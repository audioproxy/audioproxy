defmodule AudioProxy.MetricsEndpointTest do
  @moduledoc """
  `GET /metrics`: what a scraper receives, and where it may not receive it.

  The exposition is checked against a strict line grammar rather than against
  an expected string. A hand-rolled format has one failure mode that matters —
  producing something a scraper rejects — and an assertion on exact bytes
  cannot tell "this changed" from "this is now invalid". The grammar is the
  format's own (a `# HELP` line, a `# TYPE` line, or a sample), plus the two
  semantic rules a scraper enforces and an eyeball does not: every sample
  belongs to a declared metric, and a histogram's `+Inf` bucket equals its
  `_count`. `AudioProxy.Metrics.ExpositionTest` is where exact output is
  pinned, against series it wrote itself.

  The end-to-end block is tagged `:integration`: counters that move only
  because Bandit emitted an event need Bandit to have emitted one, which needs
  a socket.
  """

  use ExUnit.Case, async: false

  import AudioProxy.CoalesceHelper
  import AudioProxy.ConfigHelper
  import AudioProxy.SignedRequest, except: [conn: 3]
  import ExUnit.CaptureLog
  import Plug.Conn, only: [get_resp_header: 2]
  import Plug.Test

  alias AudioProxy.{Metrics, RawHttp, Signature}

  @moduletag tmp_dir: "metrics_endpoint"

  @metrics_opts AudioProxy.Metrics.Router.init([])
  @public_opts AudioProxy.Router.init([])

  @name "[a-zA-Z_:][a-zA-Z0-9_:]*"
  @pair ~S/[a-zA-Z_][a-zA-Z0-9_]*="(?:[^"\\]|\\.)*"/
  @value ~S/-?(?:\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|[+-]?Inf|NaN)/

  setup do
    Metrics.reset()
    :ok
  end

  defp scrape do
    conn(:get, "/metrics") |> AudioProxy.Metrics.Router.call(@metrics_opts)
  end

  describe "the scrape response" do
    test "is a 200 in the Prometheus text format, uncacheable" do
      conn = scrape()

      assert conn.status == 200

      assert get_resp_header(conn, "content-type") == [
               "text/plain; version=0.0.4; charset=utf-8"
             ]

      # A cached scrape is a measurement of a moment that has passed.
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "a HEAD says the target is up without rendering the numbers" do
      conn = conn(:head, "/metrics") |> AudioProxy.Metrics.Router.call(@metrics_opts)

      assert conn.status == 200
      assert conn.resp_body == ""
    end

    test "nothing else is served on this listener, and the refusal is uncacheable too" do
      conn = conn(:get, "/health") |> AudioProxy.Metrics.Router.call(@metrics_opts)

      assert conn.status == 404
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "a trailing slash is the same request" do
      # Plug drops the empty trailing segment, so `/metrics/` and `/metrics`
      # have identical `path_info` and neither listener treats them
      # differently. Pinned because it is the sort of thing a reader assumes
      # goes the other way.
      conn = conn(:get, "/metrics/") |> AudioProxy.Metrics.Router.call(@metrics_opts)

      assert conn.status == 200

      assert conn(:get, "/metrics/") |> AudioProxy.Router.call(@public_opts) |> Map.get(:status) ==
               404
    end
  end

  describe "the exposition grammar" do
    test "every line is a HELP line, a TYPE line, or a well-formed sample" do
      for line <- body_lines(scrape().resp_body) do
        assert valid_line?(line), "not valid exposition: #{inspect(line)}"
      end
    end

    test "every sample belongs to a metric that declared its type" do
      body = populated()

      declared = declared_types(body)

      for line <- body_lines(body), sample = sample_name(line) do
        assert base_name(sample, declared) != nil,
               "#{inspect(sample)} has no # TYPE line"
      end
    end

    test "a histogram's +Inf bucket equals its count" do
      body = populated()

      infinities =
        for %{"name" => name, "labels" => labels, "value" => value} <- samples(body),
            String.ends_with?(name, "_bucket"),
            labels =~ ~s(le="+Inf"),
            into: %{} do
          {String.replace_suffix(name, "_bucket", "") <> strip_le(labels), value}
        end

      counts =
        for %{"name" => name, "labels" => labels, "value" => value} <- samples(body),
            String.ends_with?(name, "_count"),
            into: %{} do
          {String.replace_suffix(name, "_count", "") <> labels, value}
        end

      assert map_size(infinities) > 0, "no histogram in the exposition to check"
      assert infinities == counts
    end

    test "the body ends in a newline, so a concatenating scraper is not off by one" do
      assert String.ends_with?(scrape().resp_body, "\n")
    end
  end

  describe "the public listener" do
    test "does not serve /metrics" do
      conn = conn(:get, "/metrics") |> AudioProxy.Router.call(@public_opts)

      # A 404 rather than the 401 every other unsigned single-segment path
      # gets: the scrape surface is genuinely not on this listener, and an
      # operator who pointed a scraper at the wrong port should be told that
      # rather than told about a signature.
      assert conn.status == 404
      assert conn.resp_body =~ "not_found"
    end

    test "does not serve HEAD /metrics either" do
      conn = conn(:head, "/metrics") |> AudioProxy.Router.call(@public_opts)

      assert conn.status == 404
    end
  end

  describe "end to end" do
    @describetag :integration

    setup %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "piece.wav"), "RIFF-fake-wav-bytes")

      put_config(base_config(local_root: tmp_dir))

      # `outcome="miss"` is only meaningful against a known-empty registry: a
      # coordinator left lingering by another test file asking for the same
      # fixture would make this request a `coalesced` one.
      reset_coordinators()

      {public, public_port} = listen(AudioProxy.FakeFfmpeg.Router)
      {metrics, metrics_port} = listen(Metrics.Router)

      {:ok,
       public: public_port,
       metrics: metrics_port,
       public_listener: public,
       metrics_listener: metrics}
    end

    test "a real request cycle moves the counters", %{public: public, metrics: metrics} do
      Metrics.reset()

      rest = "/f:mp3/cb:metrics-e2e/plain/local://piece.wav"
      path = "/#{Signature.sign(rest, key(), salt())}#{rest}"

      capture_log(fn ->
        socket = RawHttp.get(path, public)
        assert %{head: head} = RawHttp.read_one(socket, 5_000)
        assert head =~ "200 ok"
      end)

      body =
        await_scrape(metrics, ~s(audio_proxy_renders_total{format="mp3",outcome="success"} 1))

      # The render happened, it was a cache miss, and the request that carried
      # it was counted — the three signals from three different event families,
      # all moved by one GET.
      assert body =~ ~s(audio_proxy_cache_lookups_total{format="mp3",outcome="miss"} 1)
      assert body =~ ~s(audio_proxy_http_requests_total{endpoint="render",status="2xx"} 1)

      # And a scrape is a request too. Not in `body` — the exposition is
      # rendered before its own request's stop event fires, so a scrape reports
      # the scrape before it. That is the property, not a lag to work around:
      # it is what makes a scraper that stops reaching this port visible from
      # the last scrape that did.
      refute body =~ ~s(audio_proxy_http_requests_total{endpoint="metrics")

      assert await_scrape(
               metrics,
               ~s(audio_proxy_http_requests_total{endpoint="metrics",status="2xx"})
             )
    end

    test "the metrics listener is bound to one address, not to every interface", context do
      # Not a claim about firewalls — a claim that the listener took the `ip`
      # option rather than defaulting to `0.0.0.0`, which is the whole of §2's
      # bind restriction. `AudioProxy.Application` is what passes
      # `config.metrics_bind` into that option.
      assert {:ok, {{127, 0, 0, 1}, port}} =
               ThousandIsland.listener_info(context.metrics_listener)

      assert port == context.metrics
    end
  end

  ## Listeners

  defp listen(plug) do
    bandit =
      start_supervised!(
        {Bandit, plug: plug, scheme: :http, ip: {127, 0, 0, 1}, port: 0},
        id: plug
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    {bandit, port}
  end

  # Bandit's stop event is emitted after the response is written, so the
  # request may not be counted by the time the client has read it. Polling is
  # the honest wait: there is nothing to synchronise on that is not the
  # counter itself.
  defp await_scrape(port, expected, attempts \\ 50) do
    socket = RawHttp.get("/metrics", port)
    %{body: body} = RawHttp.read_one(socket, 5_000)

    cond do
      body =~ expected -> body
      attempts > 0 -> Process.sleep(20) && await_scrape(port, expected, attempts - 1)
      true -> flunk("counter never reached #{expected}; last scrape:\n#{body}")
    end
  end

  ## The grammar

  defp populated do
    :telemetry.execute(
      [:audio_proxy, :render, :stop],
      %{duration: System.convert_time_unit(300, :millisecond, :native), bytes: 1},
      %{format: :mp3, source: "local://x.wav", cache_status: :miss, outcome: :ok}
    )

    AudioProxy.Telemetry.cache_lookup(%{status: :hit, format: :mp3})

    scrape().resp_body
  end

  defp body_lines(body) do
    body |> String.split("\n") |> Enum.reject(&(&1 == ""))
  end

  defp valid_line?(line) do
    Regex.match?(~r/^# HELP #{@name} .*$/, line) or
      Regex.match?(~r/^# TYPE #{@name} (counter|gauge|histogram|summary|untyped)$/, line) or
      sample(line) != nil
  end

  # Strict on labels: the whole brace has to be a comma-separated run of
  # `name="escaped"` pairs and nothing else, so an unescaped quote or a stray
  # comma fails here rather than at a scraper.
  defp sample(line) do
    Regex.named_captures(
      ~r/^(?<name>#{@name})(?<labels>\{#{@pair}(?:,#{@pair})*\})? (?<value>#{@value})$/,
      line
    )
  end

  defp sample_name(line) do
    with %{"name" => name} <- sample(line), do: name
  end

  defp samples(body) do
    body |> body_lines() |> Enum.map(&sample/1) |> Enum.reject(&is_nil/1)
  end

  defp declared_types(body) do
    for line <- body_lines(body),
        match = Regex.run(~r/^# TYPE (#{@name}) \w+$/, line),
        into: MapSet.new(),
        do: Enum.at(match, 1)
  end

  # A sample's name is the metric's, except on a histogram, where it carries
  # one of three suffixes the `# TYPE` line does not.
  defp base_name(sample, declared) do
    ["", "_bucket", "_sum", "_count"]
    |> Enum.map(&String.replace_suffix(sample, &1, ""))
    |> Enum.find(&MapSet.member?(declared, &1))
  end

  defp strip_le(labels) do
    labels
    |> String.replace(~r/,?le="[^"]*"/, "")
    |> String.replace("{}", "")
  end
end
