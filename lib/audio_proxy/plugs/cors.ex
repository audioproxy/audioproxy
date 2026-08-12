defmodule AudioProxy.Plugs.Cors do
  @moduledoc """
  CORS response headers and the preflight answer, gated on `AP_ALLOW_ORIGIN`.

  Unset — the default — this plug is a no-op: no `Access-Control-*` header on
  any response, and `OPTIONS` falls through to the router's 404 like every
  other non-GET method. Set, every response the main listener produces carries
  the allow header, including the §5 error envelopes: a page that cannot read
  a 422 is a page that can only report "something went wrong".

  ## Why `register_before_send`

  The headers belong on *every* response, and the responses come from
  everywhere — the router's own 404, a 401 halted in
  `AudioProxy.Plugs.VerifySignature`, the 302 a variant HIT redirects with,
  the chunked stream `AudioProxy.Plugs.RenderAction` opens. A callback
  registered once at the top of the chain is the only place all of those pass
  through; setting the headers here directly would cover the ones that halt
  in this plug and nothing else.

  ## Expose-headers, and why it is not empty

  The CORS filter hides every response header from a reading page except the
  safelisted handful, and the three this API expects a client to act on are
  all outside it: `Retry-After` on the queue-full 429 (without it a page sees
  the 429 but not how long to wait), `x-audio-proxy` for anyone measuring
  HIT/MISS, and `Accept-Ranges`/`ETag` on a served variant.
  """

  @behaviour Plug

  import Plug.Conn

  alias AudioProxy.Config

  @expose_headers "x-audio-proxy, retry-after, accept-ranges, etag"

  # A day, the ceiling Chromium enforces. The preflight answer is a function
  # of configuration, not of the request, so nothing it says goes stale before
  # the process that said it is restarted.
  @max_age "86400"

  # The methods the signed URL space answers. `OPTIONS` itself is deliberately
  # absent: it is the question, not one of the answers.
  @allow_methods "GET, HEAD"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: cors(conn, Config.get(:allow_origin))

  defp cors(conn, nil), do: conn

  defp cors(conn, origin) do
    conn = register_before_send(conn, &put_cors_headers(&1, origin))

    if conn.method == "OPTIONS", do: preflight(conn), else: conn
  end

  defp put_cors_headers(conn, origin) do
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-expose-headers", @expose_headers)
    |> vary_on_origin(origin)
  end

  # `*` is the same answer for every origin, so nothing downstream may key a
  # cache on a header that did not affect the response. A named origin is the
  # opposite: the response *is* origin-specific to a cache that cannot see the
  # configuration behind it.
  defp vary_on_origin(conn, "*"), do: conn

  # Appended rather than assigned. Nothing sets `Vary` today, but before-send
  # callbacks run newest-first, and every plug below this one registers later
  # — so this callback runs after all of theirs, and an assignment here would
  # be the one that silently won. A response that had negotiated on
  # `Accept-Encoding` would lose the header saying so.
  defp vary_on_origin(conn, _origin) do
    update_resp_header(conn, "vary", "Origin", fn existing ->
      if origin_in_vary?(existing), do: existing, else: existing <> ", Origin"
    end)
  end

  defp origin_in_vary?(vary) do
    vary
    |> String.split(",")
    |> Enum.any?(&(&1 |> String.trim() |> String.downcase() == "origin"))
  end

  # The one scoped exception to API doc §2's "methods other than GET answer
  # 404, everywhere". It halts before `:match`, so the preflight never reaches
  # signature verification — which is correct rather than lax: a preflight
  # carries neither the signature's credentials nor a body, and answering it
  # confirms only what the operator already told this origin by naming it.
  defp preflight(conn) do
    conn
    |> assign(:endpoint_class, :preflight)
    |> put_resp_header("access-control-allow-methods", @allow_methods)
    |> put_resp_header("access-control-max-age", @max_age)
    |> echo_requested_headers()
    |> send_resp(204, "")
    |> halt()
  end

  # Echoed rather than enumerated: the request headers a client sends are its
  # business, the URL carries the credentials, and a fixed list would have to
  # be edited every time a caller added a `Cache-Control` or a trace header.
  #
  # Echoed *filtered*, though. What comes back is a comma-separated list of
  # header names, and a name is an RFC 9110 token; anything else in the
  # request is not something a browser sent, and reflecting it would put a
  # malformed header on the wire — or, for the control characters `Plug`
  # refuses outright, raise from inside a before-send callback. Dropping the
  # junk answers the preflight for whatever was legitimate and stays quiet
  # about the rest.
  defp echo_requested_headers(conn) do
    with [requested | _rest] <- get_req_header(conn, "access-control-request-headers"),
         [_ | _] = tokens <-
           requested |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.filter(&token?/1) do
      put_resp_header(conn, "access-control-allow-headers", Enum.join(tokens, ", "))
    else
      _nothing_to_echo -> conn
    end
  end

  # RFC 9110 §5.6.2's `tchar` set, trimmed of the surrounding whitespace the
  # list grammar allows.
  defp token?(candidate), do: Regex.match?(~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/, candidate)
end
