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

  ## What the router owes the log

  `:endpoint_class` names the route in the log line and is what filters
  `/health` down to debug (`AudioProxy.LogHandler`). It is assigned here
  rather than in the pipeline because a 401 halts before any pipeline plug
  could say what the request was asking for. `Plug.RequestId` runs ahead of
  matching, so every line a request produces — its own and its render's —
  carries the same id, and the client gets it back in `x-request-id`.
  """

  use Plug.Router

  alias AudioProxy.Plugs.RenderPipeline

  @render_pipeline RenderPipeline.init([])

  plug Plug.RequestId
  plug :match
  plug :dispatch

  # `no-store`: liveness is only worth anything fresh, and a cached "ok"
  # would answer for a proxy that is down.
  get "/health" do
    conn
    |> assign(:endpoint_class, :health)
    |> put_resp_header("cache-control", "no-store")
    |> send_json(200, %{status: "ok", version: version()})
  end

  # Bodiless by construction rather than by adapter stripping, so what a test
  # sees is what the wire carries.
  head "/health" do
    conn
    |> assign(:endpoint_class, :health)
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, "")
  end

  get "/:sig/*rest" do
    conn
    |> assign(:endpoint_class, :render)
    |> RenderPipeline.call(@render_pipeline)
  end

  # Same pipeline as GET: every check runs, the action ends bodiless after
  # the stat instead of spawning a render.
  head "/:sig/*rest" do
    conn
    |> assign(:endpoint_class, :render)
    |> RenderPipeline.call(@render_pipeline)
  end

  match _ do
    conn
    |> assign(:endpoint_class, :unknown)
    |> assign(:error_class, :not_found)
    |> put_resp_header("cache-control", AudioProxy.ErrorJSON.cache_control(404))
    |> send_json(404, %{error: "not_found", message: "No such resource"})
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
