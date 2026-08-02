defmodule AudioProxy.RenderSemaphoreTest do
  @moduledoc """
  The slot budget where it actually bites: renders, and the requests that ask
  for them.

  `AudioProxy.SemaphoreTest` proves the counting. This proves the wiring — that
  a slot is taken per *render* and not per request, that a coordinator waiting
  for one still coalesces, that a full queue reaches the client as §5's 429 with
  a `Retry-After`, and that a render which hangs rather than fails still gives
  its slot back.

  Driven against `fake_cmd.sh` and `fake_ffmpeg.sh` rather than the encoder: the
  scenarios are "hold a slot for thirty seconds" and "never produce a byte",
  which are properties of a subprocess and not of ffmpeg.

  `async: false`, because the config, the coalescing registry and the semaphore
  are all one global thing.
  """

  use ExUnit.Case, async: false

  import AudioProxy.CoalesceHelper
  import AudioProxy.ConfigHelper
  import Plug.Conn
  import Plug.Test

  alias AudioProxy.{RenderCoordinator, RenderHarness, Semaphore, Signature, VariantStore}
  alias AudioProxy.Ffmpeg.RenderSupervisor

  @moduletag tmp_dir: "render_semaphore"

  @key Base.decode16!("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")
  @salt Base.decode16!("FFEEDDCCBBAA99887766554433221100")

  @fake_opts AudioProxy.FakeFfmpeg.Router.init([])

  @paced ["emit", "63", "sleep", "0.1", "emit", "63"]
  @paced_bytes RenderHarness.pattern(126)

  # Long enough that it cannot plausibly end on its own, so a slot it holds is
  # held for the whole test.
  @forever ["sleep", "30"]

  @deadline 10_000

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "piece.wav"), "RIFF-fake-wav-bytes")
    # `fake_ffmpeg.sh` keys its behaviour off the basename: this one renders
    # nothing, ever. See its header.
    File.write!(Path.join(tmp_dir, "hang.wav"), "RIFF-fake-wav-bytes")

    put_config(%{
      key: @key,
      salt: @salt,
      allow_insecure: false,
      local_root: tmp_dir,
      max_src_bytes: 2_000_000_000
    })

    reset_coordinators()

    :ok
  end

  describe "the cap counts renders" do
    test "no more than AP_MAX_CONCURRENCY subprocesses run at once" do
      put_config(%{max_concurrency: 2, queue_size: 8})

      coordinators = for _ <- 1..4, do: start_subscriber(unique_key(), @forever)

      wait_until(fn -> length(running_renders()) == 2 end)

      # Held rather than merely reached: a cap that let the third through a
      # moment later would satisfy the line above.
      Process.sleep(200)
      assert length(running_renders()) == 2

      # The other two are alive and registered — queued, not rejected. A
      # subscriber cannot tell the difference, which is the design.
      assert Enum.count(coordinators, &(phase(&1) == :rendering)) == 2
      assert Enum.count(coordinators, &(phase(&1) == :queued)) == 2
    end

    test "everyone coalescing on one key shares its single slot" do
      # One slot and nowhere to wait: if coalescing cost a slot per subscriber,
      # four of these five would be rejected instead of served.
      put_config(%{max_concurrency: 1, queue_size: 0})

      key = unique_key()

      results =
        1..5
        |> Task.async_stream(fn _ -> subscribe_and_collect(key, @paced) end,
          max_concurrency: 5,
          timeout: @deadline
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(&1.status == :miss)) == 1

      for result <- results do
        assert result.outcome == :ok
        assert result.bytes == @paced_bytes
      end
    end

    test "a queued coordinator still coalesces, and its joiners get the whole stream" do
      put_config(%{max_concurrency: 1, queue_size: 4})

      # The one slot, taken by something that will not give it back on its own.
      blocker = start_subscriber(unique_key(), @forever)
      wait_until(fn -> phase(blocker) == :rendering end)

      key = unique_key()
      starter = Task.async(fn -> subscribe_and_collect(key, @paced) end)

      wait_until(fn -> registered(key) != nil end)
      assert phase(registered(key)) == :queued

      # Joining something that has not started is the case that only exists
      # because slots do: before this slice a coordinator was always rendering
      # by the time anyone could find it.
      joiner = Task.async(fn -> subscribe_and_collect(key, @paced) end)
      wait_until(fn -> length(subscribers(registered(key))) == 2 end)

      stop_subscriber(blocker)

      starter = Task.await(starter, @deadline)
      joiner = Task.await(joiner, @deadline)

      assert starter.status == :miss
      assert joiner.status == :coalesced
      assert starter.bytes == @paced_bytes
      assert joiner.bytes == @paced_bytes
    end
  end

  describe "the write-back tee and the queue" do
    @metadata %{
      content_type: "audio/mpeg",
      cache_control: "public, max-age=31536000, immutable",
      etag: ~s("deadbeef")
    }

    test "a render that queued still writes back once it gets its slot" do
      put_config(%{max_concurrency: 1, queue_size: 4, variant_store: {:file, store_root()}})

      blocker = start_subscriber(unique_key(), @forever)
      wait_until(fn -> phase(blocker) == :rendering end)

      key = store_key()
      collector = Task.async(fn -> subscribe_and_collect(key, @paced, metadata: @metadata) end)

      wait_until(fn -> registered(key) != nil end)
      assert phase(registered(key)) == :queued

      stop_subscriber(blocker)

      assert Task.await(collector, @deadline).bytes == @paced_bytes

      # The tee starts with the render rather than with the coordinator, so the
      # thing to prove is that starting it late loses nothing: the store holds
      # the whole stream, not the tail after the grant.
      wait_until(fn -> stored(key) == @paced_bytes end)
    end

    test "a queued render every client abandoned stops instead of rendering for the cache" do
      put_config(%{max_concurrency: 1, queue_size: 4, variant_store: {:file, store_root()}})

      blocker = start_subscriber(unique_key(), @forever)
      wait_until(fn -> phase(blocker) == :rendering end)

      key = store_key()
      client = start_subscriber(key, @paced, metadata: @metadata)
      assert phase(client) == :queued

      # With a store configured the tee is a subscriber, and it is what keeps a
      # render alive after the last client leaves. While queued there is no tee
      # yet, on purpose: a render nobody is waiting for must not hold its place
      # in the queue and then spend a slot encoding for the cache alone — under
      # exactly the contention that made it queue.
      monitor = Process.monitor(client)
      stop_subscriber(client)
      assert_receive {:DOWN, ^monitor, :process, ^client, _reason}, @deadline

      stop_subscriber(blocker)

      # Nothing rendered, so nothing was stored, and the slot went nowhere.
      refute stored?(key)
      wait_until(fn -> match?(%{held: 0, queued: 0}, Semaphore.stats()) end)
    end
  end

  describe "a full queue" do
    test "is refused with an estimate rather than queued" do
      put_config(%{max_concurrency: 1, queue_size: 0})

      blocker = start_subscriber(unique_key(), @forever)
      wait_until(fn -> phase(blocker) == :rendering end)

      key = unique_key()
      assert {:error, {:queue_full, retry_after}} = subscribe(key, @paced)
      assert is_integer(retry_after) and retry_after >= 1

      # And nothing was left registered under it: the next request has to ask
      # the semaphore again rather than attach to a coordinator that will never
      # render.
      assert registered(key) == nil
    end

    test "a wait that outlasts the budget is 429, not a 504 naming the render" do
      # The wait has to clear the consumer's whole deadline — `AP_RENDER_TIMEOUT`
      # plus the margin, so 2 s at the one-second floor — or this passes against
      # the bug it exists for.
      put_config(%{max_concurrency: 1, queue_size: 4, render_timeout: 1})

      holder = hold_a_slot()
      Process.send_after(holder, :release, 2_500)

      conn = render("/f:mp3/plain/local://piece.wav")

      # This was a 504 `render_timeout` — "Render exceeded AP_RENDER_TIMEOUT" —
      # for a render that had not begun, with the request log repeating the same
      # wrong thing. It is the queue that ran out of time, which is the 429 the
      # semaphore would have given up front had the queue been full rather than
      # merely slow.
      assert conn.status == 429
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) >= 1
      assert conn.assigns.error_class == :queue_full
    end

    test "a wait inside the budget still renders" do
      put_config(%{max_concurrency: 1, queue_size: 4, render_timeout: 1})

      holder = hold_a_slot()
      Process.send_after(holder, :release, 300)

      conn = render("/f:mp3/plain/local://piece.wav")

      assert conn.status == 200
      assert get_resp_header(conn, "x-audio-proxy") == ["MISS"]
    end

    test "a render that hangs after taking its slot is still a 504" do
      # The other side of the split: this request queued *and* rendered, and it
      # is the render that went silent. Answering 429 here would be the same
      # mistake in the opposite direction.
      put_config(%{max_concurrency: 1, queue_size: 4, render_timeout: 1})

      holder = hold_a_slot()
      Process.send_after(holder, :release, 200)

      conn = render("/f:mp3/plain/local://hang.wav")

      assert conn.status == 504
      assert conn.assigns.error_class == :render_timeout
    end

    test "reaches the client as a 429 carrying Retry-After" do
      put_config(%{max_concurrency: 1, queue_size: 0})

      # The slot is taken directly rather than by a render: what this test is
      # about is the response, and a subprocess would only add a way for it to
      # be flaky.
      hold_a_slot()

      conn = render("/f:mp3/plain/local://piece.wav")

      assert conn.status == 429
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) >= 1

      assert JSON.decode!(conn.resp_body) == %{
               "error" => "queue_full",
               "message" => "Render queue is full"
             }

      # The request log names the same word the body does.
      assert conn.assigns.error_class == :queue_full
    end
  end

  describe "a render that hangs" do
    test "gives its slot back at AP_RENDER_TIMEOUT, and the queue moves" do
      # One slot, and a render allowed one second of it.
      put_config(%{max_concurrency: 1, queue_size: 4, render_timeout: 1})

      # A subprocess that never writes a byte and never exits — the shape of a
      # stalled origin, which is the case `AudioProxy.Source.ffmpeg_input/1`
      # refuses locally and cannot refuse for a remote backend. The slot has to
      # come back from the timeout, because nothing else will end this.
      stalled = Task.async(fn -> subscribe_and_collect(unique_key(), @forever) end)
      wait_until(fn -> length(running_renders()) == 1 end)

      queued = Task.async(fn -> subscribe_and_collect(unique_key(), @paced) end)

      assert {:error, %{class: :timeout}} = Task.await(stalled, @deadline).outcome

      # The whole point: the slot the timeout freed was granted to the waiter,
      # which then rendered normally.
      queued = Task.await(queued, @deadline)
      assert queued.outcome == :ok
      assert queued.bytes == @paced_bytes

      # And the accounting survived a render that hung rather than failed:
      # nothing is still held by a coordinator that is gone.
      wait_until(fn -> match?(%{held: 0, queued: 0}, Semaphore.stats()) end)
    end
  end

  ## Helpers

  defp unique_key, do: "slot-#{System.unique_integer([:positive, :monotonic])}"

  defp spec(directives, opts) do
    [args: directives, executable: RenderHarness.fake_cmd()] ++ Keyword.take(opts, [:metadata])
  end

  defp subscribe(key, directives, opts \\ []) do
    RenderCoordinator.subscribe(key, spec(directives, opts))
  end

  # The store keys on the cache key, and `VariantStore.Local` expects the hex
  # shape `CacheKey.derive!/2` produces rather than this file's readable ones.
  defp store_key do
    :sha256
    |> :crypto.hash("slot-#{System.unique_integer([:positive, :monotonic])}")
    |> Base.encode16(case: :lower)
  end

  defp store_root do
    root = Path.join(System.tmp_dir!(), "slot-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    root
  end

  defp stored(key) do
    case VariantStore.get_stream(key, nil) do
      {:ok, stream} -> stream |> Enum.to_list() |> IO.iodata_to_binary()
      _other -> nil
    end
  end

  defp stored?(key), do: stored(key) != nil

  # A subscriber that exists and does nothing else, so the render it started
  # stays up until this test says otherwise. Returns the coordinator.
  defp start_subscriber(key, directives, opts \\ []) do
    test = self()

    pid =
      spawn(fn ->
        {:ok, _status, render, _backlog} = subscribe(key, directives, opts)
        send(test, {:subscribed, self(), render})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)

    assert_receive {:subscribed, ^pid, render}, @deadline

    Process.put({:subscriber, render}, pid)
    render
  end

  # Kills the subscriber, which is the last one, which stops the coordinator,
  # which releases the slot — and waits for that to have happened rather than
  # for it to have been asked for.
  defp stop_subscriber(coordinator) do
    monitor = Process.monitor(coordinator)
    Process.exit(Process.get({:subscriber, coordinator}), :kill)

    assert_receive {:DOWN, ^monitor, :process, ^coordinator, _reason}, @deadline
  end

  # Takes a slot in a process of its own and keeps it until the test ends, or
  # until the returned pid is sent `:release`.
  defp hold_a_slot do
    test = self()

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

  defp subscribe_and_collect(key, directives, opts \\ []) do
    {:ok, status, render, backlog} = subscribe(key, directives, opts)

    collect(render, %{status: status, chunks: Enum.reverse(backlog), outcome: nil, bytes: nil})
  end

  defp collect(render, acc) do
    receive do
      {:chunk, ^render, data} ->
        collect(render, %{acc | chunks: [data | acc.chunks]})

      {:done, ^render, _info} ->
        %{acc | outcome: :ok, bytes: joined(acc)}

      {:error, ^render, failure} ->
        %{acc | outcome: {:error, failure}, bytes: joined(acc)}
    after
      @deadline -> %{acc | outcome: :timeout, bytes: joined(acc)}
    end
  end

  defp joined(acc), do: acc.chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp render(rest) do
    signed = "/#{Signature.sign(rest, @key, @salt)}#{rest}"

    conn(:get, signed) |> AudioProxy.FakeFfmpeg.Router.call(@fake_opts)
  end

  ## Probing

  defp running_renders do
    RenderSupervisor |> DynamicSupervisor.which_children() |> Enum.map(&elem(&1, 1))
  end

  # White-box, for the same reason `AudioProxy.RenderCoordinatorTest` reaches
  # for it: "queued rather than rendering" has no public accessor and wants
  # none, but it is exactly what these tests are about.
  defp phase(coordinator), do: coordinator |> :sys.get_state() |> Map.fetch!(:phase)

  defp subscribers(coordinator) do
    coordinator |> :sys.get_state() |> Map.fetch!(:subscribers) |> Map.keys()
  end

  defp registered(key) do
    case Registry.lookup(RenderCoordinator.Registry, key) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  defp wait_until(condition, remaining \\ @deadline) do
    cond do
      condition.() ->
        :ok

      remaining <= 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(20)
        wait_until(condition, remaining - 20)
    end
  end
end
