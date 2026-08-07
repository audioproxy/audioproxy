defmodule AudioProxy.MetricsTest do
  @moduledoc """
  Events in, exposition out.

  The aggregator is attached at boot, so these tests emit the documented
  events directly rather than driving a render: what is under test is the
  mapping from an event to a series, and a real render would make the duration
  — the one number with arithmetic behind it — unpinnable.
  `AudioProxy.TelemetryTest` is what proves the render path emits these shapes
  in the first place, and `AudioProxy.MetricsEndpointTest` is what proves a
  real request cycle moves them.

  `async: false`: one ETS table, one process, one global.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AudioProxy.Metrics

  setup do
    Metrics.reset()
    :ok
  end

  defp scrape, do: Metrics.scrape() |> IO.iodata_to_binary()

  defp lines(prefix) do
    scrape()
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, prefix))
  end

  defp seconds(value),
    do: System.convert_time_unit(trunc(value * 1_000_000), :microsecond, :native)

  defp render_stop(format, outcome, duration) do
    :telemetry.execute(
      [:audio_proxy, :render, :stop],
      %{duration: seconds(duration), bytes: 0},
      %{format: format, source: "local://x.wav", cache_status: :miss, outcome: outcome}
    )
  end

  # Wrapped, like `AudioProxy.TelemetryTest`'s renders are: the boot-attached
  # `AudioProxy.LogHandler` is listening to these same events, and its warning
  # in the suite's output reads as something going wrong.
  defp render_exception(format, class, duration) do
    capture_log(fn ->
      :telemetry.execute(
        [:audio_proxy, :render, :exception],
        %{duration: seconds(duration), bytes: 0},
        %{format: format, source: "local://x.wav", cache_status: :miss, class: class}
      )
    end)
  end

  describe "render metrics" do
    test "a completed render counts as success and lands in the histogram" do
      render_stop(:mp3, :ok, 0.3)

      assert ~s(audio_proxy_renders_total{format="mp3",outcome="success"} 1) in lines(
               "audio_proxy_renders_total"
             )

      buckets = lines("audio_proxy_render_duration_seconds_bucket")

      # 0.3 s falls in the 0.5 bucket, so 0.1 and 0.25 are empty and everything
      # from 0.5 up carries it — that is what cumulative means, and getting it
      # backwards is the classic hand-rolled histogram bug.
      assert ~s(audio_proxy_render_duration_seconds_bucket{format="mp3",outcome="success",le="0.25"} 0) in buckets

      assert ~s(audio_proxy_render_duration_seconds_bucket{format="mp3",outcome="success",le="0.5"} 1) in buckets

      assert ~s(audio_proxy_render_duration_seconds_bucket{format="mp3",outcome="success",le="+Inf"} 1) in buckets

      assert ~s(audio_proxy_render_duration_seconds_sum{format="mp3",outcome="success"} 0.3) in lines(
               "audio_proxy_render_duration_seconds_sum"
             )
    end

    test "a failed render is counted under its failure class" do
      render_exception(:opus, :timeout, 300.0)

      assert ~s(audio_proxy_renders_total{format="opus",outcome="timeout"} 1) in lines(
               "audio_proxy_renders_total"
             )
    end

    test "a cancelled render is neither a success nor a failure" do
      render_stop(:wav, :cancelled, 1.0)

      assert lines("audio_proxy_renders_total") == [
               ~s(audio_proxy_renders_total{format="wav",outcome="cancelled"} 1)
             ]
    end

    test "an observation past the last edge lands only in +Inf" do
      render_stop(:flac, :ok, 600.0)

      buckets = lines("audio_proxy_render_duration_seconds_bucket")

      assert ~s(audio_proxy_render_duration_seconds_bucket{format="flac",outcome="success",le="300.0"} 0) in buckets

      assert ~s(audio_proxy_render_duration_seconds_bucket{format="flac",outcome="success",le="+Inf"} 1) in buckets
    end

    test "an event without a usable duration still counts, and does not observe zero" do
      :telemetry.execute(
        [:audio_proxy, :render, :stop],
        %{bytes: 0},
        %{format: :mp3, source: "local://x.wav", cache_status: :miss, outcome: :ok}
      )

      assert lines("audio_proxy_renders_total") == [
               ~s(audio_proxy_renders_total{format="mp3",outcome="success"} 1)
             ]

      # Counting it as a zero-second render would drag every latency quantile
      # down; a count that disagrees with `renders_total` at least shows up.
      assert lines("audio_proxy_render_duration_seconds_count") == []
    end
  end

  describe "cache metrics" do
    test "each outcome increments its own series" do
      for status <- [:hit, :hit, :miss, :coalesced] do
        AudioProxy.Telemetry.cache_lookup(%{status: status, format: :mp3})
      end

      assert lines("audio_proxy_cache_lookups_total") == [
               ~s(audio_proxy_cache_lookups_total{format="mp3",outcome="coalesced"} 1),
               ~s(audio_proxy_cache_lookups_total{format="mp3",outcome="hit"} 2),
               ~s(audio_proxy_cache_lookups_total{format="mp3",outcome="miss"} 1)
             ]
    end

    test "a write-back failure is counted" do
      capture_log(fn ->
        AudioProxy.Telemetry.store_write_failure(%{key: "abc", reason: :enospc})
      end)

      assert lines("audio_proxy_variant_store_write_failures_total") == [
               "audio_proxy_variant_store_write_failures_total 1"
             ]
    end
  end

  describe "queue metrics" do
    test "a rejection is counted and the semaphore's other events are not" do
      for event <- [:acquired, :queued, :released, :abandoned] do
        :telemetry.execute(
          [:audio_proxy, :semaphore, event],
          %{held: 1, queued: 0},
          %{capacity: 2, queue_size: 4}
        )
      end

      :telemetry.execute(
        [:audio_proxy, :semaphore, :rejected],
        %{held: 2, queued: 4, retry_after: 3},
        %{capacity: 2, queue_size: 4}
      )

      assert lines("audio_proxy_render_queue_rejections_total") == [
               "audio_proxy_render_queue_rejections_total 1"
             ]
    end

    test "occupancy is sampled from the semaphore, not replayed from events" do
      stats = AudioProxy.Semaphore.stats()

      assert lines("audio_proxy_render_slots_held") == [
               "audio_proxy_render_slots_held #{stats.held}"
             ]

      assert lines("audio_proxy_render_slots_capacity") == [
               "audio_proxy_render_slots_capacity #{stats.capacity}"
             ]

      assert lines("audio_proxy_render_queue_capacity") == [
               "audio_proxy_render_queue_capacity #{stats.queue_size}"
             ]
    end

    test "renders_running is sampled from the coalescing registry" do
      assert lines("audio_proxy_renders_running") == [
               "audio_proxy_renders_running #{AudioProxy.RenderCoordinator.in_flight()}"
             ]
    end
  end

  describe "HTTP metrics" do
    defp request(class, status) do
      conn = %Plug.Conn{status: status, assigns: %{endpoint_class: class}}

      capture_log(fn ->
        :telemetry.execute([:bandit, :request, :stop], %{duration: 1, resp_body_bytes: 0}, %{
          conn: conn
        })
      end)
    end

    test "requests are counted by endpoint class and status family" do
      request(:render, 200)
      request(:render, 200)
      request(:render, 404)
      request(:health, 200)

      assert lines("audio_proxy_http_requests_total") == [
               ~s(audio_proxy_http_requests_total{endpoint="health",status="2xx"} 1),
               ~s(audio_proxy_http_requests_total{endpoint="render",status="2xx"} 2),
               ~s(audio_proxy_http_requests_total{endpoint="render",status="4xx"} 1)
             ]
    end

    test "a request that never got a status is counted as unknown" do
      request(:render, nil)

      assert lines("audio_proxy_http_requests_total") == [
               ~s(audio_proxy_http_requests_total{endpoint="render",status="unknown"} 1)
             ]
    end

    test "a stop event with no conn is not attributed to an endpoint at all" do
      :telemetry.execute([:bandit, :request, :stop], %{duration: 1}, %{error: "malformed"})

      assert lines("audio_proxy_http_requests_total") == []
    end
  end

  describe "the handler survives what it is given" do
    test "an unreadable event is logged and the handler stays attached" do
      # Absent fields are total by construction — a missing format is
      # `unknown`, a duration that is not one is not observed — so provoking
      # the rescue takes something the handler has no way to anticipate: a
      # `conn` with no `assigns` on it.
      log =
        capture_log(fn ->
          :telemetry.execute([:bandit, :request, :stop], %{duration: 1}, %{conn: %{}})
        end)

      assert log =~ "metrics handler failed"

      # The whole point: `:telemetry` detaches a raising handler permanently,
      # so the next event has to still be counted.
      render_stop(:mp3, :ok, 0.1)

      assert lines("audio_proxy_renders_total") == [
               ~s(audio_proxy_renders_total{format="mp3",outcome="success"} 1)
             ]
    end
  end

  describe "surviving its own death" do
    test "a brutal kill restarts cleanly and keeps counting" do
      before = Process.whereis(Metrics)
      ref = Process.monitor(before)

      # `:kill` rather than `:stop`: it is the one exit that skips `terminate/2`,
      # so the handler outlives the table and `init/1` has to cope with an id
      # that is already attached. Asserting `:ok` on the re-attach instead put
      # the supervisor into a restart loop, and three of those took the whole
      # application down — from one kill.
      Process.exit(before, :kill)
      assert_receive {:DOWN, ^ref, :process, ^before, :killed}, 5_000

      restarted = await_restart(before)

      assert is_pid(restarted) and restarted != before

      # Attached exactly once per event, not twice — a restart that attached
      # without detaching would double-count everything it saw.
      events = for h <- :telemetry.list_handlers([]), h.id == Metrics, do: h.event_name

      assert events != []
      assert length(events) == length(Enum.uniq(events))

      Metrics.reset()
      render_stop(:mp3, :ok, 0.1)

      assert lines("audio_proxy_renders_total") == [
               ~s(audio_proxy_renders_total{format="mp3",outcome="success"} 1)
             ]
    end

    defp await_restart(old, attempts \\ 100) do
      case Process.whereis(Metrics) do
        nil when attempts > 0 -> Process.sleep(20) && await_restart(old, attempts - 1)
        ^old when attempts > 0 -> Process.sleep(20) && await_restart(old, attempts - 1)
        other -> other
      end
    end
  end

  describe "concurrent updates" do
    test "counters are exact under contention" do
      writers = 20
      per_writer = 200

      1..writers
      |> Task.async_stream(
        fn _ ->
          for _ <- 1..per_writer,
              do: AudioProxy.Telemetry.cache_lookup(%{status: :hit, format: :mp3})
        end,
        max_concurrency: writers,
        timeout: 30_000
      )
      |> Stream.run()

      assert lines("audio_proxy_cache_lookups_total") == [
               ~s(audio_proxy_cache_lookups_total{format="mp3",outcome="hit"} #{writers * per_writer})
             ]
    end
  end

  describe "a fresh process" do
    test "declares every metric, and starts unlabeled counters at zero" do
      output = scrape()

      for %{name: name, type: type} <- Metrics.definitions() do
        assert output =~ "# TYPE #{name} #{type}\n"
      end

      assert output =~ "audio_proxy_render_queue_rejections_total 0\n"
      assert output =~ "audio_proxy_variant_store_write_failures_total 0\n"
    end
  end
end
