defmodule AudioProxy.InfoEndpointTest do
  @moduledoc """
  The signed info request path, end to end through the router.

  Same shape as `AudioProxy.RenderEndpointTest`, and for the same reason: the
  chain up to the action is the production one, and what runs at the end is
  `test/support/fake_ffprobe.sh` rather than the real binary — because the
  cases worth pinning here are the ones a real prober cannot produce on demand
  (a hang, output that is not JSON) and the ones that are properties of the
  action rather than of ffprobe (the validator, the 304, the error mapping).
  `AudioProxy.InfoEndpointFfmpegTest` is where a real `ffprobe` answers for the
  contract itself.
  """

  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper
  import AudioProxy.ProbeCoalesceHelper
  import Plug.Conn
  import Plug.Test

  alias AudioProxy.Signature

  @moduletag tmp_dir: "info_endpoint"

  @key Base.decode16!("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")
  @salt Base.decode16!("FFEEDDCCBBAA99887766554433221100")

  @opts AudioProxy.Router.init([])
  @fake_opts AudioProxy.FakeFfmpeg.Router.init([])

  @generic_404 %{"error" => "not_found", "message" => "Source not found"}

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "piece.wav"), "RIFF-fake-wav-bytes")
    File.write!(Path.join(tmp_dir, "tagged.mp3"), "ID3-fake-mp3-bytes")
    File.write!(Path.join(tmp_dir, "unprobeable.txt"), "definitely not audio")
    File.write!(Path.join(tmp_dir, "silent.mp4"), "fake-mp4-bytes")
    File.write!(Path.join(tmp_dir, "garbage.wav"), "fake-bytes")
    File.write!(Path.join(tmp_dir, "probehang.wav"), "fake-bytes")
    File.write!(Path.join(tmp_dir, "video.mp4"), "fake-bytes")
    File.write!(Path.join(tmp_dir, "cover.mp3"), "fake-bytes")

    put_config(%{
      key: @key,
      salt: @salt,
      allow_insecure: false,
      local_root: tmp_dir,
      max_src_bytes: 2_000_000_000,
      max_variant_bytes: 2_000_000_000,
      # Short enough that the timeout test is not the slowest in the suite,
      # long enough that a loaded machine does not trip it spuriously.
      probe_timeout: 1
    })

    reset_probes()

    :ok
  end

  defp signed(rest), do: "/#{Signature.sign(rest, @key, @salt)}#{rest}"

  # The production router, for everything that halts before the action.
  defp get(path), do: conn(:get, path) |> AudioProxy.Router.call(@opts)

  # The same chain with the stand-in prober, for everything that reaches it.
  defp info(path, headers \\ []), do: request(:get, path, headers)

  defp request(method, path, headers) do
    headers
    |> Enum.reduce(conn(method, path), fn {k, v}, c -> put_req_header(c, k, v) end)
    |> AudioProxy.FakeFfmpeg.Router.call(@fake_opts)
  end

  defp header(conn, name) do
    case get_resp_header(conn, name) do
      [value | _rest] -> value
      [] -> nil
    end
  end

  describe "the §4 object" do
    test "a probed source answers 200 with the contract as JSON" do
      conn = info(signed("/info/plain/local://piece.wav"))

      assert conn.status == 200
      assert header(conn, "content-type") =~ "application/json"

      assert JSON.decode!(conn.resp_body) == %{
               "format" => "wav",
               "duration" => 5.0,
               "sample_rate" => 48_000,
               "channels" => 2,
               "bit_depth" => 16,
               "bitrate" => 1_536_000,
               # The stat's size, not the fixture's — the store is
               # authoritative for the object, and the stand-in claims 960044.
               "size" => 19
             }
    end

    test "a tagged lossy source reports its tags and no bit depth" do
      conn = info(signed("/info/plain/local://tagged.mp3"))

      assert conn.status == 200
      info = JSON.decode!(conn.resp_body)

      assert info["tags"] == %{
               "title" => "Sea Change",
               "artist" => "Test Artist",
               "track" => "3"
             }

      assert info["bitrate"] == 128_000
      refute Map.has_key?(info, "bit_depth")
    end
  end

  describe "options are rejected on info requests" do
    test "an option alongside info is a 422 naming the segment" do
      conn = get(signed("/info/br:128/plain/local://piece.wav"))

      assert conn.status == 422
      assert %{"error" => "invalid_options", "message" => message} = JSON.decode!(conn.resp_body)
      assert message =~ ~s("br:128")
      assert message =~ ~s("info")
    end

    test "the order of the segments does not change the verdict" do
      assert get(signed("/br:128/info/plain/local://piece.wav")).status == 422
      assert get(signed("/f:mp3/info/f:opus/plain/local://piece.wav")).status == 422
    end

    test "the chain halts before the source is even resolved" do
      conn = get(signed("/info/f:opus/plain/local://piece.wav"))

      assert conn.status == 422
      assert conn.halted

      # Asserted through the assigns rather than by counting children of
      # `Ffmpeg.RenderSupervisor`: that supervisor is a global shared by every
      # test in the run, so a render another module started and has not yet
      # reaped makes an emptiness check fail for reasons that have nothing to
      # do with this request. An absent `:source` is the local fact, and the
      # stronger one — the chain stopped at `ParseOptions`, two plugs before
      # anything could spawn.
      refute Map.has_key?(conn.assigns, :source)
      refute Map.has_key?(conn.assigns, :action)
    end
  end

  describe "caching" do
    test "a strong ETag and a revalidatable Cache-Control travel with the 200" do
      conn = info(signed("/info/plain/local://piece.wav"))

      assert header(conn, "cache-control") == "public, max-age=3600"
      assert etag = header(conn, "etag")
      assert etag =~ ~r/^"[0-9a-f]{64}"$/
      # Not immutable: /info describes a mutable source, and a cache that never
      # revalidates could never be corrected.
      refute header(conn, "cache-control") =~ "immutable"
    end

    test "repeating the request with the ETag is a 304 with no body" do
      first = info(signed("/info/plain/local://piece.wav"))
      etag = header(first, "etag")

      second = info(signed("/info/plain/local://piece.wav"), [{"if-none-match", etag}])

      assert second.status == 304
      assert second.resp_body == ""
      assert header(second, "etag") == etag
      assert header(second, "cache-control") == "public, max-age=3600"
    end

    test "a weak spelling and a list both revalidate" do
      etag = header(info(signed("/info/plain/local://piece.wav")), "etag")

      weak = info(signed("/info/plain/local://piece.wav"), [{"if-none-match", "W/#{etag}"}])
      other = info(signed("/info/plain/local://piece.wav"), [{"if-none-match", ~s("x")}])

      listed =
        info(signed("/info/plain/local://piece.wav"), [{"if-none-match", ~s("x", ) <> etag}])

      assert weak.status == 304
      assert other.status == 200
      assert listed.status == 304
    end

    test "the validator changes when the source does" do
      before = header(info(signed("/info/plain/local://piece.wav")), "etag")

      # The local backend's ETag material is size and mtime; a rewrite of a
      # different length changes it whatever the clock resolution is.
      path = Path.join(AudioProxy.Config.get(:local_root), "piece.wav")
      File.write!(path, "RIFF-fake-wav-bytes-and-then-some")

      assert header(info(signed("/info/plain/local://piece.wav")), "etag") != before
    end

    test "two different sources do not share a validator" do
      one = header(info(signed("/info/plain/local://piece.wav")), "etag")
      other = header(info(signed("/info/plain/local://tagged.mp3")), "etag")

      assert one != other
    end
  end

  describe "errors" do
    test "a source ffprobe cannot parse is 415" do
      conn = info(signed("/info/plain/local://unprobeable.txt"))

      assert conn.status == 415
      assert JSON.decode!(conn.resp_body)["error"] == "undecodable_source"
      assert header(conn, "cache-control") == "max-age=10"
    end

    test "a source carrying video is 415, the same answer a render gets" do
      conn = info(signed("/info/plain/local://video.mp4"))

      assert conn.status == 415
      assert JSON.decode!(conn.resp_body)["error"] == "video_source"
      assert header(conn, "cache-control") == "max-age=10"
    end

    test "cover art is not video: a tagged mp3 with artwork is described" do
      conn = info(signed("/info/plain/local://cover.mp3"))

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body)["format"] == "mp3"
    end

    test "a source with no audio stream is 415 too" do
      conn = info(signed("/info/plain/local://silent.mp4"))

      assert conn.status == 415
      assert JSON.decode!(conn.resp_body)["error"] == "undecodable_source"
    end

    test "a probe that outruns AP_PROBE_TIMEOUT is 504" do
      conn = info(signed("/info/plain/local://probehang.wav"))

      assert conn.status == 504
      assert JSON.decode!(conn.resp_body)["error"] == "probe_timeout"
      assert header(conn, "cache-control") == "no-store"
    end

    test "output that is not JSON is 500, not a crash" do
      conn = info(signed("/info/plain/local://garbage.wav"))

      assert conn.status == 500
      assert JSON.decode!(conn.resp_body)["error"] == "probe_failed"
      assert header(conn, "cache-control") == "no-store"
    end

    test "a missing source is the same blind 404 the render path gives" do
      conn = get(signed("/info/plain/local://nope.wav"))

      assert conn.status == 404
      assert JSON.decode!(conn.resp_body) == @generic_404
    end

    test "a source outside the root is the same 404" do
      conn = get(signed("/info/plain/local://../etc/passwd"))

      assert conn.status == 404
      assert JSON.decode!(conn.resp_body) == @generic_404
    end

    test "a source over AP_MAX_SRC_BYTES is still described" do
      # Unlike the render path. A probe reads headers, so the limit buys
      # nothing here — and the long source is exactly the one a client needs
      # described before it can ask for a trimmed preview of it.
      put_config(%{max_src_bytes: 1})

      conn = info(signed("/info/plain/local://piece.wav"))

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body)["format"] == "wav"
    end

    test "the render path still refuses the same source" do
      put_config(%{max_src_bytes: 1})

      assert get(signed("/f:mp3/plain/local://piece.wav")).status == 413
    end

    test "an unsigned info request is 401 before anything else" do
      assert get("/info/plain/local://piece.wav").status == 401
      assert get("/nonsense/info/plain/local://piece.wav").status == 401
    end
  end

  describe "HEAD" do
    test "answers the headers a GET would, bodiless and without probing" do
      get_conn = info(signed("/info/plain/local://piece.wav"))
      head_conn = request(:head, signed("/info/plain/local://piece.wav"), [])

      assert head_conn.status == 200
      assert head_conn.resp_body == ""
      assert header(head_conn, "etag") == header(get_conn, "etag")
      assert header(head_conn, "cache-control") == header(get_conn, "cache-control")
    end

    test "answers 200 where the GET answers 415, because diagnosing it is the probe" do
      assert request(:head, signed("/info/plain/local://unprobeable.txt"), []).status == 200
      assert info(signed("/info/plain/local://unprobeable.txt")).status == 415
    end

    test "still answers everything the check chain can determine" do
      assert request(:head, signed("/info/plain/local://nope.wav"), []).status == 404
    end
  end
end
