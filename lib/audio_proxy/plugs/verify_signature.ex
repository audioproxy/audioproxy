defmodule AudioProxy.Plugs.VerifySignature do
  @moduledoc """
  Gate for the signed URL space (API doc §1/§2).

  Splits `conn.request_path` into the signature segment and everything after
  it, then verifies with `AudioProxy.Signature.verify/2` — the signed string
  is the raw request path, so no re-encoding ambiguity can creep in.

  On success the rest-of-path (leading `/` included) is stashed in
  `conn.assigns[:rest_of_path]` for the downstream options/source parsers. On
  failure the plug halts with `401` and a JSON error body; a missing
  signature segment is just another invalid signature.

  Invariants downstream code must respect:

  - **Parse `assigns.rest_of_path`, never `path_info`.** The signature covers
    the raw request path, and `conn.path_info` cannot reproduce those bytes:
    `Plug.Conn.Adapter` builds it by splitting on `/` and *dropping empty
    segments* (`/{sig}//a` and `/{sig}/a` collide), and `Plug.Router`
    additionally percent-decodes its own copy for route matching. Neither
    form is the verified byte sequence.
  - **The signature covers the path only.** The query string and the HTTP
    method are not signed — never let an unsigned query param influence
    processing, and don't assume a signed URL is GET-only.
  - **`rest_of_path` can be `"/"`** (a request for `/{sig}/` with a valid
    signature). That carries no options/source; reject it downstream.

  Mount this plug on the signed routes only — `/health` (and later `/metrics`)
  live outside the signed URL space and must not pass through it.
  """

  @behaviour Plug

  import Plug.Conn

  alias AudioProxy.Signature

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, sig_segment, rest_of_path} <- split(conn.request_path),
         :ok <- Signature.verify(sig_segment, rest_of_path) do
      assign(conn, :rest_of_path, rest_of_path)
    else
      _ -> unauthorized(conn)
    end
  end

  # "/sig/rest/of/path" → {"sig", "/rest/of/path"}; anything without a second
  # segment ("/sig", "/", "") carries no signed content and is rejected.
  defp split(path) do
    case String.split(path, "/", parts: 3) do
      ["", sig_segment, rest] -> {:ok, sig_segment, "/" <> rest}
      _ -> {:error, :invalid_signature}
    end
  end

  defp unauthorized(conn) do
    body = JSON.encode!(%{error: "invalid_signature", message: "Invalid or missing signature"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
