defmodule AudioProxy.Metrics.Router do
  @moduledoc """
  The scrape surface, and nothing else.

  API doc §2 makes `GET /metrics` unsigned and bind-address-restricted, and
  this router is how the second half of that is enforced: it is mounted on its
  own Bandit listener bound to `AP_METRICS_BIND` (`AudioProxy.Application`),
  rather than added to `AudioProxy.Router` behind a plug that checks the peer
  address. Two reasons, in order of weight.

  A bind is a guarantee the kernel makes; a peer check is a guarantee this
  code makes, and the difference shows up behind a proxy, where the peer
  address is the proxy's and every check that reads one has to decide how much
  of `X-Forwarded-For` to believe. Nothing here has to decide anything: an
  interface that is not bound cannot be connected to.

  And the surface stays honest. This router serves one route. There is no
  ordering between it and the signed route to get wrong, no chance of a future
  `/metrics/…` falling through to the render pipeline, and a request for
  anything else on this port is a 404 rather than a path into the API.

  ## Scrapes are requests too

  `:endpoint_class` is assigned, so a scrape appears in the log at debug
  alongside the probes, and counts in `audio_proxy_http_requests_total` under
  `endpoint="metrics"`. Counting itself is not circular — the exposition is
  rendered before this request's own stop event fires, so a scrape reports the
  scrape before it, which is exactly what a monotonically increasing counter
  is for. What it buys is that a scraper failing to reach this port is visible
  from the last scrape that did.
  """

  use Plug.Router

  alias AudioProxy.Metrics
  alias AudioProxy.Metrics.Exposition

  plug :match
  plug :dispatch

  # `no-store` for the reason `/health` has it: a cached scrape is a
  # measurement of a moment that has passed, and the whole point of the
  # endpoint is that the moment is now.
  get "/metrics" do
    conn
    |> expose()
    |> send_resp(200, Metrics.scrape())
  end

  # Bodiless by construction rather than by adapter stripping, so what a test
  # sees is what the wire carries. A scraper that HEADs is checking the target
  # is up, and does not need the numbers rendered to find out.
  head "/metrics" do
    conn
    |> expose()
    |> send_resp(200, "")
  end

  match _ do
    conn
    |> assign(:endpoint_class, :unknown)
    |> assign(:error_class, :not_found)
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "not_found\n")
  end

  defp expose(conn) do
    conn
    |> assign(:endpoint_class, :metrics)
    |> put_resp_content_type(Exposition.content_type(), nil)
    |> put_resp_header("cache-control", "no-store")
  end
end
