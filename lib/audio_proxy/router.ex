defmodule AudioProxy.Router do
  @moduledoc """
  Top-level HTTP router.

  `/health` is unsigned liveness and `/ready` unsigned readiness — the first
  says the VM is up, the second says this node should be sent new work (see
  `AudioProxy.Readiness`, and `docs/scaling.md` for how to wire them).
  `/llms.txt` and `/llms-full.txt` are unsigned too, and necessarily so: a
  document explaining how to sign a URL cannot itself sit behind a signature.
  Everything else in the signed URL space — the render endpoint and `/info`,
  which share a route — is dispatched to a pipeline that verifies the
  signature before any other processing; an unsigned or badly-signed request
  is a 401 from there, and anything that matches no route at all is the JSON
  404 below. `/metrics` is deliberately *not* here — it has a listener of its
  own (`AudioProxy.Metrics.Router`), and the route below says so with a 404
  rather than letting it fall through to the signed one.

  The signed route binds `:sig` and `rest` for dispatch only. Neither binding
  is read downstream: the signature covers the raw request path, which
  `AudioProxy.Plugs.VerifySignature` re-splits from `conn.request_path` —
  route bindings are percent-decoded and re-segmented, so they can never
  reproduce the signed bytes.

  ## What the router owes the log

  `:endpoint_class` names the route in the log line and is what filters
  `/health` down to debug (`AudioProxy.LogHandler`). It is assigned here
  rather than in the pipeline because a 401 halts before any pipeline plug
  could say what the request was asking for — which is also why the signed
  route assigns `:render` rather than the truth: only
  `AudioProxy.Plugs.ParseOptions` can tell a render from an info request, and
  it re-assigns `:info` once it has. `Plug.RequestId` runs ahead of
  matching, so every line a request produces — its own and its render's —
  carries the same id, and the client gets it back in `x-request-id`.
  """

  use Plug.Router

  alias AudioProxy.Llms
  alias AudioProxy.Plugs.RenderPipeline
  alias AudioProxy.Readiness

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

  # Readiness, not liveness: a 503 here means "route elsewhere", never
  # "restart me". `no-store` for the same reason `/health` has it — a cached
  # verdict is advice about a load level that has since moved.
  get "/ready" do
    %{ready?: ready?, queued: queued, threshold: threshold} = Readiness.check()

    conn
    |> assign(:endpoint_class, :ready)
    |> put_resp_header("cache-control", "no-store")
    |> send_json(ready_status(ready?), %{
      status: if(ready?, do: "ready", else: "not_ready"),
      queued: queued,
      threshold: threshold
    })
  end

  head "/ready" do
    %{ready?: ready?} = Readiness.check()

    conn
    |> assign(:endpoint_class, :ready)
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(ready_status(ready?), "")
  end

  # The llms.txt pair (llmstxt.org): unsigned, like the probes, because a
  # document describing how to sign a URL is no use behind a signature.
  #
  # Cacheable for a day rather than the year a variant gets: these URLs are
  # not content-addressed, so a deploy changes what they answer, and an edge
  # holding yesterday's copy would describe yesterday's API. A day is long
  # enough that an agent re-reading the docs costs the origin nothing.
  match "/llms.txt", via: [:get, :head] do
    send_markdown(conn, Llms.index())
  end

  match "/llms-full.txt", via: [:get, :head] do
    send_markdown(conn, Llms.full())
  end

  # `/metrics` is served on its own listener (`AudioProxy.Metrics.Router`), and
  # saying so here is the only way this listener answers what it means. Without
  # the route it would match the signed one below with an empty `rest`, and an
  # operator who pointed a scraper at the wrong port would get a 401 about a
  # signature — a message about the wrong problem entirely. It is also the
  # honest status: the scrape surface is genuinely not here.
  match "/metrics", via: [:get, :head] do
    not_found(conn)
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
    not_found(conn)
  end

  defp not_found(conn) do
    conn
    |> assign(:endpoint_class, :unknown)
    |> assign(:error_class, :not_found)
    |> put_resp_header("cache-control", AudioProxy.ErrorJSON.cache_control(404))
    |> send_json(404, %{error: "not_found", message: "No such resource"})
  end

  defp ready_status(true), do: 200
  defp ready_status(false), do: 503

  # HEAD answers the GET's status and headers bodiless, as `/health` and
  # `/ready` do — by construction here rather than by adapter stripping.
  defp send_markdown(conn, body) do
    conn
    |> assign(:endpoint_class, :llms)
    |> put_resp_content_type("text/markdown")
    |> put_resp_header("cache-control", "public, max-age=86400")
    |> send_resp(200, if(conn.method == "HEAD", do: "", else: body))
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
