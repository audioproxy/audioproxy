defmodule AudioProxy.Plugs.VerifySignatureTest do
  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper
  import AudioProxy.SignedRequest, except: [conn: 3]
  import Plug.Conn
  import Plug.Test

  alias AudioProxy.Plugs.VerifySignature
  alias AudioProxy.Signature

  @rest "/f:opus/br:96/plain/s3://masters/2026/piece-final.wav"

  setup do
    put_config(%{key: key(), salt: salt(), allow_insecure: false})
    :ok
  end

  defp call(path) do
    conn(:get, path) |> VerifySignature.call([])
  end

  describe "a valid signature" do
    test "passes the conn through unhalted" do
      conn = call("/#{Signature.sign(@rest, key(), salt())}#{@rest}")

      assert conn.status == nil
      refute conn.halted
    end

    test "stashes the rest-of-path in assigns for downstream parsers" do
      conn = call("/#{Signature.sign(@rest, key(), salt())}#{@rest}")

      assert conn.assigns[:rest_of_path] == @rest
    end

    test "verifies the raw path, not a re-encoded form" do
      rest = "/f:mp3/plain/s3://bucket/a%20track.wav"
      conn = call("/#{Signature.sign(rest, key(), salt())}#{rest}")

      refute conn.halted
      assert conn.assigns[:rest_of_path] == rest
    end
  end

  describe "an invalid signature" do
    test "halts with 401 and a JSON error body" do
      conn = call("/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA#{@rest}")

      assert conn.halted
      assert conn.status == 401
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      assert JSON.decode!(conn.resp_body) == %{
               "error" => "invalid_signature",
               "message" => "Invalid or missing signature"
             }
    end

    test "a tampered rest-of-path is 401" do
      conn =
        call("/#{Signature.sign(@rest, key(), salt())}/f:opus/br:128/plain/s3://masters/x.wav")

      assert conn.status == 401
    end

    test "a missing signature segment is 401, not a crash" do
      assert call("/").status == 401
      assert call("/onlyonesegment").status == 401
    end
  end

  describe "insecure mode" do
    test "passes with the literal insecure segment when AP_ALLOW_INSECURE is set" do
      put_config(%{allow_insecure: true})

      conn = call("/insecure#{@rest}")

      refute conn.halted
      assert conn.assigns[:rest_of_path] == @rest
    end

    test "the literal insecure segment is 401 by default" do
      assert call("/insecure#{@rest}").status == 401
    end
  end

  describe "unsigned endpoints" do
    test "/health stays outside the signed URL space" do
      conn = conn(:get, "/health") |> AudioProxy.Router.call(AudioProxy.Router.init([]))

      assert conn.status == 200
    end
  end

  # A mounted pipeline: the plug in front of a 200 stub, the way
  # add-render-endpoint will mount it. Guards the signed/unsigned boundary —
  # an unsigned request must never reach downstream code.
  defmodule BoundaryPipeline do
    use Plug.Builder

    plug AudioProxy.Plugs.VerifySignature

    plug :ok

    defp ok(conn, _opts), do: send_resp(conn, 200, "rendered")
  end

  describe "mounted in a pipeline" do
    test "an unsigned request 401s before reaching downstream" do
      conn = conn(:get, "/nosig/f:opus/br:96/plain/s3://b/k.wav") |> BoundaryPipeline.call([])

      assert conn.status == 401
      refute conn.resp_body == "rendered"
    end

    test "a signed request reaches downstream" do
      sig = Signature.sign(@rest, key(), salt())
      conn = conn(:get, "/#{sig}#{@rest}") |> BoundaryPipeline.call([])

      assert conn.status == 200
      assert conn.resp_body == "rendered"
    end
  end

  describe "signature coverage invariants" do
    test "the query string is not covered by the signature" do
      sig = Signature.sign(@rest, key(), salt())
      conn = call("/#{sig}#{@rest}?anything=x")

      # Pinned deliberately: verification ignores the query, so downstream
      # must never let a param influence processing (see plug moduledoc).
      refute conn.halted
      assert conn.assigns[:rest_of_path] == @rest
    end

    test "the HTTP method is not covered by the signature" do
      sig = Signature.sign(@rest, key(), salt())
      conn = conn(:post, "/#{sig}#{@rest}") |> VerifySignature.call([])

      refute conn.halted
    end

    test "a request for /{sig}/ carries an empty rest-of-path" do
      sig = Signature.sign("/", key(), salt())
      conn = call("/#{sig}/")

      refute conn.halted
      assert conn.assigns[:rest_of_path] == "/"
    end
  end
end
