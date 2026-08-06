defmodule AudioProxy.VariantStore.S3 do
  @moduledoc """
  The `s3://` variant store: one object per variant in a bucket.

  This is the store for a deployment that has object storage — the cache
  outlives the container, every node reads what any node rendered, and,
  because an object can be handed to a client directly, `AP_SERVE_MODE=redirect`
  becomes reachable. That last part is not a bonus: redirect is the documented
  default (`docs/audio-proxy-api-v1.md` §5), and until this backend existed no
  shipped store could presign, so every deployment served cached bytes through
  the BEAM.

  ## Layout: the cache key *is* the object key

  No fan-out. `AudioProxy.VariantStore.Local` splits a key into
  `ab/cd/abcd…` because a directory holding a million entries is a filesystem
  problem; a bucket holding a million objects is not one, and S3 partitions by
  key prefix on its own. A flat key is also what makes the reserved probe
  prefix below unambiguous.

  Keys are still checked against the cache-key shape before they name an
  object. Not for traversal — an object key has no `..` to follow — but so
  that nothing outside `AudioProxy.CacheKey`'s alphabet can be written into
  the bucket, which is what keeps `#{inspect(__MODULE__)}` and
  `AudioProxy.Config`'s boot probe out of each other's key space.

  ## A PUT is the commit point

  There is no staging, because there is nothing to stage: an object does not
  exist until its upload completes, and `AudioProxy.S3.put_stream/4` aborts a
  multipart upload on every failure path it can see. So the local backend's
  `tmp/` dance and its boot-time sweep have no analogue here, and
  atomic-or-absent is a property of the protocol rather than of this module.

  ## Metadata rides on the object

  `Content-Type` and `Cache-Control` are the object's own headers. That is
  what makes a redirect correct: the client fetches the object from the store
  with no proxy in the path, and must receive the same headers a proxied HIT
  would have sent. The seam's `etag` cannot be one — S3 computes an object's
  ETag itself — so it travels as `x-amz-meta-etag` and is read back off the
  HEAD.

  An object missing any of the three is reported as a miss rather than served
  with a guess. `head/1` answering `{:ok, _}` means *this* module wrote the
  object, whole; a stray object under a 64-hex key is not a variant.

  ## Failures are misses, and the store's failures are the operator's

  The seam has two error values — `:not_found` and `:invalid_range` — so every
  other way S3 can fail arrives at a caller that can only render. That is the
  right answer on a lookup: a render produces correct bytes whatever the cache
  did, and failing a request because the *cache* is unreachable would turn a
  degraded store into an outage.

  It is not a *silent* answer. `AudioProxy.Source.S3.classify/1` — the table
  `add-s3-source-backend` established, reused here rather than restated — says
  whether a failure was an ordinary miss, a misconfiguration, or an outage,
  and anything that is not an ordinary miss is logged at warning with the
  bucket and key. An operator reading "every request is a MISS" needs the line
  that says the store answered 403.

  Write failures are different only in who hears about them:
  `AudioProxy.VariantStore.Tee` already treats the write-back as best-effort
  and reports `[:audio_proxy, :variant_store, :write_failure]`, so this module
  returns the error as data and lets the tee decide. A client receiving a
  correct render is never failed because the cache could not keep it.
  """

  @behaviour AudioProxy.VariantStore

  alias AudioProxy.{Config, S3}

  require Logger

  # `AudioProxy.CacheKey.derive!/2`'s shape, enforced for the reason in the
  # moduledoc.
  @key_format ~r/^[a-f0-9]{64}$/

  # The seam's ETag, which S3 will not let us set as the object's own.
  @etag_metadata "etag"

  @impl true
  def capabilities, do: [:presign]

  @impl true
  def head(key) do
    with true <- valid_key?(key),
         {:ok, object} <- lookup(key, "head"),
         {:ok, metadata} <- metadata(object) do
      {:ok, %{size: object.size, metadata: metadata}}
    else
      # One answer for every miss — a malformed key, an absent object, an
      # object that is not one of ours, a store that could not be asked.
      _incomplete -> {:error, :not_found}
    end
  end

  @impl true
  def get_stream(key, range) do
    if valid_key?(key) do
      case S3.get_stream(bucket(), key, range) do
        {:ok, stream} -> {:ok, stream}
        {:error, :invalid_range} -> {:error, :invalid_range}
        {:error, reason} -> miss(reason, key, "get")
      end
    else
      {:error, :not_found}
    end
  end

  @impl true
  def put_stream(key, chunks, metadata) do
    if valid_key?(key) do
      S3.put_stream(bucket(), key, chunks,
        content_type: metadata.content_type,
        cache_control: metadata.cache_control,
        metadata: %{@etag_metadata => metadata.etag}
      )
    else
      {:error, :invalid_key}
    end
  end

  @impl true
  def presign(key, opts) do
    if valid_key?(key) do
      S3.presign_get(bucket(), key, opts)
    else
      {:error, :invalid_key}
    end
  end

  ## Reading

  defp lookup(key, op) do
    case S3.head(bucket(), key) do
      {:ok, object} -> {:ok, object}
      {:error, reason} -> miss(reason, key, op)
    end
  end

  # Everything the seam has no word for becomes a miss, and everything that is
  # not an ordinary miss becomes a log line first. See the moduledoc.
  defp miss(:not_found, _key, _op), do: {:error, :not_found}

  defp miss(reason, key, op) do
    Logger.warning(
      "s3 variant store: #{op} failed, treating as a miss " <>
        "(bucket=#{bucket()} key=#{key} reason=#{inspect(reason)} " <>
        "class=#{AudioProxy.Source.S3.classify(reason)})"
    )

    {:error, :not_found}
  end

  # All three or nothing: an object without them was not written by this
  # module, and serving it would mean inventing headers the redirect path
  # cannot correct.
  defp metadata(%{
         content_type: content_type,
         cache_control: cache_control,
         metadata: %{@etag_metadata => etag}
       })
       when is_binary(content_type) and is_binary(cache_control) and is_binary(etag) do
    {:ok, %{content_type: content_type, cache_control: cache_control, etag: etag}}
  end

  defp metadata(_incomplete), do: :error

  ## Configuration

  defp valid_key?(key), do: is_binary(key) and key =~ @key_format

  defp bucket do
    {:s3, bucket} = Config.get(:variant_store)
    bucket
  end
end
