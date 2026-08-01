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

  describe "the signed URL space" do
    # These hold under any config: an invalid signature is a 401 whether or
    # not keys are set and whether or not AP_ALLOW_INSECURE is on, so the
    # module stays async. Config-dependent signature cases (tampering,
    # insecure-disabled) live in AudioProxy.RenderEndpointTest.

    test "a signed-looking URL with an invalid signature is 401" do
      conn =
        request(
          :get,
          "/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/f:opus/br:96/plain/s3://b/k.wav"
        )

      assert conn.status == 401

      assert JSON.decode!(conn.resp_body) == %{
               "error" => "invalid_signature",
               "message" => "Invalid or missing signature"
             }
    end

    test "a single-segment path is a signature with no content — 401" do
      assert request(:get, "/nope").status == 401
    end

    test "verification runs ahead of dispatch: no sig, no error but 401" do
      # Bad options and an unknown scheme would be 422/404 after
      # verification; without a valid signature they are 401 first.
      assert request(:get, "/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/f:bogus/plain/s3://b/k").status ==
               401
    end
  end

  describe "unknown paths" do
    test "the root path matches no signed route and 404s" do
      conn = request(:get, "/")

      assert conn.status == 404
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      assert JSON.decode!(conn.resp_body) == %{
               "error" => "not_found",
               "message" => "No such resource"
             }
    end

    test "non-GET methods fall through to the 404" do
      assert request(:post, "/health").status == 404

      assert request(
               :post,
               "/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/f:opus/plain/s3://b/k.wav"
             ).status ==
               404
    end
  end
end
