defmodule AudioProxy.RenderEndpointTest do
  @moduledoc """
  The signed render request path, end to end through the router: signature,
  options, source, stat — and, for a request that survives all of it, the
  streaming action's response head.

  All of it is `Plug.Test`. The error paths halt before any subprocess is
  spawned, and the requests that do reach the action render through
  `AudioProxy.FakeFfmpeg` rather than the real encoder, so the only state to
  arrange is config (key/salt, the local root, the size limit) and files under
  a per-test tmp dir. What `Plug.Test` cannot show — chunk cadence, a client
  that disappears, a stream torn down after its 200 — belongs to
  `AudioProxy.RenderEndpointStreamTest`, over a real socket.
  """

  use ExUnit.Case, async: false

  import AudioProxy.CoalesceHelper
  import AudioProxy.ConfigHelper
  import Plug.Conn
  import Plug.Test

  alias AudioProxy.Signature

  @moduletag tmp_dir: "render_endpoint"

  @key Base.decode16!("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")
  @salt Base.decode16!("FFEEDDCCBBAA99887766554433221100")

  @opts AudioProxy.Router.init([])
  @fake_opts AudioProxy.FakeFfmpeg.Router.init([])
  @payload "fake-audio-payload"

  @piece_content "RIFF-fake-wav-bytes"
  @generic_404 %{"error" => "not_found", "message" => "Source not found"}

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "piece.wav"), @piece_content)
    File.write!(Path.join(tmp_dir, "a track.wav"), "RIFF")
    File.write!(Path.join(tmp_dir, "notaudio.txt"), "definitely not audio")

    # Pin every config value the chain reads: a boot-time AP_MAX_SRC_BYTES in
    # the environment must not be able to flip these tests' 501s to 413s.
    put_config(%{
      key: @key,
      salt: @salt,
      allow_insecure: false,
      local_root: tmp_dir,
      max_src_bytes: 2_000_000_000
    })

    # Every request below is its own render unless the test says otherwise —
    # see `AudioProxy.CoalesceHelper` for why that needs saying.
    reset_coordinators()

    :ok
  end

  defp get(path) do
    conn(:get, path) |> AudioProxy.Router.call(@opts)
  end

  # The same route, rendered by the stand-in encoder. Everything before the
  # action is the identical plug chain, so an error asserted through `get/1`
  # is asserted against the production mounting.
  defp render(path, headers \\ []) do
    request(:get, path, headers)
  end

  defp request(method, path, headers \\ []) do
    headers
    |> Enum.reduce(conn(method, path), fn {k, v}, c -> put_req_header(c, k, v) end)
    |> AudioProxy.FakeFfmpeg.Router.call(@fake_opts)
  end

  defp signed(rest) do
    "/#{Signature.sign(rest, @key, @salt)}#{rest}"
  end

  defp quoted_etag(options, source) do
    ~s("#{AudioProxy.CacheKey.derive!(options, source)}")
  end

  # The process-table probe behind every "no render was spawned" assertion:
  # each render runs under its own coordinator, and `reset_coordinators/0` in
  # setup guarantees the table starts empty.
  defp no_render_spawned? do
    DynamicSupervisor.which_children(AudioProxy.RenderCoordinator.Supervisor) == []
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

      assert render(signed("/f:mp3/plain/local://piece.wav")).status == 200
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

  describe "the streaming response" do
    test "a fully valid request streams the render as a chunked 200" do
      conn = render(signed("/f:opus/br:96/plain/local://piece.wav"))

      assert conn.status == 200
      assert conn.state == :chunked
      assert conn.resp_body == @payload

      # No Content-Length and no Accept-Ranges, per §5: the length is not
      # known when the head goes out, and the proxy does not serve ranges on
      # a MISS.
      assert get_resp_header(conn, "content-length") == []
      assert get_resp_header(conn, "accept-ranges") == []
    end

    test "a valid request with escapes in the filename reaches the action" do
      # The signature covers the raw %20 spelling; the source parser decodes
      # exactly once; stat finds the file on disk — the whole raw-bytes
      # round trip this chain exists to protect.
      assert render(signed("/f:mp3/plain/local://a%20track.wav")).status == 200
    end

    test "the §5 headers describe the variant" do
      rest = "/f:opus/br:96/plain/local://piece.wav"
      conn = render(signed(rest))

      key = AudioProxy.CacheKey.derive!("f:opus/br:96", "local://piece.wav")

      assert get_resp_header(conn, "content-type") == ["audio/ogg"]

      assert get_resp_header(conn, "cache-control") ==
               ["public, max-age=31536000, immutable, no-transform"]

      assert get_resp_header(conn, "etag") == [~s("#{key}")]
      assert get_resp_header(conn, "x-audio-proxy") == ["MISS"]
      assert get_resp_header(conn, "content-disposition") == []
    end

    test "a request that attaches to a running render is COALESCED, not MISS" do
      rest = signed("/f:opus/br:96/plain/local://piece.wav")

      first = render(rest)
      # Sequential, and still coalesced: the coordinator stays registered
      # briefly after finishing, so a request that arrives just too late to
      # start the render gets its bytes instead of running ffmpeg again.
      second = render(rest)

      assert get_resp_header(first, "x-audio-proxy") == ["MISS"]
      assert get_resp_header(second, "x-audio-proxy") == ["COALESCED"]

      # The point of joining: the same bytes, not merely the same status.
      assert second.resp_body == first.resp_body
      assert get_resp_header(second, "etag") == get_resp_header(first, "etag")
    end

    test "a different variant of the same source is its own render" do
      first = render(signed("/f:opus/br:96/plain/local://piece.wav"))
      second = render(signed("/f:opus/br:128/plain/local://piece.wav"))

      assert get_resp_header(first, "x-audio-proxy") == ["MISS"]
      assert get_resp_header(second, "x-audio-proxy") == ["MISS"]
    end

    test "the ETag is the cache key, so option order cannot change it" do
      one = render(signed("/f:opus/br:96/plain/local://piece.wav"))
      other = render(signed("/br:96/f:opus/plain/local://piece.wav"))

      assert get_resp_header(one, "etag") == get_resp_header(other, "etag")
    end

    test "dl becomes a Content-Disposition naming the file" do
      conn = render(signed("/f:mp3/dl:preview.mp3/plain/local://piece.wav"))

      assert get_resp_header(conn, "content-disposition") ==
               [~s(attachment; filename="preview.mp3")]
    end

    test "a dl that would break the header is escaped, not passed through" do
      # `dl` is opaque past the control-character check, so a quote in it
      # would otherwise end the filename parameter and turn the rest into
      # header syntax.
      conn = render(signed(~s(/f:mp3/dl:a"b\\c.mp3/plain/local://piece.wav)))

      assert get_resp_header(conn, "content-disposition") ==
               [~s(attachment; filename="a\\"b\\\\c.mp3")]
    end

    test "a non-ASCII dl is carried by filename*, with an ASCII fallback" do
      conn = render(signed("/f:mp3/dl:stück.mp3/plain/local://piece.wav"))

      assert get_resp_header(conn, "content-disposition") ==
               [~s(attachment; filename="st_ck.mp3"; filename*=UTF-8''st%C3%BCck.mp3)]
    end

    test "an undecodable source is a 415, from the render's own diagnosis" do
      conn = render(signed("/f:mp3/plain/local://notaudio.txt"))

      assert conn.status == 415
      assert JSON.decode!(conn.resp_body)["error"] == "undecodable_source"
    end
  end

  describe "errors declare their cacheability end to end" do
    test "a 404 is briefly negative-cached, a 422 for a minute, a 401 too" do
      assert get_resp_header(get(signed("/f:mp3/plain/local://missing.wav")), "cache-control") ==
               ["max-age=10"]

      assert get_resp_header(get(signed("/nope:1/plain/local://piece.wav")), "cache-control") ==
               ["max-age=60"]

      assert get_resp_header(get("/f:mp3/plain/local://piece.wav"), "cache-control") ==
               ["max-age=60"]
    end
  end

  describe "conditional requests are answered from the URL" do
    @variant "/f:opus/br:96/plain/local://piece.wav"

    test "a matching If-None-Match is a 304 with no render spawned" do
      etag = quoted_etag("f:opus/br:96", "local://piece.wav")

      conn = render(signed(@variant), [{"if-none-match", etag}])

      assert conn.status == 304
      assert conn.resp_body == ""
      assert get_resp_header(conn, "etag") == [etag]

      assert get_resp_header(conn, "cache-control") ==
               ["public, max-age=31536000, immutable, no-transform"]

      assert no_render_spawned?()
    end

    test "a weak validator matches too — CDNs may weaken stored ETags" do
      etag = quoted_etag("f:opus/br:96", "local://piece.wav")

      conn = render(signed(@variant), [{"if-none-match", "W/" <> etag}])

      assert conn.status == 304
      assert no_render_spawned?()
    end

    test "a stale validator proceeds exactly as without the header" do
      conn = render(signed(@variant), [{"if-none-match", ~s("someone-elses-etag")}])

      assert conn.status == 200
      assert conn.state == :chunked
      assert conn.resp_body == @payload
    end

    test "the signature still gates: unsigned plus a matching validator is 401" do
      etag = quoted_etag("f:opus/br:96", "local://piece.wav")

      conn =
        conn(:get, "/insecure#{@variant}")
        |> put_req_header("if-none-match", etag)
        |> AudioProxy.Router.call(@opts)

      assert conn.status == 401
      assert no_render_spawned?()
    end
  end

  describe "HEAD is supported on the signed endpoint" do
    test "a valid URL answers the GET's headers, an empty body, and no spawn" do
      conn = request(:head, signed("/f:opus/br:96/plain/local://piece.wav"))

      assert conn.status == 200
      assert conn.resp_body == ""
      assert get_resp_header(conn, "content-type") == ["audio/ogg"]

      assert get_resp_header(conn, "cache-control") ==
               ["public, max-age=31536000, immutable, no-transform"]

      assert get_resp_header(conn, "etag") == [quoted_etag("f:opus/br:96", "local://piece.wav")]

      # No render ran, so the header that names a render's outcome is absent.
      assert get_resp_header(conn, "x-audio-proxy") == []
      assert no_render_spawned?()
    end

    test "a bad signature is 401, a missing source 404 — errors as GET" do
      rest = "/f:opus/br:96/plain/local://piece.wav"

      bad_sig =
        conn(:head, "/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA#{rest}")
        |> AudioProxy.Router.call(@opts)

      assert bad_sig.status == 401
      assert get_resp_header(bad_sig, "cache-control") == ["max-age=60"]

      missing = request(:head, signed("/f:mp3/plain/local://missing.wav"))

      assert missing.status == 404
      assert get_resp_header(missing, "cache-control") == ["max-age=10"]
      assert no_render_spawned?()
    end

    test "HEAD runs the stat: an oversized source is 413, exactly like GET" do
      put_config(%{max_src_bytes: byte_size(@piece_content) - 1})

      assert request(:head, signed("/f:mp3/plain/local://piece.wav")).status == 413
    end

    test "dl still describes the variant: Content-Disposition on the HEAD" do
      conn = request(:head, signed("/f:mp3/dl:preview.mp3/plain/local://piece.wav"))

      assert get_resp_header(conn, "content-disposition") ==
               [~s(attachment; filename="preview.mp3")]
    end
  end

  describe "Range on a MISS is ignored" do
    test "a Range header still gets the full 200 chunked stream" do
      # Pinning intent, not an accident (RFC 9110 §14.2 permits ignoring
      # Range): 206 semantics belong to cached variants, which storage will
      # serve. A future "helpful" 416 or partial implementation fails here.
      conn = render(signed("/f:opus/br:96/plain/local://piece.wav"), [{"range", "bytes=1000-"}])

      assert conn.status == 200
      assert conn.state == :chunked
      assert conn.resp_body == @payload
      assert get_resp_header(conn, "accept-ranges") == []
      assert get_resp_header(conn, "content-range") == []
    end
  end
end
