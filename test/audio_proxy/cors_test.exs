defmodule NegotiatingPlug do
  @moduledoc """
  The CORS plug over a response that sets a `Vary` of its own.

  Mounted the way `AudioProxy.Router` mounts it — CORS above, the responding
  plug below — because the ordering is the whole subject: a callback
  registered below this one runs *before* it. `?vary=` names the value, so one
  plug covers both the append and the already-present case.
  """

  use Plug.Builder

  plug AudioProxy.Plugs.Cors
  plug :respond

  def respond(conn, _opts) do
    vary =
      conn
      |> fetch_query_params()
      |> Map.fetch!(:query_params)
      |> Map.get("vary", "Accept-Encoding")

    conn |> put_resp_header("vary", vary) |> send_resp(200, "")
  end
end

defmodule AudioProxy.CorsTest do
  @moduledoc """
  What a browser on another origin can see, and what it can see today.

  Two halves, and the first is the more important one: with `AP_ALLOW_ORIGIN`
  unset every response is the response a proxy without this feature sends, and
  `OPTIONS` is the 404 that API doc §2 promises for every non-GET method. The
  second half walks the response codes a fetching page actually meets — the
  200, the HIT redirect, the 4xx, the 5xx, the queue-full 429 — because the
  headers are worth nothing if they are missing from precisely the responses a
  client needs to read.

  Config parsing lives in `AudioProxy.ConfigTest`; the boot refusal is here
  because it is the *behaviour* an operator meets, not another parser case.
  """

  use ExUnit.Case, async: false

  import AudioProxy.CoalesceHelper
  import AudioProxy.ProbeCoalesceHelper
  import AudioProxy.ConfigHelper
  import AudioProxy.SignedRequest, except: [conn: 3]
  import Plug.Conn
  import Plug.Test

  alias AudioProxy.{CacheKey, Config, PresigningStore, Semaphore, SignedRequest, VariantStore}

  @moduletag tmp_dir: "cors"

  @opts AudioProxy.Router.init([])
  @fake_opts AudioProxy.FakeFfmpeg.Router.init([])

  @origin "https://app.example.com"
  @expose "x-audio-proxy, retry-after, accept-ranges, etag"

  @deadline 5_000

  @options "f:mp3"
  @rest "/f:mp3/plain/local://piece.wav"

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "piece.wav"), "RIFF-fake-wav-bytes")
    # `fake_ffmpeg.sh` keys its behaviour off the basename: this one fails
    # before the first byte, which is how a 500 is reached without a socket.
    File.write!(Path.join(tmp_dir, "failfast.wav"), "RIFF-fake-wav-bytes")

    put_config(base_config(local_root: tmp_dir))

    reset_coordinators()
    reset_probes()
    PresigningStore.reset()

    :ok
  end

  ## Helpers

  defp request(method, path), do: conn(method, path) |> AudioProxy.Router.call(@opts)

  defp render(rest) do
    SignedRequest.conn(:get, signed(rest), []) |> AudioProxy.FakeFfmpeg.Router.call(@fake_opts)
  end

  defp cors_headers(conn) do
    Enum.filter(conn.resp_headers, fn {name, _value} ->
      String.starts_with?(name, "access-control-")
    end)
  end

  defp refute_cors(conn) do
    assert cors_headers(conn) == []
    assert get_resp_header(conn, "vary") == []
    conn
  end

  # A slot held by a process that will not give it back, so anything needing a
  # render is refused outright rather than queued.
  defp hold_a_slot do
    test = self()

    # It has to stay alive holding it: a process that exits gives the slot
    # back, and the next request is served instead of refused.
    pid =
      spawn(fn ->
        send(test, {:holding, Semaphore.request()})

        receive do
          :release -> Semaphore.release()
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:holding, :granted}, @deadline

    pid
  end

  # A preflight whose `Access-Control-Request-Headers` is `asked`.
  defp preflight_asking(asked) do
    SignedRequest.conn(:options, signed(@rest), [
      {"origin", @origin},
      {"access-control-request-method", "GET"},
      {"access-control-request-headers", asked}
    ])
    |> AudioProxy.Router.call(@opts)
  end

  # Puts a variant in the store under the key `@rest` resolves to, so the next
  # request for it is a HIT with no render behind it.
  defp store_variant! do
    key = CacheKey.derive!(@options, "local://piece.wav")

    :ok =
      VariantStore.put_stream(key, ["cached-bytes"], %{
        content_type: "audio/mpeg",
        cache_control: "public, max-age=31536000, immutable, no-transform",
        etag: ~s("#{key}")
      })

    key
  end

  describe "unset — today's behaviour, pinned" do
    test "no CORS header on a rendered 200" do
      conn = refute_cors(render(@rest))

      assert conn.status == 200
    end

    test "no CORS header on a HIT redirect" do
      put_config(%{variant_store: {:module, PresigningStore}, serve_mode: :redirect})
      store_variant!()

      conn = refute_cors(render(@rest))

      assert conn.status == 302
    end

    test "no CORS header on the 404" do
      assert refute_cors(request(:get, "/nothing/here")).status == 401
      assert refute_cors(request(:get, "/")).status == 404
    end

    test "no CORS header on the queue-full 429" do
      put_config(%{max_concurrency: 1, queue_size: 0})
      hold_a_slot()

      conn = refute_cors(render(@rest))

      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") != []
    end

    test "OPTIONS is the 404 every other non-GET method is" do
      conn = refute_cors(request(:options, signed(@rest)))

      assert conn.status == 404
      assert JSON.decode!(conn.resp_body)["error"] == "not_found"
    end
  end

  describe "enabled" do
    setup do
      put_config(%{allow_origin: @origin})
      :ok
    end

    test "a rendered 200 carries the allow, expose and vary headers" do
      conn = render(@rest)

      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
      assert get_resp_header(conn, "access-control-expose-headers") == [@expose]
      assert get_resp_header(conn, "vary") == ["Origin"]
    end

    test "so does the HIT redirect" do
      put_config(%{variant_store: {:module, PresigningStore}, serve_mode: :redirect})
      store_variant!()

      conn = render(@rest)

      assert conn.status == 302
      assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
    end

    test "so does a 4xx — an unreadable error envelope is no error at all" do
      conn =
        request(:get, "/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/f:opus/plain/s3://b/k.wav")

      assert conn.status == 401
      assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
      assert get_resp_header(conn, "access-control-expose-headers") == [@expose]
    end

    test "and a 5xx" do
      conn = render("/f:mp3/plain/local://failfast.wav")

      assert conn.status == 500
      assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
    end

    test "so does `/info`, the other endpoint a page fetches rather than plays" do
      conn = render("/info/plain/local://piece.wav")

      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
      assert get_resp_header(conn, "access-control-expose-headers") == [@expose]
    end

    test "`Vary: Origin` is appended to what the response already varies on" do
      # Mounted the way the router mounts it, over a plug that negotiates on
      # something of its own. Not replaced: every plug below the CORS one
      # registers its before-send callback later and callbacks run
      # newest-first, so this one runs last — an assignment here would be the
      # one that silently won.
      conn = Plug.Test.conn(:get, "/") |> NegotiatingPlug.call(NegotiatingPlug.init([]))

      assert get_resp_header(conn, "vary") == ["Accept-Encoding, Origin"]
    end

    test "and is not duplicated when the response already varies on it" do
      conn =
        Plug.Test.conn(:get, "/?vary=Origin") |> NegotiatingPlug.call(NegotiatingPlug.init([]))

      assert get_resp_header(conn, "vary") == ["Origin"]
    end

    test "`*` allows everyone and varies on nothing" do
      put_config(%{allow_origin: "*"})

      conn = render(@rest)

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      # A response identical for every origin must not teach a cache to key on
      # one — `Vary: Origin` under `*` would fragment every CDN entry by a
      # header that changed nothing.
      assert get_resp_header(conn, "vary") == []
    end
  end

  describe "the exposed headers" do
    setup do
      put_config(%{allow_origin: @origin})
      :ok
    end

    test "`Retry-After` on the queue-full 429 is one of them" do
      put_config(%{max_concurrency: 1, queue_size: 0})
      hold_a_slot()

      conn = render(@rest)

      assert conn.status == 429
      # Both halves matter: the header is sent, and the CORS filter is told to
      # let the page read it. Either alone leaves a client backing off blind.
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) >= 1
      assert get_resp_header(conn, "access-control-expose-headers") == [@expose]
    end

    test "`x-audio-proxy` on a render is another" do
      conn = render(@rest)

      assert get_resp_header(conn, "x-audio-proxy") == ["MISS"]
      assert [exposed] = get_resp_header(conn, "access-control-expose-headers")
      assert exposed =~ "x-audio-proxy"
    end
  end

  describe "preflight" do
    setup do
      put_config(%{allow_origin: @origin})
      :ok
    end

    test "is a bodiless 204 naming the methods, the age and the echoed headers" do
      conn =
        SignedRequest.conn(:options, signed(@rest), [
          {"origin", @origin},
          {"access-control-request-method", "GET"},
          {"access-control-request-headers", "x-request-id, cache-control"}
        ])
        |> AudioProxy.Router.call(@opts)

      assert conn.status == 204
      assert conn.resp_body == ""
      assert get_resp_header(conn, "access-control-allow-methods") == ["GET, HEAD"]
      assert get_resp_header(conn, "access-control-max-age") == ["86400"]

      assert get_resp_header(conn, "access-control-allow-headers") == [
               "x-request-id, cache-control"
             ]

      assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
    end

    test "omits the allow-headers echo when the browser asked for none" do
      conn = request(:options, signed(@rest))

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-headers") == []
    end

    # The echo is the one part of the response a client writes, so what comes
    # back is the header names that are actually header names. Anything else
    # was not sent by a browser, and reflecting it would put a malformed
    # header on the wire — or, for a control character, raise from inside the
    # before-send callback and turn a preflight into a 500.
    test "echoes only the well-formed header names, and drops the rest" do
      conn = preflight_asking("x-request-id, not a name, \"quoted\", cache-control")

      assert conn.status == 204

      assert get_resp_header(conn, "access-control-allow-headers") == [
               "x-request-id, cache-control"
             ]
    end

    test "omits the echo entirely when nothing in the list is a header name" do
      conn = preflight_asking("\"quoted\"")

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-headers") == []
    end

    test "a control character is dropped rather than raised on" do
      conn = preflight_asking("x-fine\r\nx-injected: 1")

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-headers") == []
    end

    test "answers an unsigned path too — it carries no credentials to check" do
      assert request(:options, "/anything").status == 204
    end

    test "leaves every other non-GET method on the 404" do
      assert request(:post, signed(@rest)).status == 404
      assert request(:delete, "/").status == 404
    end
  end

  describe "boot" do
    test "refuses a value that is not an origin at all, naming the variable" do
      for value <- [
            "app.example.com",
            "https://",
            "https://app.example.com/path",
            "https://app.example.com?a=1",
            "https://user:pw@app.example.com",
            "*.example.com"
          ] do
        assert_raise Config.Error, ~r/AP_ALLOW_ORIGIN/, fn ->
          Config.build!(%{"AP_ALLOW_ORIGIN" => value})
        end
      end
    end

    # The dangerous family: each of these means the right origin to a person
    # and matches nothing in a browser, which compares the header to its own
    # `Origin` byte for byte. Accepted, they would boot a proxy that sends a
    # CORS header allowing nobody — a failure visible only as an opaque fetch
    # error in someone else's page.
    test "refuses a near-miss spelling, and says what to write instead" do
      for {value, canonical} <- [
            {"https://app.example.com/", "https://app.example.com"},
            {"HTTPS://APP.Example.com", "https://app.example.com"},
            {"https://app.example.com.", "https://app.example.com"},
            {"https://app.example.com:443", "https://app.example.com"},
            {"http://app.example.com:80", "http://app.example.com"},
            {"https://app.example.com:0443", "https://app.example.com"},
            {"https://app.example.com:", "https://app.example.com"}
          ] do
        message =
          assert_raise Config.Error, fn -> Config.build!(%{"AP_ALLOW_ORIGIN" => value}) end

        assert message.message =~ "AP_ALLOW_ORIGIN"
        assert message.message =~ canonical
      end
    end

    test "accepts `*`, a non-default port, either scheme, and an IPv6 literal" do
      for value <- [
            "*",
            "https://app.example.com",
            "http://localhost:5173",
            "http://[::1]:5173"
          ] do
        assert Config.build!(%{"AP_ALLOW_ORIGIN" => value}).allow_origin == value
      end
    end

    test "is unset by default" do
      assert Config.build!(%{}).allow_origin == nil
      assert Config.build!(%{"AP_ALLOW_ORIGIN" => "  "}).allow_origin == nil
    end
  end
end
