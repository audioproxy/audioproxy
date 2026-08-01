defmodule AudioProxy.RenderEndpointTest do
  @moduledoc """
  The signed render request path, end to end through the router: signature,
  options, source, stat — and then the 501 placeholder, which is as far as a
  valid request gets until `add-render-endpoint` replaces the action.

  All of it is `Plug.Test`: the chain spawns no subprocess, so the only state
  to arrange is config (key/salt, the local root, the size limit) and files
  under a per-test tmp dir.
  """

  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper
  import Plug.Conn
  import Plug.Test

  alias AudioProxy.Signature

  @moduletag tmp_dir: "render_endpoint"

  @key Base.decode16!("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")
  @salt Base.decode16!("FFEEDDCCBBAA99887766554433221100")

  @opts AudioProxy.Router.init([])

  @piece_content "RIFF-fake-wav-bytes"
  @generic_404 %{"error" => "not_found", "message" => "Source not found"}

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "piece.wav"), @piece_content)
    File.write!(Path.join(tmp_dir, "a track.wav"), "RIFF")

    # Pin every config value the chain reads: a boot-time AP_MAX_SRC_BYTES in
    # the environment must not be able to flip these tests' 501s to 413s.
    put_config(%{
      key: @key,
      salt: @salt,
      allow_insecure: false,
      local_root: tmp_dir,
      max_src_bytes: 2_000_000_000
    })

    :ok
  end

  defp get(path) do
    conn(:get, path) |> AudioProxy.Router.call(@opts)
  end

  defp signed(rest) do
    "/#{Signature.sign(rest, @key, @salt)}#{rest}"
  end

  describe "signature gate (see also RouterTest)" do
    test "the insecure segment is 401 while AP_ALLOW_INSECURE is off" do
      assert get("/insecure/f:mp3/plain/local://piece.wav").status == 401
    end

    test "a tampered path is 401" do
      rest = "/f:opus/br:96/plain/local://piece.wav"
      sig = Signature.sign(rest, @key, @salt)

      assert get("/#{sig}/f:opus/br:128/plain/local://piece.wav").status == 401
    end

    test "a path with no signature segment worth the name is 401, not dispatch" do
      assert get("/f:mp3/plain/local://piece.wav").status == 401
    end
  end

  describe "reachable errors end to end" do
    test "an unknown option is a 422 naming the segment" do
      conn = get(signed("/nope:1/plain/local://piece.wav"))

      assert conn.status == 422

      assert %{"error" => "invalid_options", "message" => message} =
               JSON.decode!(conn.resp_body)

      assert message =~ ~s("nope:1")
    end

    test "a disallowed source is the generic 404" do
      conn = get(signed("/f:mp3/plain/local://../secret.wav"))

      assert conn.status == 404
      assert JSON.decode!(conn.resp_body) == @generic_404
    end

    test "a missing file is the generic 404" do
      conn = get(signed("/f:mp3/plain/local://missing.wav"))

      assert conn.status == 404
      assert JSON.decode!(conn.resp_body) == @generic_404
    end

    test "a source exceeding AP_MAX_SRC_BYTES is a 413" do
      put_config(%{max_src_bytes: byte_size(@piece_content) - 1})

      conn = get(signed("/f:mp3/plain/local://piece.wav"))

      assert conn.status == 413
      assert JSON.decode!(conn.resp_body)["error"] == "source_too_large"
    end

    test "a source of exactly AP_MAX_SRC_BYTES is allowed through" do
      put_config(%{max_src_bytes: byte_size(@piece_content)})

      assert get(signed("/f:mp3/plain/local://piece.wav")).status == 501
    end

    test "a malformed escape in a signed request is the generic 404, never a bare 400" do
      # Tripwire for Plug.Router's match-time decode: if a Plug upgrade starts
      # raising MalformedURIError on %zz, hostile paths get a bare 400 *before*
      # VerifySignature — breaking both the uniform 404 and 401-first. The
      # current Plug version matches the route without decoding; keep it pinned.
      conn = get(signed("/f:mp3/plain/local://a%zztrack.wav"))

      assert conn.status == 404
      assert JSON.decode!(conn.resp_body) == @generic_404
    end

    test "an existing, oversized file outside the root is 404, not 413", %{tmp_dir: tmp_dir} do
      # Authorize-before-stat on the wire: the file exists and exceeds the
      # limit, but confinement refuses it before size is ever read.
      File.write!(Path.join(tmp_dir, "../big-outside-root.wav"), String.duplicate("x", 64))
      put_config(%{max_src_bytes: 10})

      conn = get(signed("/f:mp3/plain/local://../big-outside-root.wav"))

      assert conn.status == 404
      assert JSON.decode!(conn.resp_body) == @generic_404
    end
  end

  describe "the 404 is deliberately blind" do
    test "unauthorized and missing sources answer byte-identical responses" do
      disallowed = get(signed("/f:mp3/plain/local://../secret.wav"))
      missing = get(signed("/f:mp3/plain/local://missing.wav"))

      assert disallowed.status == 404
      assert missing.status == 404
      assert disallowed.resp_body == missing.resp_body

      assert get_resp_header(disallowed, "content-type") ==
               get_resp_header(missing, "content-type")
    end
  end

  describe "the placeholder" do
    # Pinned so the gap is visible: add-render-endpoint replaces the action
    # and removes this test.
    test "a fully valid request is a 501 naming the missing capability" do
      conn = get(signed("/f:opus/br:96/plain/local://piece.wav"))

      assert conn.status == 501

      assert JSON.decode!(conn.resp_body) == %{
               "error" => "not_implemented",
               "message" => "Rendering is not implemented yet"
             }
    end

    test "a valid request with escapes in the filename reaches the action" do
      # The signature covers the raw %20 spelling; the source parser decodes
      # exactly once; stat finds the file on disk — the whole raw-bytes
      # round trip this chain exists to protect.
      assert get(signed("/f:mp3/plain/local://a%20track.wav")).status == 501
    end
  end
end
