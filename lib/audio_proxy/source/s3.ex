defmodule AudioProxy.Source.S3 do
  @moduledoc """
  The `s3://` source type: an object in a bucket.

  `s3://masters/2026/piece-final.wav` is a bucket and a key, split at the first
  `/`. Both halves are required — a source naming only a bucket, or only a key,
  is refused rather than guessed at.

  The key is kept as its **raw decoded bytes**. `AudioProxy.Source` has already
  peeled off exactly one layer of encoding, and what is left is what S3 stores:
  a key is an opaque byte string, `a b.wav` and `a+b.wav` are different objects,
  and nothing here folds them together. Neither is `a//b` collapsed the way
  `local://` collapses it — an empty path segment is a perfectly ordinary
  character in a key, and S3 will hand you back a different object for it.

  ## Policy

  The bucket is matched against `AP_SOURCE_ALLOWLIST`
  (`AudioProxy.Source.Allowlist`), where an unset list accepts everything: the
  proxy's S3 credentials already decide which buckets are readable, so an
  allowlist is a second, narrower gate rather than the only one. Refusals are
  `{:error, :not_allowed}` → 404, indistinguishable from a missing object.

  ## Limits

  A bucket may be 63 bytes and a key 1024 — S3's own maxima. Past them the
  object cannot exist, so refusing early costs nothing and keeps an unbounded
  string out of an argv element and a log line.

  The whole body is bounded **before** it is split, not after. Finding the first
  `/` is a memchr-style scan, so it is cheap when a separator turns up early and
  linear in the whole body when none ever does — measured at 0.016 ms for 1 MB
  and 0.177 ms for 10 MB of separator-free input. That is four orders of
  magnitude short of the cost that made `AudioProxy.Source.Local`'s cap a
  denial-of-service control, so this bound is a protocol bound like
  `AudioProxy.Source.Https`'s rather than a scheduler defence. It is enforced
  first anyway: an input that cannot name an object should not be scanned at
  all, and the ordering is one less thing to re-derive later.

  ## Status: no backend yet

  `stat/1` and `ffmpeg_input/1` answer `{:error, :no_backend}`. The SigV4
  client and presigned-URL generation they need arrive with `add-s3-client`;
  until then an `s3://` source parses, canonicalizes and authorizes but cannot
  be rendered. The gap is pinned by a test, so it is a failing assertion away
  from being forgotten rather than a crash in production.
  """

  @behaviour AudioProxy.Source.Type

  alias AudioProxy.Source.Allowlist

  @typedoc "An S3 source: a bucket and an object key, both as written."
  @type t :: {:s3, String.t(), String.t()}

  # S3's own maxima: a bucket name is 3–63 characters, a key at most 1024
  # bytes. A longer one names nothing that can exist.
  @max_bucket_bytes 63
  @max_key_bytes 1024

  # The longest body that could name an object: bucket, separator, key.
  @max_body_bytes @max_bucket_bytes + 1 + @max_key_bytes

  # See `reasons/0`. `:not_allowed` comes from the allowlist, the rest from here.
  @reasons [:missing_bucket, :missing_key, :source_too_long, :no_backend, :not_allowed]

  @impl true
  def scheme, do: "s3"

  @impl true
  def tag, do: :s3

  @impl true
  def parse(""), do: {:error, :missing_bucket}

  def parse(body) when is_binary(body) do
    # Bounded before the split, never after: see the moduledoc.
    if byte_size(body) > @max_body_bytes do
      {:error, :source_too_long}
    else
      case String.split(body, "/", parts: 2) do
        [bucket, key] -> typed(bucket, key)
        [_bucket_only] -> {:error, :missing_key}
      end
    end
  end

  @impl true
  def canonical({:s3, bucket, key}) when is_binary(bucket) and is_binary(key),
    do: "s3://" <> bucket <> "/" <> key

  @impl true
  def authorize({:s3, bucket, key}) when is_binary(bucket) and is_binary(key) do
    Allowlist.authorize(:bucket, bucket)
  end

  def authorize(_source), do: {:error, :not_allowed}

  @impl true
  def stat(_source), do: {:error, :no_backend}

  @impl true
  def ffmpeg_input(_source), do: {:error, :no_backend}

  @doc """
  Every rejection reason this type can produce.

  Declared rather than inferred, so a test can hold the two ends together:
  `AudioProxy.ErrorJSON` renders a 404 only for reasons on its own list, and a
  reason missing from it answers 500 through a `FunctionClauseError`. A new
  reason added here without a row there fails that test instead of a request.
  """
  @spec reasons() :: [atom()]
  def reasons, do: @reasons

  @doc """
  A short human-readable sentence for one of this type's own reasons.
  """
  @spec message(atom()) :: String.t()
  def message(:missing_bucket), do: "s3 source has no bucket"
  def message(:missing_key), do: "s3 source has no object key"
  def message(:source_too_long), do: "s3 bucket or key is longer than S3 allows"
  def message(:no_backend), do: "s3 sources have no storage backend yet"
  def message(:not_allowed), do: "s3 bucket is not on AP_SOURCE_ALLOWLIST"

  defp typed("", _key), do: {:error, :missing_bucket}
  defp typed(_bucket, ""), do: {:error, :missing_key}

  defp typed(bucket, key) do
    if byte_size(bucket) > @max_bucket_bytes or byte_size(key) > @max_key_bytes do
      {:error, :source_too_long}
    else
      {:ok, {:s3, bucket, key}}
    end
  end
end
