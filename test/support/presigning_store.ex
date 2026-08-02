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
      %{^key => _object} ->
        {:ok, "#{@base}/#{key}?expires_in=#{Keyword.fetch!(opts, :expires_in)}"}

      _absent ->
        {:error, :not_found}
    end
  end

  @impl true
  def head(key) do
    case objects() do
      %{^key => {bytes, metadata}} -> {:ok, %{size: byte_size(bytes), metadata: metadata}}
      _absent -> {:error, :not_found}
    end
  end

  @impl true
  def get_stream(key, range) do
    with {:ok, %{size: size}} <- head(key) do
      {bytes, _metadata} = Map.fetch!(objects(), key)

      case slice(range, size) do
        {:ok, offset, length} -> {:ok, [binary_part(bytes, offset, length)]}
        :error -> {:error, :invalid_range}
      end
    end
  end

  @impl true
  def put_stream(key, chunks, metadata) do
    bytes = chunks |> Enum.to_list() |> IO.iodata_to_binary()

    :persistent_term.put(@storage_key, Map.put(objects(), key, {bytes, metadata}))

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
