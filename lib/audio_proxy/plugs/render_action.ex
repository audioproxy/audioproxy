defmodule AudioProxy.Plugs.RenderAction do
  @moduledoc """
  The render endpoint's action — currently a placeholder.

  This is the seam `add-render-endpoint` replaces with the streaming action.
  What lives here already is everything a valid request must survive *before*
  a render could start: `AudioProxy.Source.stat/1` answers a missing (or
  non-regular, or gone-unreadable) source with the same generic 404 as an
  unauthorized one, and a source whose size exceeds `AP_MAX_SRC_BYTES` with
  413. A source of unknown size passes — `AP_MAX_SRC_BYTES` is then the render
  pipeline's byte cap, per the `AudioProxy.Source.Type` contract.

  What does not live here yet is the render itself, so a request that passes
  every check is answered `501` with a JSON body naming the missing
  capability. 501 rather than 404: the resource is valid, the capability is
  absent, and a 404 would be indistinguishable from the no-oracle 404s above.
  The pinning test is removed by `add-render-endpoint`.
  """

  @behaviour Plug

  import Plug.Conn

  alias AudioProxy.{Config, ErrorJSON, Source}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, stat} <- Source.stat(conn.assigns.source),
         :ok <- within_limit(stat.size) do
      not_implemented(conn)
    else
      {:error, reason} -> ErrorJSON.halt_with(conn, reason)
    end
  end

  # `nil` size means the backing store does not know it; refusing outright
  # would make the proxy less capable than the ffmpeg it drives, so the limit
  # is enforced downstream by the render byte cap instead.
  defp within_limit(nil), do: :ok

  defp within_limit(size) do
    if size > Config.get(:max_src_bytes), do: {:error, :source_too_large}, else: :ok
  end

  defp not_implemented(conn) do
    body =
      JSON.encode!(%{error: "not_implemented", message: "Rendering is not implemented yet"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(501, body)
    |> halt()
  end
end
