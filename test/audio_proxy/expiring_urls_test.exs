defmodule AudioProxy.ExpiringUrlsTest do
  @moduledoc """
  `exp` end to end: the 410, the two clamps, and the two properties that make
  `exp` a *request* option rather than another way to spell a variant.

  All of it through a router with `Plug.Test`. The clock is the real one — no
  leeway means nothing to inject — so every URL here is signed with a timestamp
  a fixed distance from now, and the assertions are inequalities rather than
  equalities: the seconds between signing a URL and reading its headers are
  real seconds, and a test that demanded `max-age` be exactly 60 would fail
  whenever they crossed a boundary.
  """

  use ExUnit.Case, async: false

  import AudioProxy.CoalesceHelper
  import AudioProxy.ProbeCoalesceHelper
  import AudioProxy.ConfigHelper
  import AudioProxy.SignedRequest
  import AudioProxy.Eventually

  alias AudioProxy.{CacheKey, PresigningStore, Signature, SignedRequest, VariantStore}

  @moduletag tmp_dir: "expiring_urls"

  @fake_opts AudioProxy.FakeFfmpeg.Router.init([])

  @options "f:opus/br:96"

  # A stored variant, so the HIT clamps can be asserted without rendering one.
  @variant "cached-variant-bytes"

  @metadata %{
    content_type: "audio/ogg",
    cache_control: "public, max-age=31536000, immutable, no-transform",
    etag: nil
  }

  setup %{tmp_dir: tmp_dir} do
    store = Path.join(tmp_dir, "store")
    File.mkdir_p!(store)
    File.write!(Path.join(tmp_dir, "piece.wav"), "RIFF-fake-wav-bytes")

    put_config(
      base_config(local_root: tmp_dir, variant_store: {:file, store}, serve_mode: :proxy)
    )

    reset_coordinators()
    reset_probes()
    PresigningStore.reset()

    :ok
  end

  ## Helpers

  defp request(path, headers \\ []) do
    SignedRequest.conn(:get, path, headers)
    |> AudioProxy.FakeFfmpeg.Router.call(@fake_opts)
  end

  defp in_seconds(offset), do: System.system_time(:second) + offset

  defp max_age(conn) do
    value = header(conn, "cache-control")
    [_whole, seconds] = Regex.run(~r/max-age=(\d+)/, value)

    String.to_integer(seconds)
  end

  defp store!(source) do
    key = CacheKey.derive!(@options, source)

    :ok = VariantStore.put_stream(key, [@variant], %{@metadata | etag: ~s("#{key}")})

    key
  end

  defp no_render_spawned? do
    DynamicSupervisor.which_children(AudioProxy.RenderCoordinator.Supervisor) == []
  end

  describe "an expired URL is refused from the URL alone" do
    test "the response is the 410 envelope" do
      conn = request(signed("/f:opus/exp:#{in_seconds(-1)}/plain/local://piece.wav"))

      assert conn.status == 410

      assert JSON.decode!(conn.resp_body) == %{
               "error" => "expired",
               "message" => "URL has expired"
             }
    end

    test "no source is resolved and no subprocess starts" do
      # `absent.wav` is not on disk, so a *live* request for it is a 404 from
      # the stat — which is exactly what makes this assertion sharp. A 410 for
      # the same path proves the chain halted before source resolution: the
      # proxy never learned whether the file exists, and neither does anyone
      # holding the expired URL.
      expired = "/f:opus/exp:#{in_seconds(-1)}/plain/local://absent.wav"
      live = "/f:opus/exp:#{in_seconds(3600)}/plain/local://absent.wav"

      assert request(signed(expired)).status == 410
      assert request(signed(live)).status == 404

      assert no_render_spawned?()
    end

    test "an expired URL for a variant already in the store is still 410" do
      # The cache check would answer 200 without touching the source at all, so
      # this is the one path where "no source access" is not enough of a gate.
      store!("local://cached.wav")

      conn = request(signed("/f:opus/br:96/exp:#{in_seconds(-1)}/plain/local://cached.wav"))

      assert conn.status == 410
    end

    test "the 410 is cacheable, because the verdict is permanent" do
      # The timestamp is inside the signature, so no later request can make this
      # URL valid again and an edge answering it outright is enforcement rather
      # than staleness.
      conn = request(signed("/f:opus/exp:#{in_seconds(-1)}/plain/local://piece.wav"))

      assert header(conn, "cache-control") == "public, max-age=31536000, immutable"
    end

    test "the production router refuses it, not merely the test mounting" do
      # Every other test here drives `AudioProxy.FakeFfmpeg.Router`, which once
      # hand-copied the production chain — so on its own the suite proved the
      # *copy* checked expiry and said nothing about the deployment. Removing
      # `AudioProxy.Plugs.CheckExpiry` from `AudioProxy.Plugs.RenderPipeline`
      # left all 1051 tests green, and this was the one that turned red.
      #
      # `extract-signed-chain` closed that: both routers mount
      # `AudioProxy.Plugs.SignedChain` now, so the other five turn red with it.
      # This one stays because it is the only test driving `AudioProxy.Router`
      # end to end — it covers the router's own wiring to the pipeline, which
      # a shared chain says nothing about.
      #
      # It needs no encoder precisely because of what it asserts: the check
      # halts before the action, so the production router is drivable for it.
      conn =
        SignedRequest.conn(
          :get,
          signed("/f:opus/exp:#{in_seconds(-1)}/plain/local://piece.wav"),
          []
        )
        |> AudioProxy.Router.call(AudioProxy.Router.init([]))

      assert conn.status == 410
      assert JSON.decode!(conn.resp_body)["error"] == "expired"
    end

    test "expiry is judged after the signature, not before" do
      # An expired URL whose signature is also wrong is a 401: a client with a
      # bad key learns nothing about the timestamp, and the cheaper, more
      # fundamental refusal is the one reported.
      rest = "/f:opus/exp:#{in_seconds(-1)}/plain/local://piece.wav"
      conn = request("/" <> String.duplicate("a", 43) <> rest)

      assert conn.status == 401
    end
  end

  describe "a live URL behaves as though exp were not there" do
    test "the same variant, the same cache key, the same bytes" do
      bare = request(signed("/f:opus/br:96/plain/local://piece.wav"))
      dated = request(signed("/f:opus/br:96/exp:#{in_seconds(3600)}/plain/local://piece.wav"))

      assert bare.status == 200
      assert dated.status == 200
      assert dated.resp_body == bare.resp_body
      assert header(dated, "etag") == header(bare, "etag")
      assert header(dated, "content-type") == header(bare, "content-type")
    end

    test "a timestamp in the past is valid grammar, not an invalid option" do
      # The distinction the parser owes the 410: were `exp:1` a 422, the verdict
      # would be a parse error and the 410 could never be reached, let alone
      # cached.
      conn = request(signed("/f:opus/exp:1/plain/local://piece.wav"))

      assert conn.status == 410
    end

    test "a malformed exp is a 422 like any other option" do
      for value <- ["later", "-1", "1.5", "99999999999999"] do
        conn = request(signed("/f:opus/exp:#{value}/plain/local://piece.wav"))

        assert conn.status == 422, "expected exp:#{value} to be a 422, got #{conn.status}"
        assert JSON.decode!(conn.resp_body)["error"] == "invalid_options"
      end
    end
  end

  describe "expiry caps every lifetime the response hands out" do
    test "a MISS clamps max-age to what is left of the URL" do
      conn = request(signed("/f:opus/br:96/exp:#{in_seconds(60)}/plain/local://piece.wav"))

      assert conn.status == 200
      assert max_age(conn) <= 60
    end

    test "a HIT clamps the max-age the store handed back" do
      # The stored policy is a year, and it has to stay one — those bytes are
      # shared by every `exp`. The clamp is applied on the way out instead.
      key = store!("local://cached.wav")

      {:ok, %{metadata: metadata}} = VariantStore.head(key)
      assert metadata.cache_control == "public, max-age=31536000, immutable, no-transform"

      conn = request(signed("/f:opus/br:96/exp:#{in_seconds(60)}/plain/local://cached.wav"))

      assert header(conn, "x-audio-proxy") == "HIT"
      assert max_age(conn) <= 60
    end

    test "a HIT redirect clamps the presigned credential to the same bound" do
      # The sharpest of the three: a followed `Location` needs no signature of
      # ours, so a credential outliving its URL leaves the building entirely.
      put_config(%{variant_store: {:module, PresigningStore}, serve_mode: :redirect})
      store!("local://cached.wav")

      conn = request(signed("/f:opus/br:96/exp:#{in_seconds(30)}/plain/local://cached.wav"))

      assert conn.status == 302
      location = header(conn, "location")
      assert [_whole, ttl] = Regex.run(~r/expires_in=(\d+)/, location)
      assert String.to_integer(ttl) <= 30
    end

    test "a 304 clamps too, or it would refresh what the 200 clamped" do
      etag = ~s("#{CacheKey.derive!(@options, "local://piece.wav")}")

      conn =
        request(signed("/f:opus/br:96/exp:#{in_seconds(60)}/plain/local://piece.wav"), [
          {"if-none-match", etag}
        ])

      assert conn.status == 304
      assert max_age(conn) <= 60
    end

    test "without exp, both lifetimes are exactly what configuration says" do
      put_config(%{presign_ttl: 3600})

      miss = request(signed("/f:opus/br:96/plain/local://piece.wav"))

      assert header(miss, "cache-control") == "public, max-age=31536000, immutable, no-transform"

      put_config(%{variant_store: {:module, PresigningStore}, serve_mode: :redirect})
      store!("local://cached.wav")

      redirect = request(signed("/f:opus/br:96/plain/local://cached.wav"))

      location = header(redirect, "location")
      assert location =~ "expires_in=3600"
    end
  end

  describe "exp is signed like every other path byte" do
    test "altering the timestamp without re-signing is a 401" do
      # The whole reason `exp` needs no mechanism of its own: it is inside the
      # HMAC because it is inside the path.
      expires_at = in_seconds(-1)
      rest = "/f:opus/br:96/exp:#{expires_at}/plain/local://piece.wav"
      sig = Signature.sign(rest, key(), salt())

      tampered = String.replace(rest, "exp:#{expires_at}", "exp:#{in_seconds(3600)}")

      assert request("/#{sig}#{tampered}").status == 401
    end

    test "removing the timestamp is a 401 too" do
      rest = "/f:opus/br:96/exp:#{in_seconds(-1)}/plain/local://piece.wav"
      sig = Signature.sign(rest, key(), salt())

      assert request("/#{sig}/f:opus/br:96/plain/local://piece.wav").status == 401
    end
  end

  describe "two URLs differing only in exp are one variant" do
    test "the second request coalesces onto the first render" do
      # No store, so the second request cannot be answered as a HIT: the only
      # way it gets bytes without a second render is by joining the first.
      put_config(%{variant_store: nil})

      first = request(signed("/f:opus/br:96/exp:#{in_seconds(3600)}/plain/local://piece.wav"))
      second = request(signed("/f:opus/br:96/exp:#{in_seconds(7200)}/plain/local://piece.wav"))

      assert header(first, "x-audio-proxy") == "MISS"
      assert header(second, "x-audio-proxy") == "COALESCED"

      # Both served, and served the same bytes — coalescing that dropped a
      # requester would satisfy "one render" and fail the point of it.
      assert second.resp_body == first.resp_body
      assert header(second, "etag") == header(first, "etag")
    end

    test "one write-back, which a URL carrying no exp at all then hits" do
      # `exp:600` rather than a year out, so a clamp leaking into the write-back
      # would be a visibly different number below rather than a coincidence.
      rest = "/f:opus/br:96/exp:#{in_seconds(600)}/plain/local://piece.wav"

      dated = request(signed(rest))
      assert header(dated, "x-audio-proxy") == "MISS"

      key = CacheKey.derive!(@options, "local://piece.wav")
      wait_until(fn -> match?({:ok, _entry}, VariantStore.head(key)) end)

      # The invariant the whole class split rests on: this variant is shared by
      # every `exp`, so the requester's remaining lifetime must not have been
      # stored with it. Writing the clamped policy here instead left all 1051
      # tests green, and would degrade the variant's cacheability permanently
      # for every later requester — including ones with no `exp` at all.
      {:ok, %{metadata: stored}} = VariantStore.head(key)
      assert stored.cache_control == "public, max-age=31536000, immutable, no-transform"

      bare = request(signed("/f:opus/br:96/plain/local://piece.wav"))

      # The stored object was written by an expiring URL and is served to one
      # that never carried a timestamp — which is only correct because nothing
      # about the requester was stored with it.
      assert header(bare, "x-audio-proxy") == "HIT"
      assert bare.resp_body == dated.resp_body

      # And it is served under the full year, not the expiring URL's remainder.
      assert header(bare, "cache-control") == "public, max-age=31536000, immutable, no-transform"
    end
  end

  describe "the expiring second" do
    test "a redirect with nothing left to sign for proxies the bytes instead" do
      # `exp` exactly now is the one second where the check passes — the
      # boundary is exclusive — and `clamp_ttl/2` is nevertheless 0. Signing for
      # zero seconds is not refused by the signer the way it looks like it
      # would be (`ExAws.S3.presigned_url/5` returns `{:ok, …X-Amz-Expires=0…}`),
      # so redirecting here would hand the client a URL that is already dead.
      #
      # Driven through `serve/3` rather than the router because the outcome must
      # not depend on which side of a second the request lands on: `remaining/1`
      # is 0 for `exp` at or before now, so this is deterministic where a signed
      # request would race the clock.
      put_config(%{variant_store: {:module, PresigningStore}, serve_mode: :redirect})
      key = store!("local://cached.wav")
      {:ok, entry} = VariantStore.head(key)

      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.assign(:options, %AudioProxy.Options{expires_at: System.system_time(:second)})

      assert {:ok, served} = AudioProxy.VariantCache.serve(conn, key, entry)

      assert served.status == 200
      assert served.resp_body == @variant
      assert header(served, "location") == nil
    end

    test "a redirect with a second left still redirects" do
      # The neighbouring case, so the clause above is a boundary rather than a
      # blanket disabling of redirect mode under `exp`.
      put_config(%{variant_store: {:module, PresigningStore}, serve_mode: :redirect})
      key = store!("local://cached.wav")
      {:ok, entry} = VariantStore.head(key)

      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.assign(:options, %AudioProxy.Options{
          expires_at: System.system_time(:second) + 5
        })

      assert {:ok, served} = AudioProxy.VariantCache.serve(conn, key, entry)

      assert served.status == 302
      assert served |> header("location") =~ ~r/expires_in=[1-5]$/
    end
  end
end
