defmodule AudioProxy.VariantStore.Local do
  @moduledoc """
  The `file://` variant store: a directory tree under the configured root.

  This is the store for a deployment with no object storage at all — renders
  of `local://` (or any other) sources cached on a disk the operator mounted.
  It is a single-node choice by design: two nodes with separate roots each
  render a variant once, and that is accepted rather than worked around.
  Shared caches want the `s3://` backend.

  ## Layout

  Keys are cache keys — 64 lowercase hex characters (`AudioProxy.CacheKey`) —
  and fan out by prefix so one directory never accumulates every variant:

      <root>/ab/cd/abcd…            the bytes
      <root>/ab/cd/abcd….meta       the metadata, as JSON
      <root>/tmp/                   in-flight writes

  Anything that is not a well-formed cache key is refused before it can name
  a path, so a key cannot traverse out of the root.

  ## Atomicity from rename-within-a-filesystem

  `put_stream/3` stages both files under `<root>/tmp` — *inside* the store,
  because a cross-device rename is a copy and not atomic — and commits with
  `File.rename/2`, sidecar first. The data file is the commit point:
  `head/1` requires both files, so a crash between the two renames leaves a
  sidecar nobody reads rather than bytes served with no metadata, and a
  write that never completes leaves nothing readable at all.

  ## Streamed both ways

  Reads and writes move chunk by chunk in raw mode — never a whole variant
  in memory, which is what lets this back full-length transcodes and not
  just previews. Range slices are positioned reads over the same chunking.
  """

  @behaviour AudioProxy.VariantStore

  alias AudioProxy.Config

  # The shape `AudioProxy.CacheKey.derive!/2` produces. Enforced here because
  # the key becomes a path: anything else could name a file outside the
  # fan-out, or outside the root entirely.
  @key_format ~r/^[a-f0-9]{64}$/

  # Read granularity. Large enough that a full-length variant is a few
  # thousand reads, small enough that a Range slice never over-reads much.
  @read_chunk 65_536

  @impl true
  def capabilities, do: []

  @impl true
  def presign(_key, _opts), do: {:error, :unsupported}

  @impl true
  def head(key) do
    with true <- valid_key?(key),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(data_path(key)),
         {:ok, metadata} <- read_metadata(meta_path(key)) do
      {:ok, %{size: size, metadata: metadata}}
    else
      # One answer for every miss — a malformed key, a missing file, a
      # half-written entry whose sidecar is not there or not parseable.
      _incomplete -> {:error, :not_found}
    end
  end

  @impl true
  def get_stream(key, range) do
    with {:ok, %{size: size}} <- head(key) do
      case slice(range, size) do
        {:ok, offset, length} -> {:ok, stream(data_path(key), offset, length)}
        :error -> {:error, :invalid_range}
      end
    end
  end

  @impl true
  def put_stream(key, chunks, metadata) do
    if valid_key?(key) do
      write(key, chunks, metadata)
    else
      {:error, :invalid_key}
    end
  end

  ## Writing

  defp write(key, chunks, metadata) do
    data = data_path(key)
    meta = meta_path(key)

    # Unique per write, so two concurrent puts for one key stage separately
    # and the later rename wins whole.
    unique = System.unique_integer([:positive])
    data_tmp = tmp_path(key, unique, "data")
    meta_tmp = tmp_path(key, unique, "meta")

    outcome =
      try do
        with :ok <- File.mkdir_p(Path.dirname(data)),
             :ok <- File.mkdir_p(tmp_dir()),
             :ok <- stream_to(data_tmp, chunks),
             :ok <- File.write(meta_tmp, encode_metadata(metadata)),
             # Sidecar first: `head/1` requires the data file, so committing
             # the metadata early is invisible, while committing the data
             # early would expose bytes with no metadata.
             :ok <- File.rename(meta_tmp, meta) do
          File.rename(data_tmp, data)
        end
      rescue
        # The chunk stream raising is the tee's abort signal; a filesystem
        # call raising is a genuine failure. Either way: discard, report.
        exception -> {:error, exception}
      end

    case outcome do
      :ok ->
        :ok

      {:error, _reason} = error ->
        discard(data_tmp, meta_tmp, data, meta)
        error
    end
  end

  defp stream_to(path, chunks) do
    case :file.open(path, [:raw, :binary, :write]) do
      {:ok, io} ->
        try do
          Enum.reduce_while(chunks, :ok, fn chunk, :ok ->
            case :file.write(io, chunk) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
        after
          :file.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp discard(data_tmp, meta_tmp, data, meta) do
    File.rm(data_tmp)
    File.rm(meta_tmp)

    # A sidecar that made it into place without its data file is unreadable
    # (`head/1` requires both) but still worth tidying away.
    unless File.exists?(data), do: File.rm(meta)

    :ok
  end

  ## Reading

  # `nil` is the whole variant. A slice must start inside it; an end past it
  # is truncated, which is what Range semantics ask for.
  defp slice(nil, size), do: {:ok, 0, size}

  defp slice({first, last}, size)
       when is_integer(first) and is_integer(last) and
              first >= 0 and first <= last and first < size do
    {:ok, first, min(last, size - 1) - first + 1}
  end

  defp slice(_range, _size), do: :error

  defp stream(path, offset, length) do
    Stream.resource(
      fn ->
        case :file.open(path, [:raw, :binary, :read]) do
          {:ok, io} -> {io, offset, length}
          {:error, reason} -> raise File.Error, reason: reason, action: "open", path: path
        end
      end,
      fn
        {_io, _pos, 0} = state ->
          {:halt, state}

        {io, pos, remaining} ->
          case :file.pread(io, pos, min(@read_chunk, remaining)) do
            {:ok, chunk} ->
              {[chunk], {io, pos + byte_size(chunk), remaining - byte_size(chunk)}}

            # The file was shorter than `head/1` said a moment ago — it was
            # replaced mid-read. Ending the stream early is the only honest
            # option left.
            :eof ->
              {:halt, {io, pos, remaining}}

            {:error, reason} ->
              raise File.Error, reason: reason, action: "read", path: path
          end
      end,
      fn {io, _pos, _remaining} -> :file.close(io) end
    )
  end

  ## Metadata

  defp encode_metadata(%{content_type: content_type, cache_control: cache_control, etag: etag}) do
    JSON.encode!(%{
      "content_type" => content_type,
      "cache_control" => cache_control,
      "etag" => etag
    })
  end

  defp read_metadata(path) do
    with {:ok, binary} <- File.read(path),
         {:ok,
          %{"content_type" => content_type, "cache_control" => cache_control, "etag" => etag}}
         when is_binary(content_type) and is_binary(cache_control) and is_binary(etag) <-
           JSON.decode(binary) do
      {:ok, %{content_type: content_type, cache_control: cache_control, etag: etag}}
    else
      _missing_or_malformed -> :error
    end
  end

  ## Paths

  defp valid_key?(key), do: is_binary(key) and key =~ @key_format

  defp root do
    {:file, root} = Config.get(:variant_store)
    root
  end

  defp data_path(key) do
    Path.join([root(), binary_part(key, 0, 2), binary_part(key, 2, 2), key])
  end

  defp meta_path(key), do: data_path(key) <> ".meta"

  defp tmp_dir, do: Path.join(root(), "tmp")

  defp tmp_path(key, unique, kind), do: Path.join(tmp_dir(), "#{key}.#{unique}.#{kind}")
end
