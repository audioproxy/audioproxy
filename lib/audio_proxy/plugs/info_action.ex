defmodule AudioProxy.Plugs.InfoAction do
  @moduledoc """
  The info endpoint's action (API doc §2, §4): stat, probe, JSON.

  It shares the whole check chain with the render endpoint and diverges only
  here — same signature gate, same source resolution, same blind 404. What it
  does instead of rendering is one `ffprobe` run through
  `AudioProxy.Ffprobe`, filtered to §4's object.

  The order is `stat` then probe, and the stat earns its place twice over: it
  is what answers 404 before a subprocess exists, and its ETag material is half
  of this response's validator.

  ## `AP_MAX_SRC_BYTES` does not apply here

  The render path refuses an oversized source with 413, and this endpoint
  deliberately does not — which is a departure from the proposal's "413 as
  usual", made once it was clear what the limit buys on this path. Nothing.
  A probe reads container headers and stops; against an HTTP source ffmpeg
  ranges for them, so a four-gigabyte master costs the same probe a four-megabyte
  one does. The limit exists to stop a render from *decoding* something huge.

  Refusing anyway would also be self-defeating in the one case that matters:
  the client most in need of `/info` is the one holding a long source it means
  to ask for a trimmed preview of, and answering "too large to describe" leaves
  it guessing at the very numbers the endpoint exists to supply.

  ## The ETag is not a cache key

  On the render path the ETag *is* the cache key — a pure function of the URL,
  because the URL fully describes immutable variant bytes. Nothing like that is
  true here. `/info` describes the source, the source is mutable, and the same
  URL answers differently after a re-upload. So the validator is

      lowercase-hex(SHA-256(canonical-source ‖ "\\n" ‖ stat-etag))

  which changes exactly when the object does. Two consequences follow, and both
  are the opposite of the render path's:

    * The 304 comes **after** the stat, not before it, because the stat is what
      the validator is made of. A revalidation still skips the probe, which is
      the expensive half.
    * `Cache-Control` is **not** `immutable`. §4 asks for aggressive caching and
      `@cache_control` gives an hour of it, but `immutable` on a URL whose
      answer can change would tell caches never to revalidate a document that
      has no other way of being corrected. An hour plus a cheap 304 is
      aggressive; never asking again is wrong.

  A backend that offers no ETag material (`stat.etag` is `nil`) gets no
  validator and a short, plainly-stated `max-age` instead — a response that
  cannot be revalidated must not be held for an hour.

  ## HEAD

  Same discipline as `AudioProxy.Plugs.RenderAction`: every check the chain can
  run — here the stat, and nothing else — then a bodiless 200 with no
  subprocess. The divergence that buys is the same one, and is deliberate: a
  HEAD on an unprobeable source answers 200 where the GET answers 415, because
  diagnosing 415 *is* the probe. There is no `Content-Length` either, for the
  same reason.

  ## Failures

  `AudioProxy.Ffprobe` classifies, this maps: a source ffprobe cannot parse — or
  that carries no audio stream at all — is 415, a probe that outran
  `AP_PROBE_TIMEOUT` is 504, and anything else is 500. A missing source
  rediscovered by the probe (deleted between the stat and the spawn) is the
  same blind 404 the stat would have given.
  """

  @behaviour Plug

  import Plug.Conn

  alias AudioProxy.{ErrorJSON, Ffprobe, Source}

  # An hour, then revalidate. See the moduledoc for why not `immutable`.
  @cache_control "public, max-age=3600"

  # What a response with no validator gets: still shareable, still cached, but
  # for a minute rather than an hour, since nothing can correct it early.
  @unvalidatable_cache_control "public, max-age=60"

  @separator "\n"

  @typedoc """
  Plug options.

    * `:executable` — the binary to probe with, passed through to
      `AudioProxy.Ffprobe`. Unset means `ffprobe` from `PATH`; tests mount a
      chain of their own with a stand-in.
  """
  @type opts :: keyword()

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    source = conn.assigns.source

    case Source.stat(source) do
      {:ok, stat} -> conn |> describe(source, stat) |> answer(source, stat, opts)
      {:error, reason} -> ErrorJSON.halt_with(conn, reason)
    end
  end

  # The validator and its policy travel with every outcome that has a body or
  # could have had one — 200, 304 and the bodiless HEAD alike — so a cache sees
  # the same metadata whichever it got.
  defp describe(conn, source, stat) do
    case etag(source, stat) do
      nil ->
        put_resp_header(conn, "cache-control", @unvalidatable_cache_control)

      etag ->
        conn
        |> put_resp_header("cache-control", @cache_control)
        |> put_resp_header("etag", etag)
    end
  end

  defp answer(%Plug.Conn{method: "HEAD"} = conn, _source, _stat, _opts) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, "") |> halt()
  end

  defp answer(conn, source, stat, opts) do
    if revalidated?(conn, source, stat) do
      conn |> send_resp(304, "") |> halt()
    else
      probe(conn, source, stat, opts)
    end
  end

  defp probe(conn, source, stat, opts) do
    with {:ok, input} <- Source.ffmpeg_input(source),
         {:ok, output} <- Ffprobe.probe(input, Keyword.take(opts, [:executable])),
         {:ok, info} <- Ffprobe.contract(output, size: stat.size) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(info))
      |> halt()
    else
      {:error, reason} -> ErrorJSON.halt_with(conn, reason)
    end
  end

  ## The validator

  # Hashed rather than passed through: `stat.etag` is a backend's own string
  # (an S3 ETag arrives quoted) and the canonical source is arbitrary text, so
  # digesting both is what makes the result a well-formed entity-tag whatever
  # the backend spells. The newline separates the halves for the same reason
  # `AudioProxy.CacheKey` uses one.
  defp etag(_source, %{etag: nil}), do: nil

  defp etag(source, %{etag: material}) do
    digest =
      :sha256
      |> :crypto.hash(Source.canonical(source) <> @separator <> material)
      |> Base.encode16(case: :lower)

    ~s("#{digest}")
  end

  # RFC 9110 §13.1.2's weak comparison, as on the render path: the header may
  # carry a list, and `W/` marks weakness without changing the tag it marks.
  # `*` is not matched — it means "if the resource exists", and answering it
  # 304 would claim the client's copy is current when nothing was compared.
  defp revalidated?(conn, source, stat) do
    case etag(source, stat) do
      nil ->
        false

      etag ->
        conn
        |> get_req_header("if-none-match")
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.map(&String.trim/1)
        |> Enum.any?(fn candidate -> strip_weak(candidate) == etag end)
    end
  end

  defp strip_weak("W/" <> tag), do: tag
  defp strip_weak(tag), do: tag
end
