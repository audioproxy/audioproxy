defmodule AudioProxy.Router do
  @moduledoc """
  Top-level HTTP router.

  `/health` is unsigned liveness. Everything else in the signed URL space —
  today only the render endpoint — is dispatched to a pipeline that verifies
  the signature before any other processing; an unsigned or badly-signed
  request is a 401 from there, and anything that matches no route at all is
  the JSON 404 below. The `info` and `metrics` routes from
  `docs/audio-proxy-api-v1.md` §2 arrive with their own slices.

  The render route binds `:sig` and `rest` for dispatch only. Neither binding
  is read downstream: the signature covers the raw request path, which
  `AudioProxy.Plugs.VerifySignature` re-splits from `conn.request_path` —
  route bindings are percent-decoded and re-segmented, so they can never
  reproduce the signed bytes.
  """

  use Plug.Router

  alias AudioProxy.Plugs.RenderPipeline

  @render_pipeline RenderPipeline.init([])

  plug :match
  plug :dispatch

  get "/health" do
    send_json(conn, 200, %{status: "ok", version: version()})
  end

  get "/:sig/*rest" do
    RenderPipeline.call(conn, @render_pipeline)
  end

  match _ do
    send_json(conn, 404, %{error: "not_found", message: "No such resource"})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  defp version do
    :audio_proxy |> Application.spec(:vsn) |> to_string()
  end
end
