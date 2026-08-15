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
  import AudioProxy.ProbeCoalesceHelper
  import AudioProxy.ConfigHelper
  import AudioProxy.SignedRequest, except: [conn: 3]
  import Plug.Conn
  import Plug.Test
  import AudioProxy.Eventually

  alias AudioProxy.Signature
  alias AudioProxy.SignedRequest

  @moduletag tmp_dir: "render_endpoint"

  @opts AudioProxy.Router.init([])
  @fake_opts AudioProxy.FakeFfmpeg.Router.init([])
  @payload "fake-audio-payload"

  @piece_content "RIFF-fake-wav-bytes"
  @generic_404 %{"error" => "not_found", "message" => "Source not found"}

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "piece.wav"), @piece_content)
    File.write!(Path.join(tmp_dir, "a track.wav"), "RIFF")
    File.write!(Path.join(tmp_dir, "notaudio.txt"), "definitely not audio")

    # The audio-only gate's fixtures. What they contain is irrelevant — the
    # stand-in prober answers on the filename, so these say "video", "cover
    # art" and "ambiguous" without shipping an mp4 to say it with.
    for name <- ~w(video.mp4 videoonly.mp4 cover.mp3 stillcover.flac slideshow.mp4) do
      File.write!(Path.join(tmp_dir, name), "fake-bytes")
    end

    put_config(base_config(local_root: tmp_dir))

    # Every request below is its own render unless the test says otherwise —
    # see `AudioProxy.CoalesceHelper` for why that needs saying.
    reset_coordinators()
    reset_probes()

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
    SignedRequest.conn(method, path, headers)
    |> AudioProxy.FakeFfmpeg.Router.call(@fake_opts)
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
      sig = Signature.sign(rest, key(), salt())

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

    test "a large source with a small variant ceiling is accepted, then killed" do
      # The split, stated end to end: the source ceiling admits the file, and
      # what refuses the request is the *output* crossing its own ceiling. The
      # outcome is a render failure, not the 413 the source ceiling produces —
      # nothing was wrong with the source.
      put_config(%{
        max_src_bytes: byte_size(@piece_content),
        max_variant_bytes: byte_size(@payload) - 1
      })

      conn = render(signed("/f:mp3/plain/local://piece.wav"))

      assert conn.status == 500
      assert JSON.decode!(conn.resp_body)["error"] == "render_failed"
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
      # The probe accepts this fixture (the stand-in prober has no directive for
      # it), so the 415 is the *encoder's* verdict, reached after the gate — the
      # case that is not the gate's, kept distinct from the ones below.
      conn = render(signed("/f:mp3/plain/local://notaudio.txt"))

      assert conn.status == 415
      assert JSON.decode!(conn.resp_body)["error"] == "undecodable_source"
    end
  end

  describe "the audio-only gate" do
    test "a source with audio and video is 415, with no render spawned" do
      conn = render(signed("/f:mp3/plain/local://video.mp4"))

      assert conn.status == 415
      assert JSON.decode!(conn.resp_body)["error"] == "video_source"
      assert JSON.decode!(conn.resp_body)["message"] =~ "audio only"

      # The whole point of the gate's placement: no ffmpeg, and no render slot
      # held while deciding.
      assert no_render_spawned?()
    end

    test "a video-only source is 415 too" do
      conn = render(signed("/f:mp3/plain/local://videoonly.mp4"))

      assert conn.status == 415
      assert JSON.decode!(conn.resp_body)["error"] == "video_source"
      assert no_render_spawned?()
    end

    test "the refusal is a policy statement, not a decoding complaint" do
      video = render(signed("/f:mp3/plain/local://video.mp4"))
      undecodable = render(signed("/f:mp3/plain/local://notaudio.txt"))

      assert video.status == undecodable.status
      refute video.resp_body == undecodable.resp_body
    end

    test "a video refusal is briefly negative-cached, like every 415" do
      conn = render(signed("/f:mp3/plain/local://videoonly.mp4"))

      assert get_resp_header(conn, "cache-control") == ["max-age=10"]
    end

    test "cover art is not video: an mp3 with embedded artwork renders" do
      conn = render(signed("/f:mp3/plain/local://cover.mp3"))

      assert conn.status == 200
      assert conn.resp_body == @payload
    end

    test "a still image with no disposition data renders too" do
      # Fake-prober only, and it cannot be otherwise: ffmpeg's mp3 and flac
      # muxers always write `attached_pic`, so a real fixture that omits the
      # disposition is not constructible with the tools this repo has. That is
      # exactly why the fallback is codec-based guesswork — it exists for
      # containers we cannot enumerate, so the containers we *can* produce
      # cannot exercise it.
      assert render(signed("/f:flac/plain/local://stillcover.flac")).status == 200
    end

    test "ambiguity that is not a picture fails closed" do
      conn = render(signed("/f:mp3/plain/local://slideshow.mp4"))

      assert conn.status == 415
      assert JSON.decode!(conn.resp_body)["error"] == "video_source"
    end

    test "every format is gated, not just the default one" do
      for format <- ~w(mp3 opus aac m4a flac wav peaks) do
        conn = render(signed("/f:#{format}/plain/local://video.mp4"))

        assert conn.status == 415, "f:#{format} rendered a video source"
      end
    end

    test "a cache HIT never pays for the gate", %{tmp_dir: tmp_dir} do
      # The gate sits after the cache lookup, so a stored variant is served
      # without probing — asserted by storing one for a *video* source, which
      # only a HIT could ever answer 200 for.
      store = Path.join(tmp_dir, "gate-store")
      File.mkdir_p!(store)
      put_config(%{variant_store: {:file, store}})

      key = AudioProxy.CacheKey.derive!("f:mp3", "local://video.mp4")

      metadata = %{
        content_type: "audio/mpeg",
        cache_control: "public, max-age=31536000, immutable, no-transform",
        etag: ~s("#{key}")
      }

      assert :ok = AudioProxy.VariantStore.put_stream(key, ["cached-bytes"], metadata)

      conn = render(signed("/f:mp3/plain/local://video.mp4"))

      assert conn.status in [200, 302]
      assert get_resp_header(conn, "x-audio-proxy") == ["HIT"]
    end

    test "HEAD does not probe, so it answers 200 where the GET answers 415" do
      # The same divergence HEAD already has for an undecodable source, and
      # deliberate for the same reason: HEAD exists to be cheap.
      path = signed("/f:mp3/plain/local://video.mp4")

      assert render(path).status == 415
      assert request(:head, path).status == 200
      assert no_render_spawned?()
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

    test "a matching validator outranks a missing source: 304, not 404" do
      # Deliberate, and pinned so it is not "fixed" into a stat per
      # revalidation: the ETag names immutable variant bytes, so a cache still
      # holding them is not wrong to keep them even though the source is gone.
      etag = quoted_etag("f:mp3", "local://gone.wav")
      path = signed("/f:mp3/plain/local://gone.wav")

      assert render(path).status == 404
      assert render(path, [{"if-none-match", etag}]).status == 304
      assert no_render_spawned?()
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

  describe "HEAD on a miss" do
    test "answers what is knowable without rendering, and spawns nothing" do
      conn = request(:head, signed("/f:opus/br:96/plain/local://piece.wav"))

      assert conn.status == 200
      assert conn.resp_body == ""
      assert get_resp_header(conn, "content-type") == ["audio/ogg"]

      assert get_resp_header(conn, "cache-control") ==
               ["public, max-age=31536000, immutable, no-transform"]

      assert get_resp_header(conn, "etag") == [quoted_etag("f:opus/br:96", "local://piece.wav")]

      # Nothing is stored, and saying so is the point: a client probing cache
      # state gets an answer rather than a silence to interpret.
      assert get_resp_header(conn, "x-audio-proxy") == ["MISS"]
      assert no_render_spawned?()
    end

    test "no length and no ranges: neither is knowable before the render" do
      # RFC 9110 §9.3.2's permitted omission, and the one case in this change
      # that qualifies for it. A `content-length` here would be a guess, and
      # `accept-ranges` would promise seeking the chunked MISS cannot do.
      conn = request(:head, signed("/f:opus/br:96/plain/local://piece.wav"))

      assert get_resp_header(conn, "content-length") == []
      assert get_resp_header(conn, "accept-ranges") == []
    end

    test "probing does not warm: no render, nothing stored, the GET still MISSes",
         %{tmp_dir: tmp_dir} do
      # The safety property the rest of this change rests on. A HEAD is the
      # cheapest request a client can make, and it has to stay that way under
      # any volume — a probe that rendered would be a denial-of-service lever
      # dressed as a courtesy.
      store = Path.join(tmp_dir, "probe-store")
      File.mkdir_p!(store)
      put_config(%{variant_store: {:file, store}})

      key = AudioProxy.CacheKey.derive!("f:opus/br:96", "local://piece.wav")
      path = signed("/f:opus/br:96/plain/local://piece.wav")

      assert request(:head, path).status == 200
      assert no_render_spawned?()
      assert AudioProxy.VariantStore.head(key) == {:error, :not_found}

      # Not a slot taken and released: the semaphore never saw this request,
      # so a following GET is the first render of this variant.
      assert get_resp_header(render(path), "x-audio-proxy") == ["MISS"]
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

    test "an expired URL is 410 and a source outside the allowlist the generic 404" do
      # Every gate a GET passes still gates the HEAD, and this is why it has to:
      # a probe that answered from behind a refused signature or a dead `exp`
      # would be an existence oracle for variants nobody may fetch.
      expired = signed("/f:opus/exp:#{System.os_time(:second) - 1}/plain/local://piece.wav")

      assert request(:head, expired).status == 410

      outside = request(:head, signed("/f:mp3/plain/local://../secret.wav"))

      assert outside.status == 404
      assert no_render_spawned?()
    end

    test "HEAD answers 200 where GET answers 415, and cannot do better" do
      # Not a lie the chain could avoid: 415 is ffmpeg's verdict while
      # decoding, and HEAD exists precisely to skip the decode. Pinned so the
      # divergence stays a documented property rather than a surprise — and so
      # anyone tempted to "fix" it has to notice they would be rendering.
      path = signed("/f:mp3/plain/local://notaudio.txt")

      assert render(path).status == 415
      assert request(:head, path).status == 200
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

  describe "HEAD on a hit" do
    # Everything but the per-request identifier, which is supposed to differ:
    # `Plug.RequestId` stamps one on every response, and two requests that
    # shared one would be the bug.
    defp comparable(conn) do
      conn.resp_headers
      |> Enum.reject(fn {name, _value} -> name == "x-request-id" end)
      |> MapSet.new()
    end

    @hit_options "f:opus/br:96"
    @hit_rest "/f:opus/br:96/plain/local://piece.wav"
    @hit_bytes "cached-opus-bytes"

    setup %{tmp_dir: tmp_dir} do
      store = Path.join(tmp_dir, "hit-store")
      File.mkdir_p!(store)
      put_config(%{variant_store: {:file, store}})

      key = AudioProxy.CacheKey.derive!(@hit_options, "local://piece.wav")

      :ok =
        AudioProxy.VariantStore.put_stream(key, [@hit_bytes], %{
          content_type: "audio/ogg",
          cache_control: "public, max-age=31536000, immutable, no-transform",
          etag: ~s("#{key}")
        })

      {:ok, key: key}
    end

    test "the header set is the GET's, header for header" do
      # A set difference rather than a list of names: whatever a later change
      # adds to the HIT response has to reach the HEAD too, and this fails
      # naming the header that did not.
      path = signed(@hit_rest)

      get = render(path)
      head = request(:head, path)

      assert get.status == 200
      assert get_resp_header(get, "x-audio-proxy") == ["HIT"]
      assert head.status == 200
      assert head.resp_body == ""

      missing = MapSet.difference(comparable(get), comparable(head))
      extra = MapSet.difference(comparable(head), comparable(get))

      assert Enum.to_list(missing) == [], "HEAD omitted headers the GET sent"
      assert Enum.to_list(extra) == [], "HEAD sent headers the GET did not"
    end

    test "size and seekability, without downloading a byte", %{key: key} do
      conn = request(:head, signed(@hit_rest))

      assert get_resp_header(conn, "x-audio-proxy") == ["HIT"]
      assert get_resp_header(conn, "content-length") == ["#{byte_size(@hit_bytes)}"]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert get_resp_header(conn, "etag") == [~s("#{key}")]
      assert get_resp_header(conn, "content-type") == ["audio/ogg"]
      assert no_render_spawned?()
    end

    test "a hit is answered from the store's head, so the source is never stat'd",
         %{tmp_dir: tmp_dir} do
      # Same ordering as the GET, which is what makes the parity above cheap:
      # the cache lookup stands before the stat, so a variant whose source has
      # since been deleted still answers from the store.
      File.rm!(Path.join(tmp_dir, "piece.wav"))

      conn = request(:head, signed(@hit_rest))

      assert conn.status == 200
      assert get_resp_header(conn, "x-audio-proxy") == ["HIT"]
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

  describe "write-back" do
    # The full-path version of the store's own round-trip tests: the metadata
    # the store hands back is the head this response actually sent, so a
    # store-direct fetch serves the variant identically.
    test "the stored variant is the response — bytes and headers alike", %{tmp_dir: tmp_dir} do
      store = Path.join(tmp_dir, "store")
      File.mkdir_p!(store)
      put_config(%{variant_store: {:file, store}})

      conn = render(signed("/f:mp3/plain/local://piece.wav"))

      assert conn.status == 200
      assert conn.resp_body == @payload

      [etag] = get_resp_header(conn, "etag")
      key = String.trim(etag, ~s("))

      wait_until(fn -> match?({:ok, _entry}, AudioProxy.VariantStore.head(key)) end)

      assert {:ok, %{metadata: metadata}} = AudioProxy.VariantStore.head(key)
      assert [metadata.content_type] == get_resp_header(conn, "content-type")
      assert [metadata.cache_control] == get_resp_header(conn, "cache-control")
      assert metadata.etag == etag

      {:ok, stream} = AudioProxy.VariantStore.get_stream(key, nil)
      assert stream |> Enum.to_list() |> IO.iodata_to_binary() == conn.resp_body
    end
  end
end
