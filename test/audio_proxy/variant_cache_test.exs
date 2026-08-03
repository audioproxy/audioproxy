defmodule AudioProxy.VariantCacheTest do
  @moduledoc """
  What a client observes when the variant it asked for is already stored.

  All of it through the router with `Plug.Test`, because every property under
  test here — the status, the framing headers, the sliced body, the 302 — is
  visible from the conn. The one that is not is progressive delivery, which
  needs a socket and lives in `AudioProxy.VariantCacheStreamTest`.

  Most tests put the variant into the store directly rather than rendering
  one. That is not a shortcut: it is what lets a HIT be asserted against a
  *source that does not exist*, which is the sharpest statement of where the
  cache check sits — before the stat, so a cached variant does not depend on
  the source outliving it.
  """

  use ExUnit.Case, async: false

  import AudioProxy.CoalesceHelper
  import AudioProxy.ConfigHelper
  import Plug.Conn
  import Plug.Test

  alias AudioProxy.{CacheKey, PresigningStore, Signature, VariantStore}

  @moduletag tmp_dir: "variant_cache"

  @key Base.decode16!("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")
  @salt Base.decode16!("FFEEDDCCBBAA99887766554433221100")

  @fake_opts AudioProxy.FakeFfmpeg.Router.init([])

  # The stand-in encoder's output, for the tests that render before they hit.
  @payload "fake-audio-payload"

  # A stored variant, long enough to slice and patterned so a wrong slice is a
  # mismatch rather than a coincidence.
  @variant Enum.map_join(0..199, fn n -> <<rem(n, 256)>> end)

  @metadata %{
    content_type: "audio/ogg",
    cache_control: "public, max-age=31536000, immutable, no-transform",
    etag: nil
  }

  @options "f:opus/br:96"
  @rest "/f:opus/br:96/plain/local://cached.wav"

  setup %{tmp_dir: tmp_dir} do
    store = Path.join(tmp_dir, "store")
    File.mkdir_p!(store)
    File.write!(Path.join(tmp_dir, "piece.wav"), "RIFF-fake-wav-bytes")

    put_config(%{
      key: @key,
      salt: @salt,
      allow_insecure: false,
      local_root: tmp_dir,
      max_src_bytes: 2_000_000_000,
      variant_store: {:file, store},
      serve_mode: :proxy
    })

    reset_coordinators()
    PresigningStore.reset()

    {:ok, store: store}
  end

  ## Helpers

  defp signed(rest), do: "/#{Signature.sign(rest, @key, @salt)}#{rest}"

  defp request(path, headers \\ []) do
    headers
    |> Enum.reduce(conn(:get, path), fn {k, v}, c -> put_req_header(c, k, v) end)
    |> AudioProxy.FakeFfmpeg.Router.call(@fake_opts)
  end

  defp cache_key(source \\ "local://cached.wav"), do: CacheKey.derive!(@options, source)

  # Puts `bytes` in the store under the cache key `rest` resolves to, with the
  # metadata the render path would have stored.
  defp store!(bytes, source \\ "local://cached.wav") do
    key = cache_key(source)

    :ok = VariantStore.put_stream(key, [bytes], %{@metadata | etag: ~s("#{key}")})

    key
  end

  defp no_render_spawned? do
    DynamicSupervisor.which_children(AudioProxy.RenderCoordinator.Supervisor) == []
  end

  @deadline 5_000

  defp wait_until(condition, remaining \\ @deadline)
  defp wait_until(_condition, remaining) when remaining <= 0, do: flunk("condition never held")

  defp wait_until(condition, remaining) do
    unless condition.() do
      Process.sleep(10)
      wait_until(condition, remaining - 10)
    end
  end

  describe "a stored variant is served without rendering" do
    test "the response is a HIT and no subprocess starts" do
      store!(@variant)

      conn = request(signed(@rest))

      assert conn.status == 200
      assert conn.resp_body == @variant
      assert get_resp_header(conn, "x-audio-proxy") == ["HIT"]
      assert no_render_spawned?()
    end

    test "the source is never stat'd: a HIT outlives the file it was made from" do
      # `local://cached.wav` does not exist in the tmp dir, and a MISS for it
      # would be a 404. The cache check runs before the stat, deliberately —
      # a stored variant is immutable bytes that owe nothing to their source.
      store!(@variant)

      assert request(signed(@rest)).status == 200

      # Same absent source, a variant nothing stored: the stat runs and 404s.
      assert request(signed("/f:mp3/plain/local://cached.wav")).status == 404
    end

    test "an unset store always renders" do
      put_config(%{variant_store: nil})

      conn = request(signed("/f:opus/br:96/plain/local://piece.wav"))

      assert get_resp_header(conn, "x-audio-proxy") == ["MISS"]
      assert conn.resp_body == @payload
    end

    test "a rendered variant is a HIT on the next request" do
      # The end-to-end version: render, wait for the write-back, ask again.
      rest = "/f:opus/br:96/plain/local://piece.wav"

      first = request(signed(rest))
      assert get_resp_header(first, "x-audio-proxy") == ["MISS"]

      key = CacheKey.derive!(@options, "local://piece.wav")
      wait_until(fn -> match?({:ok, _entry}, VariantStore.head(key)) end)

      second = request(signed(rest))

      assert get_resp_header(second, "x-audio-proxy") == ["HIT"]
      assert second.resp_body == first.resp_body
    end
  end

  describe "the client contract is the cache state, not the backend" do
    test "a HIT carries the headers the MISS that filled it sent" do
      rest = "/f:opus/br:96/plain/local://piece.wav"

      miss = request(signed(rest))
      key = CacheKey.derive!(@options, "local://piece.wav")
      wait_until(fn -> match?({:ok, _entry}, VariantStore.head(key)) end)
      hit = request(signed(rest))

      for header <- ~w(content-type cache-control etag) do
        assert get_resp_header(hit, header) == get_resp_header(miss, header),
               "#{header} changed between a MISS and the HIT it produced"
      end
    end

    test "the headers come from the store, not from re-deriving them" do
      # Stored metadata that the options would never produce. A HIT that
      # rebuilt its head from the URL would answer `audio/ogg` here — and a
      # redirected fetch, which can only serve what the store holds, would
      # then disagree with a proxied one.
      key = cache_key()

      :ok =
        VariantStore.put_stream(key, [@variant], %{
          content_type: "audio/x-stored",
          cache_control: "public, max-age=1",
          etag: ~s("stored-etag")
        })

      conn = request(signed(@rest))

      assert get_resp_header(conn, "content-type") == ["audio/x-stored"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=1"]
      assert get_resp_header(conn, "etag") == [~s("stored-etag")]
    end
  end

  describe "cache state changes the framing" do
    test "a MISS is chunked and unseekable; a HIT declares a length and takes ranges" do
      rest = "/f:opus/br:96/plain/local://piece.wav"

      miss = request(signed(rest))

      assert miss.state == :chunked
      assert get_resp_header(miss, "content-length") == []
      assert get_resp_header(miss, "accept-ranges") == []

      key = CacheKey.derive!(@options, "local://piece.wav")
      wait_until(fn -> match?({:ok, _entry}, VariantStore.head(key)) end)

      hit = request(signed(rest))

      assert hit.status == 200
      assert get_resp_header(hit, "content-length") == [Integer.to_string(byte_size(@payload))]
      assert get_resp_header(hit, "accept-ranges") == ["bytes"]

      ranged = request(signed(rest), [{"range", "bytes=0-3"}])
      assert ranged.status == 206
    end
  end

  describe "Range on a HIT" do
    setup do
      store!(@variant)
      :ok
    end

    test "a closed range is a 206 with exactly those bytes" do
      conn = request(signed(@rest), [{"range", "bytes=100-199"}])

      assert conn.status == 206
      assert conn.resp_body == binary_part(@variant, 100, 100)
      assert get_resp_header(conn, "content-range") == ["bytes 100-199/200"]
      assert get_resp_header(conn, "content-length") == ["100"]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert get_resp_header(conn, "x-audio-proxy") == ["HIT"]
    end

    test "an open-ended range runs to the last byte" do
      conn = request(signed(@rest), [{"range", "bytes=150-"}])

      assert conn.status == 206
      assert conn.resp_body == binary_part(@variant, 150, 50)
      assert get_resp_header(conn, "content-range") == ["bytes 150-199/200"]
    end

    test "a suffix range counts back from the end" do
      conn = request(signed(@rest), [{"range", "bytes=-20"}])

      assert conn.status == 206
      assert conn.resp_body == binary_part(@variant, 180, 20)
      assert get_resp_header(conn, "content-range") == ["bytes 180-199/200"]
    end

    test "a suffix longer than the variant is the whole variant, still a 206" do
      conn = request(signed(@rest), [{"range", "bytes=-500"}])

      assert conn.status == 206
      assert conn.resp_body == @variant
      assert get_resp_header(conn, "content-range") == ["bytes 0-199/200"]
    end

    test "an end past the variant is truncated, not refused" do
      conn = request(signed(@rest), [{"range", "bytes=190-9999"}])

      assert conn.status == 206
      assert conn.resp_body == binary_part(@variant, 190, 10)
      assert get_resp_header(conn, "content-range") == ["bytes 190-199/200"]
    end

    test "a start past the end is a 416 naming the size" do
      conn = request(signed(@rest), [{"range", "bytes=200-300"}])

      assert conn.status == 416
      assert get_resp_header(conn, "content-range") == ["bytes */200"]
      assert JSON.decode!(conn.resp_body)["error"] == "range_not_satisfiable"

      # Never cacheable: the body depends on a request header, and nothing
      # here sends `Vary: Range`.
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "x-audio-proxy") == ["HIT"]
    end

    test "a zero-length suffix is unsatisfiable, not empty" do
      assert request(signed(@rest), [{"range", "bytes=-0"}]).status == 416
    end

    test "every range against a zero-length variant is a 416" do
      # Contested during review, so pinned. A zero-length variant makes `last`
      # clamp to -1, which looks like a malformed range and would be *ignored*
      # if the first-byte-pos check ran after the clamp. It does not: `last <
      # first` compares the value as parsed, so these all reach the bounds
      # check and are refused rather than answered with an empty 200.
      :ok = VariantStore.put_stream(cache_key(), [""], %{@metadata | etag: ~s("empty")})

      for header <- ["bytes=0-0", "bytes=0-1", "bytes=1-2", "bytes=0-", "bytes=-5"] do
        conn = request(signed(@rest), [{"range", header}])

        assert conn.status == 416, "#{header} against a 0-byte variant should be unsatisfiable"
        assert get_resp_header(conn, "content-range") == ["bytes */0"]
      end
    end

    test "a range this proxy does not implement is ignored, not refused" do
      # RFC 9110 §14.2 permits ignoring `Range` outright; multi-range and
      # non-`bytes` units get the whole variant rather than a 416 or a
      # multipart body nothing asked for.
      for header <- ["bytes=0-9,50-59", "items=0-9", "bytes=abc", "bytes=9-2", "bytes=0-9x"] do
        conn = request(signed(@rest), [{"range", header}])

        assert conn.status == 200, "#{header} should have been ignored"
        assert conn.resp_body == @variant
        assert get_resp_header(conn, "content-range") == []
      end
    end
  end

  describe "redirect mode" do
    setup do
      put_config(%{variant_store: {:module, PresigningStore}, serve_mode: :redirect})

      store!(@variant)
      :ok
    end

    test "a HIT is a 302 to a presigned URL" do
      conn = request(signed(@rest))

      assert conn.status == 302
      assert conn.resp_body == ""
      assert get_resp_header(conn, "x-audio-proxy") == ["HIT"]

      assert [location] = get_resp_header(conn, "location")
      assert location =~ PresigningStore.base_url()
      assert location =~ cache_key()
    end

    test "the redirect is never cached — its Location expires" do
      assert get_resp_header(request(signed(@rest)), "cache-control") == ["no-store"]
    end

    test "AP_PRESIGN_TTL is what the URL is signed for" do
      put_config(%{presign_ttl: 42})

      assert [location] = get_resp_header(request(signed(@rest)), "location")
      assert location =~ "expires_in=42"
    end

    test "a presign that fails serves the bytes instead, with the reason redacted" do
      # The bytes are readable and the client asked for audio, not for a URL,
      # so the fallback is to proxy. What must not happen is the log carrying
      # the credential the failing backend was handling: this is the one
      # inspect/1 on the path, and the backend it inspects deals in signed
      # URLs by definition.
      key = cache_key()

      PresigningStore.fail_presign(
        key,
        "clock skew signing https://variants.example.test/#{key}?X-Amz-Signature=deadbeef"
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = request(signed(@rest))

          assert conn.status == 200
          assert conn.resp_body == @variant
          assert get_resp_header(conn, "x-audio-proxy") == ["HIT"]
        end)

      assert log =~ "could not presign"
      assert log =~ "[redacted]"
      refute log =~ "deadbeef"
    end

    test "a miss still renders: nothing to redirect to" do
      conn = request(signed("/f:opus/br:96/plain/local://piece.wav"))

      assert conn.status == 200
      assert get_resp_header(conn, "x-audio-proxy") == ["MISS"]
    end

    test "proxy mode against the same backend serves the bytes itself" do
      put_config(%{serve_mode: :proxy})

      conn = request(signed(@rest))

      assert conn.status == 200
      assert conn.resp_body == @variant
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert get_resp_header(conn, "location") == []
    end
  end

  describe "a store that moves under a reader" do
    setup do
      put_config(%{variant_store: {:module, PresigningStore}, serve_mode: :proxy})
      :ok
    end

    test "an entry readable by head/1 but not by get_stream/2 falls through to a render" do
      # The eviction window the local backend closes by re-heading inside
      # get_stream/2, and a shared store does not. Nothing has been sent yet,
      # so the only correct answer is to render.
      store!(@variant, "local://piece.wav")
      PresigningStore.vanish_reads(CacheKey.derive!(@options, "local://piece.wav"))

      conn = request(signed("/f:opus/br:96/plain/local://piece.wav"))

      assert conn.status == 200
      assert get_resp_header(conn, "x-audio-proxy") == ["MISS"]
      assert conn.resp_body == @payload
    end

    test "a body short of its declared Content-Length tears the response down" do
      # Completing this response would hand a keep-alive client a well-formed
      # 200 whose body is shorter than it promised — so the next response on
      # that connection is read as this one's remaining bytes. An abnormal
      # close is the only honest signal left once the head has gone out (§5).
      key = store!(@variant)
      PresigningStore.declare_size(key, byte_size(@variant) * 2)

      assert catch_exit(request(signed(@rest))) ==
               {:shutdown, {:variant_truncated, byte_size(@variant) * 2, byte_size(@variant)}}
    end

    test "a body that exactly matches its declared length completes normally" do
      # The other side of the same check: this is the ordinary path, and it
      # must not be tripped by the counting.
      store!(@variant)

      conn = request(signed(@rest))

      assert conn.status == 200
      assert conn.resp_body == @variant
    end
  end

  describe "an evicted variant" do
    test "is a miss again, not a failure", %{store: store} do
      # Nothing keeps a store from being swept between two requests. The bytes
      # going away has to read as a miss — the request renders — rather than as
      # a 404 or a torn-down stream.
      key = store!(@variant, "local://piece.wav")

      File.rm!(Path.join([store, binary_part(key, 0, 2), binary_part(key, 2, 2), key]))

      conn = request(signed("/f:opus/br:96/plain/local://piece.wav"))

      assert conn.status == 200
      assert get_resp_header(conn, "x-audio-proxy") == ["MISS"]
      assert conn.resp_body == @payload
    end
  end
end
