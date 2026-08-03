defmodule AudioProxy.PresigningStore do
  @moduledoc """
  A variant store backend that can presign, so redirect mode has something to
  redirect to.

  No shipped backend advertises `:presign` — the `file://` one has no URLs to
  sign, and the S3 one arrives in `add-s3-client` — so without a stand-in the
  302 path would be unreachable from a test and would ship unexercised.

  It keeps its objects in `:persistent_term` under a key of its own rather
  than on disk: what is under test is the *serving* branch, and a second
  filesystem implementation would only be a second thing to keep honest. The
  presigned URL is fake but well-shaped — a base URL, the key, and an
  `expires_in` echoed back — so a test can assert the TTL reached the backend.

  Wire it up with `put_config(%{variant_store: {:module, AudioProxy.PresigningStore}})`
  and clear it with `reset/0`; see `AudioProxy.VariantStore.backend_for/1` for
  why that config shape exists.

  ## Misbehaving on purpose

  Two states a real store can reach and the `file://` one structurally cannot,
  because both need `head/1` and `get_stream/2` to disagree:

    * `vanish_reads/1` — `head/1` still reports the entry, reads answer
      `{:error, :not_found}`. The eviction window between the two calls, which
      `AudioProxy.VariantStore.Local.get_stream/2` closes by re-running
      `head/1` itself.
    * `declare_size/2` — `head/1` reports a size the bytes do not back. A store
      whose object shrank under a reader, which is what makes a proxied hit
      promise a `Content-Length` it cannot deliver.

  And one that needs no disagreement at all:

    * `fail_presign/2` — `presign/2` answers `{:error, reason}` for an entry
      that is otherwise fine, which is what sends redirect mode down its
      proxy-instead fallback.
  """

  @behaviour AudioProxy.VariantStore

  @storage_key __MODULE__

  @base "https://variants.example.test"

  @doc "Forgets every stored object."
  @spec reset() :: :ok
  def reset do
    :persistent_term.put(@storage_key, %{})
    :ok
  end

  @doc "The base URL `presign/2` builds on, for tests asserting the redirect."
  @spec base_url() :: String.t()
  def base_url, do: @base

  @impl true
  def capabilities, do: [:presign]

  @impl true
  def presign(key, opts) do
    case objects() do
      %{^key => %{presign_error: reason}} ->
        {:error, reason}

      %{^key => _object} ->
        {:ok, "#{@base}/#{key}?expires_in=#{Keyword.fetch!(opts, :expires_in)}"}

      _absent ->
        {:error, :not_found}
    end
  end

  @doc """
  Makes `key` readable by `head/1` and unreadable by `get_stream/2`.

  See *Misbehaving on purpose*.
  """
  @spec vanish_reads(AudioProxy.VariantStore.key()) :: :ok
  def vanish_reads(key), do: update(key, &%{&1 | readable: false})

  @doc """
  Makes `head/1` report `size` for `key`, whatever its bytes actually are.

  See *Misbehaving on purpose*.
  """
  @spec declare_size(AudioProxy.VariantStore.key(), non_neg_integer()) :: :ok
  def declare_size(key, size), do: update(key, &%{&1 | size: size})

  @doc """
  Makes `presign/2` fail for `key` with `reason`.

  See *Misbehaving on purpose*.
  """
  @spec fail_presign(AudioProxy.VariantStore.key(), term()) :: :ok
  def fail_presign(key, reason), do: update(key, &Map.put(&1, :presign_error, reason))

  @impl true
  def head(key) do
    case objects() do
      %{^key => object} -> {:ok, %{size: object.size, metadata: object.metadata}}
      _absent -> {:error, :not_found}
    end
  end

  @impl true
  def get_stream(key, range) do
    with {:ok, %{size: size}} <- head(key) do
      object = Map.fetch!(objects(), key)

      if object.readable do
        case slice(range, size) do
          # Clamped against the *real* bytes, which is what lets
          # `declare_size/2` under-deliver instead of raising on a read past
          # the end.
          {:ok, offset, length} ->
            available = max(min(length, byte_size(object.bytes) - offset), 0)

            {:ok, [binary_part(object.bytes, offset, available)]}

          :error ->
            {:error, :invalid_range}
        end
      else
        {:error, :not_found}
      end
    end
  end

  @impl true
  def put_stream(key, chunks, metadata) do
    bytes = chunks |> Enum.to_list() |> IO.iodata_to_binary()

    object = %{bytes: bytes, metadata: metadata, size: byte_size(bytes), readable: true}

    :persistent_term.put(@storage_key, Map.put(objects(), key, object))

    :ok
  end

  defp update(key, fun) do
    objects = objects()

    :persistent_term.put(@storage_key, Map.update!(objects, key, fun))

    :ok
  end

  defp objects do
    :persistent_term.get(@storage_key, %{})
  end

  # The local backend's rule, since the contract is shared: an end past the
  # variant is truncated, a start past it is not a range at all.
  defp slice(nil, size), do: {:ok, 0, size}

  defp slice({first, last}, size)
       when is_integer(first) and is_integer(last) and first >= 0 and first <= last and
              first < size do
    {:ok, first, min(last, size - 1) - first + 1}
  end

  defp slice(_range, _size), do: :error
end
