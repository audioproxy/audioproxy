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

  ## The seam

  `stat/1` is one `AudioProxy.S3.head/2`: the object's size answers the render
  path's 413 before a subprocess starts, and its ETag is what `/info`'s
  validator hashes. `ffmpeg_input/1` is one `AudioProxy.S3.presign_get/3`,
  handed to ffmpeg as a single argv element — the source bytes never cross the
  BEAM, and ffmpeg issues its own Range requests, so `-ss` on a two-hour master
  reads only the bytes it needs.

  Nothing is presigned at `stat/1` time. Both flows call the two callbacks
  separately, and a presigned URL has an expiry: minting one the caller may
  never use is a credential with a lifetime and no purpose.

  ## Failures classify by cause

  `AudioProxy.S3`'s error type is five atoms and one `{:http, status, _}` whose
  status is *unbounded*, and this module maps all of it explicitly, with no
  catch-all — an unmapped shape should crash a test rather than pick a
  plausible status in production.

  The status ranges are the part worth reading twice. An earlier revision of
  this covered 4xx and 5xx and called that total, which it is not: `ex_aws`
  turns S3's "your bucket is in another region" into `{:http, 301, _}`, and a
  request that hit it raised `FunctionClauseError` and answered a bare 500 —
  the exact outcome the no-catch-all rule exists to prevent, arrived at by
  leaving a hole instead of a default.

      :not_found          → :not_found            404, the blind row
      :access_denied      → :not_found            404, the blind row
      {:http, 4xx, _}     → :not_found            404, the blind row
      {:http, 3xx, _}     → :not_configured       500 — a wrong-region redirect
      :not_configured     → :not_configured       500
      {:http, 5xx, _}     → :upstream_unavailable 502
      {:transport, _}     → :upstream_unavailable 502

  A `{:http, 1xx/2xx, _}` still has no clause, deliberately: `AudioProxy.S3`
  only builds those for the multipart write path, which this module never
  reaches. A 3xx other than 301 does not arrive either — `ex_aws`'s own `case`
  has no branch for one and raises inside the dependency first, which is not
  something a clause here can repair.

  Folding `:access_denied` into the 404 is the deliberate part. A bucket
  policy that denies HEAD is indistinguishable from a missing object *to the
  client*, which is the property §5's blind 404 exists to protect; the operator
  gets the truth from the log line, which names the S3 reason, rather than from
  a response body that would double as an existence oracle. A `4xx` that is
  neither goes the same way: it means we asked wrongly for an object the client
  named, and the client cannot tell that apart from the object not being there.

  An outage does **not** go there. `{:transport, _}` and an upstream `5xx` say
  nothing about whether the object exists, so answering 404 would report a
  deletion that did not happen and edge-cache it for ten seconds, suppressing
  the retry that would have worked. They answer 502 (`no-store`).

  `:invalid_range` is unreachable — it belongs to `get_stream/3`, which this
  module never calls — and so has no clause. If it ever appeared it would
  raise, which is this codebase's convention for "this should be impossible".
  """

  @behaviour AudioProxy.Source.Type

  alias AudioProxy.Source.Allowlist

  require Logger

  @typedoc "An S3 source: a bucket and an object key, both as written."
  @type t :: {:s3, String.t(), String.t()}

  # S3's own maxima: a bucket name is 3–63 characters, a key at most 1024
  # bytes. A longer one names nothing that can exist.
  @max_bucket_bytes 63
  @max_key_bytes 1024

  # The longest body that could name an object: bucket, separator, key.
  @max_body_bytes @max_bucket_bytes + 1 + @max_key_bytes

  # See `reasons/0`. `:not_allowed` comes from the allowlist, `:not_found` and
  # the two seam reasons from `classify/1`, the rest from `parse/1`.
  @reasons [
    :missing_bucket,
    :missing_key,
    :source_too_long,
    :not_allowed,
    :not_found,
    :not_configured,
    :upstream_unavailable
  ]

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
  def stat({:s3, bucket, key} = source) when is_binary(bucket) and is_binary(key) do
    case AudioProxy.S3.head(bucket, key) do
      # Straight across: `size` is what answers 413 before ffmpeg is spawned,
      # `etag` is what `/info`'s validator hashes. Nothing else in the object
      # is the seam's business.
      {:ok, %{size: size, etag: etag}} -> {:ok, %{size: size, etag: etag}}
      {:error, reason} -> {:error, refuse(reason, source, "head")}
    end
  end

  def stat(_source), do: {:error, :not_allowed}

  @impl true
  def ffmpeg_input({:s3, bucket, key} = source) when is_binary(bucket) and is_binary(key) do
    # One argv element, and one the BEAM never reads through: ffmpeg opens the
    # URL itself and ranges it. `presign_get/3` defaults its expiry to
    # `AP_PRESIGN_TTL`, so the TTL is not repeated here.
    case AudioProxy.S3.presign_get(bucket, key) do
      {:ok, url} -> {:ok, url}
      {:error, reason} -> {:error, refuse(reason, source, "presign")}
    end
  end

  def ffmpeg_input(_source), do: {:error, :not_allowed}

  @doc """
  Every rejection reason this type can produce.

  Declared rather than inferred, so a test can hold the two ends together:
  `AudioProxy.ErrorJSON` has no catch-all, so a reason with no row there
  raises `FunctionClauseError` in production. A new reason added here without
  a row there fails that test instead of a request.

  Not all of them are 404s. `:not_configured` and `:upstream_unavailable` come
  from the storage seam and are deliberately *not* on
  `AudioProxy.ErrorJSON.not_found_reasons/0` — see the moduledoc's table for
  why an outage must stay distinguishable from a missing object.
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
  def message(:not_allowed), do: "s3 bucket is not on AP_SOURCE_ALLOWLIST"
  def message(:not_found), do: "s3 object is not there, or is not readable"
  def message(:not_configured), do: "s3 credentials are not configured"
  def message(:upstream_unavailable), do: "s3 could not be reached"

  @doc """
  Maps one `t:AudioProxy.S3.error/0` shape to this type's own reason.

  One clause per shape, no catch-all — see the moduledoc's table for what each
  answers and why. Public so a test can enumerate the error type exhaustively:
  the mapping is the whole of this slice's decision, and a shape that quietly
  lost its clause would answer 500 to a request rather than fail a test.
  """
  @spec classify(AudioProxy.S3.error()) :: :not_found | :not_configured | :upstream_unavailable
  def classify(:not_found), do: :not_found

  # The one collapse that matters. This answers exactly the 404 a missing
  # object answers, byte for byte, so a client cannot use the proxy's
  # credentials to learn what a bucket holds; the operator debugging a bucket
  # policy reads the log line instead.
  def classify(:access_denied), do: :not_found

  # A redirect the store meant us to follow, and we do not: the HTTP client
  # sets `autoredirect: false` (`AudioProxy.S3.HttpClient`), so a 301 arrives
  # here as an error rather than as a second request. `ex_aws` produces exactly
  # one — `{:http_error, 301, "redirected"}`, logged by it as "did you specify
  # the correct region?" — and that is what this is: a bucket in a region the
  # configuration does not name.
  #
  # So it is the operator's, not the client's, and *not* the 502: retrying a
  # region mismatch never succeeds, and a row that invites a retry would have a
  # client hammering a request that cannot work.
  def classify({:http, status, _body}) when status >= 300 and status < 400, do: :not_configured

  # Neither 404 nor 403: we asked wrongly for an object the client named, and
  # the client cannot tell that apart from the object not being there.
  def classify({:http, status, _body}) when status >= 400 and status < 500, do: :not_found

  def classify({:http, status, _body}) when status >= 500, do: :upstream_unavailable
  def classify({:transport, _detail}), do: :upstream_unavailable
  def classify(:not_configured), do: :not_configured

  ## The seam's failures

  # `classify/1` plus the log line that carries what the response deliberately
  # drops. An ordinary miss is not logged — it is the most common answer this
  # module gives, and a warning per missing object is a warning nobody reads.
  @spec refuse(AudioProxy.S3.error(), t(), String.t()) :: atom()
  defp refuse(:not_found, _source, _op), do: :not_found

  defp refuse(reason, {:s3, bucket, key}, op) do
    Logger.warning(
      "s3 source: #{op} failed (bucket=#{bucket} key=#{key} reason=#{inspect(reason)})"
    )

    classify(reason)
  end

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
