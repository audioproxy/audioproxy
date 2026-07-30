defmodule AudioProxy.Router do
  @moduledoc """
  Top-level HTTP router.

  Only the unsigned endpoints exist so far. The signed render, `info`, and
  `metrics` routes from `docs/audio-proxy-api-v1.md` §2 arrive with their own
  slices; until then everything but `/health` falls through to the JSON 404.
  """

  use Plug.Router

  plug :match
  plug :dispatch

  get "/health" do
    send_json(conn, 200, %{status: "ok", version: version()})
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
