defmodule AudioProxy.S3 do
  @moduledoc """
  The four S3 operations this proxy needs, over `ex_aws_s3`.

  Not a general S3 client and not on the way to becoming one. An
  object-storage deployment needs exactly this much:

    * `presign_get/3` — a URL ffmpeg can read a source from, and a URL a
      client can be redirected to on a cache hit. Presigned because neither
      of them will send an `Authorization` header for us.
    * `head/2` — does this object exist, how big is it, what is its ETag.
      The `/info` and cache-hit paths.
    * `put_stream/4` — write a variant back, streaming, without knowing its
      length in advance (a render's output length is not known until it ends).
    * `get_stream/3` — read a variant back for proxy-mode serving.

  ## Why a facade and not `ExAws.S3` at the call sites

  Three reasons, none of them dogma. Callers get `{:error, :not_found}`
  instead of `{:error, {:http_error, 404, _}}`, which is the vocabulary the
  rest of the codebase already speaks. Credentials come from
  `AudioProxy.Config` rather than `ex_aws`'s own resolution — see below. And
  the surface stays four functions wide, so "we only do these four things"
  is enforced rather than merely intended.

  ## Configuration is ours, not `ex_aws`'s

  `ex_aws` resolves credentials from application env, `AWS_*` variables, and
  on EC2 from IMDS, in an order it decides. This proxy validates its whole
  configuration once at boot and keeps it in one map, so every call here
  passes an explicit config override built from `AudioProxy.Config`. The
  effect worth naming: **there is no IMDS lookup**, so an EC2 instance role
  does not work and credentials must be supplied. That is a documented
  limitation (README), not an oversight, and the place to change it is
  `config/1` here.

  ## Errors are data

  Every function returns `{:ok, _}` or `{:error, t:error/0}`. `:not_found`
  and `:access_denied` stay distinct: AWS answers 403 for a missing object
  when the caller cannot list the bucket, so they are genuinely ambiguous —
  but folding them would turn an expired credential into a permanent cache
  miss and re-render every request forever.
  """

  alias AudioProxy.Config

  @typedoc "A bucket name."
  @type bucket :: String.t()

  @typedoc "An object key, as raw bytes — never percent-encoded."
  @type key :: String.t()

  @typedoc """
  What `head/2` reports.

  `metadata` holds the `x-amz-meta-*` headers with the prefix stripped and
  names lowercased, which is how the variant store round-trips its own
  response headers through an object.
  """
  @type object :: %{
          size: non_neg_integer(),
          etag: String.t() | nil,
          content_type: String.t() | nil,
          cache_control: String.t() | nil,
          metadata: %{optional(String.t()) => String.t()}
        }

  @typedoc """
  Why an S3 call failed.

    * `:not_found` — the object is not there (404).
    * `:access_denied` — credentials rejected (403). Distinct from
      `:not_found` on purpose; see the moduledoc.
    * `{:http, status, body}` — any other status.
    * `{:transport, reason}` — nothing came back.
  """
  @type error ::
          :not_found
          | :access_denied
          | {:http, non_neg_integer(), binary()}
          | {:transport, term()}

  # Read granularity for `get_stream/3`. `ex_aws_s3` has no in-memory
  # streaming GET — `download_file/4` streams to disk and `get_object/3`
  # returns the whole body — so a bounded read is a sequence of ranged GETs.
  # 1 MiB keeps the request count sane for a full-length variant while
  # bounding memory well below one.
  @read_chunk 1_048_576

  # S3's minimum for a non-final part. A stream that ends inside this goes as
  # one `PutObject` instead — see `buffer_first_part/1`.
  @part_size 5 * 1024 * 1024

  @doc """
  A presigned GET URL for an object.

  Options: `:expires_in` (seconds, defaulting to `AP_PRESIGN_TTL`).
  """
  @spec presign_get(bucket(), key(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def presign_get(bucket, key, opts \\ []) do
    expires_in = Keyword.get(opts, :expires_in, Config.get(:presign_ttl))

    # `presigned_url/5` signs locally rather than issuing a request, so it
    # wants a built `%ExAws.Config{}` where the request path takes overrides.
    signing_config = ExAws.Config.new(:s3, config())

    case ExAws.S3.presigned_url(signing_config, :get, bucket, key, expires_in: expires_in) do
      {:ok, url} -> {:ok, url}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  @doc "Object existence, size, ETag and metadata."
  @spec head(bucket(), key()) :: {:ok, object()} | {:error, error()}
  def head(bucket, key) do
    bucket
    |> ExAws.S3.head_object(key)
    |> request()
    |> case do
      {:ok, %{headers: headers}} -> {:ok, object(headers)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Uploads `chunks` — an enumerable of binaries of unknown total length.

  Options: `:content_type`, `:cache_control`, and `:metadata` (a map written
  as `x-amz-meta-*`).

  `ExAws.S3.upload/4` runs the multipart protocol, including
  `AbortMultipartUpload` when a part fails, so a failed write leaves neither
  a partial object nor billable orphan parts. A stream that raises — which is
  how `AudioProxy.VariantStore.Tee` signals a cancelled render — is caught
  here and reported, after the abort has run.
  """
  @spec put_stream(bucket(), key(), Enumerable.t(), keyword()) :: :ok | {:error, error() | term()}
  def put_stream(bucket, key, chunks, opts \\ []) do
    case buffer_first_part(chunks) do
      {:whole, iodata} -> put_object(bucket, key, IO.iodata_to_binary(iodata), opts)
      {:streamed, stream} -> upload(bucket, key, stream, opts)
    end
  rescue
    # The chunk stream raising is the tee's abort signal. `ExAws.S3.Upload`
    # aborts the multipart upload on its way out, so by the time this is
    # reached there is nothing left in the bucket to clean up.
    exception -> {:error, exception}
  catch
    # `throw` and `exit` unwind past `rescue`. Re-raised rather than turned
    # into a return value: the point is not to swallow a shutdown something
    # else initiated.
    kind, reason -> :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @doc """
  Streams an object's bytes, or an inclusive byte range of them.

  Lazy and bounded-memory: a sequence of ranged GETs of `#{@read_chunk}`
  bytes, never the whole object at once. `ex_aws_s3` offers no in-memory
  streaming read, so this is assembled here — see `@read_chunk`.

  Only proxy-mode serving needs it. A redirect hands the client a presigned
  URL and the bytes never enter the BEAM at all, which is the default and the
  reason this costs more round trips than it might.
  """
  @spec get_stream(bucket(), key(), {non_neg_integer(), non_neg_integer()} | nil) ::
          {:ok, Enumerable.t()} | {:error, error()}
  def get_stream(bucket, key, range \\ nil) do
    with {:ok, %{size: size}} <- head(bucket, key) do
      # A zero-length object has no satisfiable range at all: `bytes=0-0`
      # asks for a byte that is not there, and S3 answers 416 rather than an
      # empty body. It is a legitimate variant — a render can produce no
      # bytes — so it streams as nothing rather than failing.
      case range || {0, size - 1} do
        {_first, last} when last < 0 -> {:ok, []}
        {first, last} -> {:ok, ranged_stream(bucket, key, first, last)}
      end
    end
  end

  ## Writing

  defp put_object(bucket, key, body, opts) do
    bucket
    |> ExAws.S3.put_object(key, body, upload_opts(opts))
    |> request()
    |> case do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp upload(bucket, key, stream, opts) do
    stream
    |> ExAws.S3.upload(bucket, key, upload_opts(opts))
    |> request()
    |> case do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Reads up to one part from `chunks` without committing to a strategy.
  #
  # This exists because `ExAws.S3.upload/4` *always* runs the multipart
  # protocol, and S3 rejects a multipart upload whose only part is under
  # 5 MiB with `EntityTooSmall` — so it cannot write a small object at all.
  # Previews, which are most of what this proxy renders, are all small
  # objects. A single `PutObject` is also one request instead of three.
  #
  # The enumerable is consumed with an explicit `Enumerable.reduce/3`
  # suspension rather than `Enum.take/2` so the tail is never re-enumerated:
  # `chunks` is a live render, and asking it to start over is not a thing it
  # can do.
  defp buffer_first_part(chunks) do
    case Enumerable.reduce(chunks, {:cont, {[], 0}}, &buffer_reducer/2) do
      # The stream ended inside one part: send it whole.
      {:done, {buffered, _size}} ->
        {:whole, Enum.reverse(buffered)}

      # There is more, so it is a genuine multipart upload. The buffered
      # prefix is replayed ahead of the rest, which resumes from exactly
      # where the peek stopped.
      {:suspended, {buffered, _size}, continuation} ->
        {:streamed,
         Enum.reverse(buffered)
         |> Stream.concat(resume(continuation))
         |> into_parts()}

      {:halted, {buffered, _size}} ->
        {:whole, Enum.reverse(buffered)}
    end
  end

  defp buffer_reducer(chunk, {buffered, size}) do
    buffered = [chunk | buffered]
    size = size + byte_size(chunk)

    if size >= @part_size do
      {:suspend, {buffered, size}}
    else
      {:cont, {buffered, size}}
    end
  end

  # `ExAws.S3.upload/4` uploads **one part per element** — it does no
  # regrouping of its own. Render chunks are far smaller than S3's 5 MiB
  # minimum, so handing it the raw stream produces a hundred undersized parts
  # and `EntityTooSmall` at completion. Grouping is therefore ours to do.
  #
  # Memory stays bounded at one part plus one chunk, which is the same bound
  # the buffering above already establishes.
  defp into_parts(stream) do
    Stream.chunk_while(
      stream,
      {[], 0},
      fn chunk, {buffered, size} ->
        buffered = [buffered, chunk]
        size = size + byte_size(chunk)

        if size >= @part_size do
          {:cont, IO.iodata_to_binary(buffered), {[], 0}}
        else
          {:cont, {buffered, size}}
        end
      end,
      fn
        # A zero-length tail is not emitted: S3 rejects an empty part, and
        # the parts already sent are the whole object.
        {_buffered, 0} -> {:cont, {[], 0}}
        {buffered, _size} -> {:cont, IO.iodata_to_binary(buffered), {[], 0}}
      end
    )
  end

  # One chunk per resumption. `into_parts/1` regroups them.
  defp resume(continuation) do
    Stream.resource(
      fn -> continuation end,
      fn
        nil ->
          {:halt, nil}

        continuation ->
          case continuation.({:cont, {[], 0}}) do
            {:suspended, {buffered, _size}, next} -> {Enum.reverse(buffered), next}
            {:done, {buffered, _size}} -> {Enum.reverse(buffered), nil}
            {:halted, {buffered, _size}} -> {Enum.reverse(buffered), nil}
          end
      end,
      fn _continuation -> :ok end
    )
  end

  ## Reading

  # One ranged GET per chunk. `Stream.resource/3` is not needed — there is no
  # resource to release, only arithmetic — so this is a plain unfold.
  defp ranged_stream(_bucket, _key, first, last) when first > last, do: []

  defp ranged_stream(bucket, key, first, last) do
    Stream.unfold(first, fn
      offset when offset > last ->
        nil

      offset ->
        chunk_last = min(offset + @read_chunk - 1, last)

        case get_range(bucket, key, offset, chunk_last) do
          {:ok, body} -> {body, offset + byte_size(body)}
          # Mid-stream, with a response already going out to the client,
          # there is nothing to return an error value *to*.
          {:error, reason} -> raise "s3: read failed at byte #{offset}: #{inspect(reason)}"
        end
    end)
  end

  defp get_range(bucket, key, first, last) do
    bucket
    |> ExAws.S3.get_object(key, range: "bytes=#{first}-#{last}")
    |> request()
    |> case do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Requests

  defp request(operation) do
    case ExAws.request(operation, config()) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, translate(reason)}
    end
  end

  # `ex_aws`'s error shapes, in this codebase's vocabulary.
  #
  # A 404 is only a miss when it is the *object* that is missing. S3 answers
  # 404 for a missing bucket too, and reporting that as a cache miss would
  # make a misconfigured `AP_VARIANT_STORE` look like a permanently cold
  # cache: every request a miss, every miss a re-render, every write-back
  # failing silently. The distinction is in the error code, so it is read.
  defp translate({:http_error, 404, %{body: body}}) when is_binary(body) do
    if String.contains?(body, "<Code>NoSuchBucket</Code>") do
      {:http, 404, body}
    else
      :not_found
    end
  end

  defp translate({:http_error, 404, _response}), do: :not_found
  defp translate({:http_error, 403, _response}), do: :access_denied

  defp translate({:http_error, status, %{body: body}}) when is_binary(body),
    do: {:http, status, body}

  defp translate({:http_error, status, _response}), do: {:http, status, ""}
  defp translate(reason), do: {:transport, reason}

  defp upload_opts(opts) do
    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> Enum.map(fn {name, value} -> {to_string(name), to_string(value)} end)

    Enum.reject(
      [
        content_type: opts[:content_type],
        cache_control: opts[:cache_control],
        meta: if(metadata == [], do: nil, else: metadata)
      ],
      fn {_name, value} -> is_nil(value) end
    )
  end

  defp object(headers) do
    headers = for {name, value} <- headers, into: %{}, do: {String.downcase(name), value}

    %{
      size: headers |> Map.get("content-length") |> to_integer(),
      etag: Map.get(headers, "etag"),
      content_type: Map.get(headers, "content-type"),
      cache_control: Map.get(headers, "cache-control"),
      metadata: user_metadata(headers)
    }
  end

  defp user_metadata(headers) do
    for {"x-amz-meta-" <> name, value} <- headers,
        into: %{},
        do: {String.downcase(name), value}
  end

  defp to_integer(nil), do: 0

  defp to_integer(value) do
    case Integer.parse(to_string(value)) do
      {integer, _rest} -> integer
      :error -> 0
    end
  end

  ## Configuration

  @doc """
  The `ex_aws` config overrides for this deployment.

  Public so a test can assert on the addressing decision without issuing a
  request.
  """
  @spec config() :: keyword()
  def config do
    s3 = Config.get(:s3)

    [
      access_key_id: s3.access_key_id,
      secret_access_key: s3.secret_access_key,
      region: s3.region,
      # `ex_aws` defaults to Jason, which this project does not depend on —
      # it uses OTP/Elixir's own `JSON`. Only reached when `ex_aws` decodes
      # an error body, which is exactly when a missing module would be most
      # confusing: the real failure disappears behind an UndefinedFunctionError.
      json_codec: JSON,
      # Ours rather than `ex_aws`'s bundled hackney adapter, which cannot
      # read hackney 4.0's bodyless responses. See `AudioProxy.S3.HttpClient`.
      http_client: AudioProxy.S3.HttpClient
    ] ++ security_token(s3.session_token) ++ endpoint(s3.endpoint)
  end

  # Omitted entirely rather than passed as `nil`: `ex_aws` sends the header
  # whenever the key is present, and a store reads an empty security token as
  # an invalid one — which fails every request with a message about temporary
  # credentials nobody configured.
  defp security_token(nil), do: []
  defp security_token(token), do: [security_token: token]

  # Virtual-hosted against AWS (path-style is deprecated there), path-style
  # against a custom endpoint — MinIO, localstack and the rest are reached by
  # hostname and port, and inventing `bucket.minio` would need DNS nobody
  # configured. `ex_aws` wants the scheme with its `://` attached.
  defp endpoint(nil), do: []

  defp endpoint(%URI{scheme: scheme, host: host, port: port}) do
    [scheme: scheme <> "://", host: host, port: port]
  end
end
