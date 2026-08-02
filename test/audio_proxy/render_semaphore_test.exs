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

  alias AudioProxy.{RenderCoordinator, RenderHarness, Semaphore, Signature}
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

  defp spec(directives), do: [args: directives, executable: RenderHarness.fake_cmd()]

  defp subscribe(key, directives), do: RenderCoordinator.subscribe(key, spec(directives))

  # A subscriber that exists and does nothing else, so the render it started
  # stays up until this test says otherwise. Returns the coordinator.
  defp start_subscriber(key, directives) do
    test = self()

    pid =
      spawn(fn ->
        {:ok, _status, render, _backlog} = subscribe(key, directives)
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

  # Takes a slot in a process of its own and keeps it until the test ends.
  defp hold_a_slot do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:holding, Semaphore.request()})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)

    assert_receive {:holding, :granted}, @deadline
  end

  defp subscribe_and_collect(key, directives) do
    {:ok, status, render, backlog} = subscribe(key, directives)

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
