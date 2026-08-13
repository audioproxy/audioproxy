defmodule AudioProxy.Expiry do
  @moduledoc """
  What `exp` means once the URL has been parsed: the verdict, and the two
  clamps that make the verdict stick.

  `AudioProxy.Options` owns the grammar; this module owns the time. It is the
  one place that reads the clock for expiry, so the verdict and both clamps
  cannot disagree about what "now" is by more than the microseconds between
  calls.

  ## The verdict

  `check/1` is the whole enforcement: `:ok` while the URL is live,
  `{:error, :expired}` after. No clock-skew leeway — a generator that wants a
  margin adds it to its own timestamps, and leeway here would be a margin every
  deployment pays whether it wanted one or not. The boundary is `now > exp`, so
  the expiring second is still served.

  ## The two clamps

  A 410 at the edge of the proxy is theater if the response the *live* request
  got hands out a longer-lived copy of itself. Two lifetimes can do that, and
  both are clamped to `remaining/1`:

    * **The response's `Cache-Control`.** Otherwise a CDN holding a
      year-long `max-age` keeps serving the body long after the proxy would
      refuse the URL.
    * **A HIT redirect's presigned TTL.** Otherwise the 302 trades an expiring
      URL for a storage URL that outlives it — the credential leaves the
      building and the proxy is no longer in the path to say no.

  Both clamps are no-ops without `exp`: `remaining/1` answers `:infinity`,
  which is above every integer in term order, so `min/2` leaves the configured
  value exactly as it was.

  ## What is deliberately *not* clamped

  The variant metadata written back to the store. Those headers belong to the
  cached bytes, which are shared by every `exp` — the whole reason `exp` is a
  request option — so storing one requester's remaining lifetime would hand it
  to every later requester of the same variant. The clamp is a property of the
  response, applied on the way out, and `AudioProxy.VariantCache` applies it
  again to the stored value when it serves a HIT.
  """

  alias AudioProxy.Options

  @max_age ~r/max-age=\d+/

  @typedoc "Seconds of life left in the URL, or `:infinity` when it has no `exp`."
  @type remaining :: non_neg_integer() | :infinity

  @doc """
  The expiry verdict for a parsed options struct.

  `:ok` for options carrying no `exp` at all, so callers need no special case.

      iex> {:ok, opts} = AudioProxy.Options.parse("exp:1")
      iex> AudioProxy.Expiry.check(opts)
      {:error, :expired}
  """
  @spec check(Options.t()) :: :ok | {:error, :expired}
  def check(%Options{expires_at: nil}), do: :ok

  def check(%Options{expires_at: expires_at}) do
    if now() > expires_at, do: {:error, :expired}, else: :ok
  end

  @doc """
  How many seconds of life the URL has left.

  `:infinity` without `exp`. Never negative: a URL that has already expired has
  zero seconds left, and every clamp below wants a lifetime it can hand to a
  header.

      iex> AudioProxy.Expiry.remaining(%AudioProxy.Options{})
      :infinity
  """
  @spec remaining(Options.t()) :: remaining()
  def remaining(%Options{expires_at: nil}), do: :infinity
  def remaining(%Options{expires_at: expires_at}), do: max(expires_at - now(), 0)

  @doc """
  Rewrites a `Cache-Control` header so its `max-age` outlives nothing.

  The header is otherwise untouched — `public`, `immutable` and `no-transform`
  still describe the bytes correctly for however long they stay fresh, and only
  the lifetime was ever too long.

      iex> {:ok, opts} = AudioProxy.Options.parse("f:mp3")
      iex> AudioProxy.Expiry.clamp_cache_control("public, max-age=60", opts)
      "public, max-age=60"
  """
  @spec clamp_cache_control(String.t(), Options.t()) :: String.t()
  def clamp_cache_control(header, options) do
    case remaining(options) do
      :infinity ->
        header

      seconds ->
        Regex.replace(@max_age, header, fn matched ->
          "max-age=" <> Integer.to_string(min(max_age(matched), seconds))
        end)
    end
  end

  @doc """
  Clamps a credential's time-to-live to the URL's own.

  Used for the presigned TTL of a HIT redirect. A `0` is possible in the
  expiring second and is left as `0` rather than floored: a credential that
  outlives its URL, however briefly, is the thing this exists to prevent, and
  a backend that refuses to sign for zero seconds falls back to proxying the
  bytes — which is the same answer the request would have got a second earlier.
  """
  @spec clamp_ttl(non_neg_integer(), Options.t()) :: non_neg_integer()
  def clamp_ttl(ttl, options), do: min(ttl, remaining(options))

  defp max_age("max-age=" <> seconds), do: String.to_integer(seconds)

  defp now, do: System.system_time(:second)
end
