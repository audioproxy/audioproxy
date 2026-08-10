defmodule AudioProxy.VariantCacheS3Test do
  @moduledoc """
  Redirect mode end to end, against a real store.

  `AudioProxy.VariantCacheTest` covers the redirect *branch* — the 302, the
  `no-store`, the TTL, the proxy-instead fallback — against a stand-in backend
  that returns a plausible URL nobody fetches. What it cannot show, and what
  the documented default's whole value rests on, is that the URL works: that a
  client following the `Location` receives the variant, under the headers a
  proxied HIT would have sent, with no proxy in the path to correct them.

  That is one claim and it needs a store, a signature the store verifies, and
  the same request served both ways to compare. Tagged `:minio`; see
  `docs/development.md`.
  """

  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper
  import AudioProxy.SignedRequest, except: [conn: 3]
  import Plug.Conn
  import Plug.Test

  alias AudioProxy.{CacheKey, MinioHelper, Signature, VariantStore}

  @moduletag :minio
  @moduletag timeout: 120_000
  # The store is S3; the *source* scheme still has to be enabled for the URL to
  # parse at all, and the directory stays empty on purpose — see the setup.
  @moduletag tmp_dir: "variant_cache_s3"

  @bucket "audio-proxy-variants"

  @opts AudioProxy.Router.init([])

  # Patterned rather than random, so a wrong slice or a truncated body is a
  # mismatch and not a coincidence.
  @variant Enum.map_join(0..999, fn n -> <<rem(n, 256)>> end)

  @content_type "audio/ogg"
  @cache_control "public, max-age=31536000, immutable, no-transform"

  @options "f:opus/br:96"
  @rest "/f:opus/br:96/plain/local://cached.wav"

  setup %{tmp_dir: tmp_dir} do
    MinioHelper.configure!(%{
      key: key(),
      salt: salt(),
      allow_insecure: false,
      local_root: tmp_dir,
      variant_store: {:s3, @bucket},
      serve_mode: :redirect
    })

    MinioHelper.ensure_bucket!(@bucket)

    # Stored directly, and under a source that does not exist: a HIT is checked
    # before the stat, so this asserts the cache path and nothing else.
    key = CacheKey.derive!(@options, "local://cached.wav")

    :ok =
      VariantStore.put_stream(key, [@variant], %{
        content_type: @content_type,
        cache_control: @cache_control,
        etag: ~s("#{key}")
      })

    {:ok, key: key}
  end

  defp request(rest) do
    "/#{Signature.sign(rest, key(), salt())}#{rest}"
    |> then(&conn(:get, &1))
    |> AudioProxy.Router.call(@opts)
  end

  test "a HIT is a 302 to a URL that is not cached", %{key: key} do
    conn = request(@rest)

    assert conn.status == 302
    assert conn.resp_body == ""
    assert get_resp_header(conn, "x-audio-proxy") == ["HIT"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert [location] = get_resp_header(conn, "location")
    assert location =~ key
  end

  test "following the Location delivers the variant, byte for byte" do
    assert [location] = get_resp_header(request(@rest), "location")

    assert {200, headers, body} = MinioHelper.fetch(location)
    assert body == @variant
    assert headers["content-length"] == "1000"
  end

  test "and delivers it under the headers a proxied HIT would have sent" do
    # The one assertion that needs both modes: the client must not be able to
    # tell which one served it, because §5 makes the serve mode an operator's
    # choice rather than part of the contract.
    assert [location] = get_resp_header(request(@rest), "location")
    assert {200, redirected, _body} = MinioHelper.fetch(location)

    put_config(%{serve_mode: :proxy})
    proxied = request(@rest)

    assert proxied.status == 200
    assert redirected["content-type"] == hd(get_resp_header(proxied, "content-type"))
    assert redirected["cache-control"] == hd(get_resp_header(proxied, "cache-control"))
    assert redirected["content-type"] == @content_type
    assert redirected["cache-control"] == @cache_control
  end

  test "the store serves Ranges the proxy would have had to implement" do
    # Which is the point of handing the client the store: a 302'd variant is
    # seekable without a byte crossing the BEAM.
    assert [location] = get_resp_header(request(@rest), "location")

    assert {:ok, {{_version, 206, _reason}, _headers, body}} =
             :httpc.request(
               :get,
               {String.to_charlist(location), [{~c"range", ~c"bytes=10-19"}]},
               [],
               body_format: :binary
             )

    assert body == binary_part(@variant, 10, 10)
  end
end
