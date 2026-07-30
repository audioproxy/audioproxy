defmodule AudioProxy.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  @opts AudioProxy.Router.init([])

  defp request(method, path) do
    conn(method, path) |> AudioProxy.Router.call(@opts)
  end

  describe "GET /health" do
    test "responds 200 with a small JSON body" do
      conn = request(:get, "/health")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      assert %{"status" => "ok", "version" => version} = JSON.decode!(conn.resp_body)
      assert version =~ ~r/^\d+\.\d+\.\d+/
    end

    test "requires no signature" do
      # The path carries neither a signature segment nor `insecure`, and the
      # response is still a 200 — /health is outside the signed URL space
      # (API doc §2).
      assert request(:get, "/health").status == 200
    end
  end

  describe "unknown paths" do
    test "respond 404 with a JSON body" do
      conn = request(:get, "/nope")

      assert conn.status == 404
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      assert JSON.decode!(conn.resp_body) == %{
               "error" => "not_found",
               "message" => "No such resource"
             }
    end

    test "a signed-looking render URL 404s until that slice lands" do
      assert request(:get, "/insecure/f:opus/br:96/plain/s3://masters/x.wav").status == 404
    end

    test "non-GET methods on /health also fall through to the 404" do
      assert request(:post, "/health").status == 404
    end
  end
end
