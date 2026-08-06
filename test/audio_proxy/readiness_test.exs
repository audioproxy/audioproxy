defmodule AudioProxy.ReadinessTest do
  @moduledoc """
  The latch itself: when it trips, when it recovers, and what it does when the
  thing it measures is not there.

  Each test runs its own semaphore and its own latch, so depth is something
  this test made happen rather than something the suite happened to be doing.
  The threshold is global config, though, so anything that sets it is
  `async: false`; the cases that only need the *default* threshold live in
  `AudioProxy.ConfigTest`.
  """

  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper

  alias AudioProxy.Readiness
  alias AudioProxy.Semaphore

  @deadline 2_000

  describe "tripping" do
    test "stays ready while depth is below the threshold" do
      readiness = start_latch(threshold: 4, capacity: 1, queue_size: 8)

      assert %{ready?: true, queued: 0, threshold: 4} = Readiness.check(readiness)

      # One holder, three waiters: depth 3, one short of the threshold.
      fill(readiness, 1 + 3)

      assert %{ready?: true, queued: 3} = Readiness.check(readiness)
    end

    test "trips once depth reaches the threshold" do
      readiness = start_latch(threshold: 4, capacity: 1, queue_size: 8)

      fill(readiness, 1 + 4)

      assert %{ready?: false, queued: 4, threshold: 4} = Readiness.check(readiness)
    end
  end

  describe "hysteresis" do
    test "recovers only at half the threshold, so an excursion flips once" do
      readiness = start_latch(threshold: 4, capacity: 1, queue_size: 8)

      # Up: one holder plus four waiters.
      waiters = fill(readiness, 1 + 4)
      assert %{ready?: false} = Readiness.check(readiness)

      # Down past the threshold but not to the recovery mark. Instantaneous
      # depth would have called this ready again; the latch does not.
      [first, second | _rest] = waiters
      drop(readiness, first)
      assert %{ready?: false, queued: 3} = Readiness.check(readiness)

      # `div(4, 2)` is 2, and recovery is at or below the mark — so this is
      # the single flip back, three samples and two crossings later.
      drop(readiness, second)
      assert %{ready?: true, queued: 2} = Readiness.check(readiness)
    end

    test "re-trips only at the threshold, not at the recovery mark" do
      readiness = start_latch(threshold: 4, capacity: 1, queue_size: 8)

      waiters = fill(readiness, 1 + 4)
      assert %{ready?: false} = Readiness.check(readiness)

      [first, second | _rest] = waiters
      drop(readiness, first)
      drop(readiness, second)
      assert %{ready?: true, queued: 2} = Readiness.check(readiness)

      # Back up to 3 — above the recovery mark, below the threshold. The band
      # between the two marks is where a flapping node would live.
      fill(readiness, 1)
      assert %{ready?: true, queued: 3} = Readiness.check(readiness)

      fill(readiness, 1)
      assert %{ready?: false, queued: 4} = Readiness.check(readiness)
    end

    test "a threshold of 1 recovers only on an empty queue" do
      readiness = start_latch(threshold: 1, capacity: 1, queue_size: 4)

      [waiter] = fill(readiness, 1 + 1)
      assert %{ready?: false, queued: 1} = Readiness.check(readiness)

      drop(readiness, waiter)
      assert %{ready?: true, queued: 0} = Readiness.check(readiness)
    end
  end

  describe "disabled" do
    test "a threshold of zero is always ready, however deep the queue" do
      readiness = start_latch(threshold: 0, capacity: 1, queue_size: 8)

      fill(readiness, 1 + 8)

      assert %{ready?: true, queued: 8, threshold: 0} = Readiness.check(readiness)
    end

    test "disabling clears a latch that had already tripped" do
      readiness = start_latch(threshold: 4, capacity: 1, queue_size: 8)

      fill(readiness, 1 + 4)
      assert %{ready?: false} = Readiness.check(readiness)

      put_config(%{ready_queue_threshold: 0})

      assert %{ready?: true} = Readiness.check(readiness)
    end
  end

  describe "failing toward ready" do
    test "an unreadable depth reads as an empty queue" do
      # A semaphore that is not running is what a restart looks like from
      # here. The node is otherwise fine, so ejecting it would be the outage.
      readiness = start_latch(threshold: 1, capacity: 1, queue_size: 4)
      stop_supervised!(semaphore_id(readiness))

      assert %{ready?: true, queued: 0} = Readiness.check(readiness)
    end

    test "an unreachable latch answers ready rather than raising" do
      assert %{ready?: true, queued: 0} = Readiness.check(:no_such_readiness_server)
    end

    test "the fallback reports the configured threshold, not the disabled sentinel" do
      # `0` is what "readiness is switched off" looks like in the body, so
      # reporting it for a latch that is merely unreachable would tell an
      # operator the one thing that is certainly untrue.
      put_config(%{ready_queue_threshold: 7})

      assert %{ready?: true, threshold: 7} = Readiness.check(:no_such_readiness_server)
    end
  end

  ## Helpers

  # A semaphore and a latch reading it, both pinned to this test. Returns the
  # latch; `semaphore_id/1` recovers the semaphore's name from it.
  defp start_latch(opts) do
    put_config(%{ready_queue_threshold: Keyword.fetch!(opts, :threshold)})

    unique = System.unique_integer([:positive, :monotonic])
    semaphore = :"readiness_semaphore_#{unique}"
    readiness = :"readiness_#{unique}"

    start_supervised!(
      {Semaphore,
       name: semaphore,
       capacity: Keyword.fetch!(opts, :capacity),
       queue_size: Keyword.fetch!(opts, :queue_size)},
      id: semaphore
    )

    start_supervised!({Readiness, name: readiness, semaphore: semaphore}, id: readiness)

    Process.put({__MODULE__, readiness}, semaphore)

    readiness
  end

  defp semaphore_id(readiness), do: Process.get({__MODULE__, readiness})

  # Puts `count` processes through the semaphore, sequentially so that who
  # holds and who waits is a fact rather than a scheduling hope. Returns the
  # queued ones, oldest first — the holders are not interesting here, only the
  # depth behind them.
  defp fill(readiness, count) do
    semaphore = semaphore_id(readiness)

    for _ <- 1..count, reduce: [] do
      waiters ->
        case start_requester(semaphore) do
          {pid, :queued} -> waiters ++ [pid]
          {_pid, :granted} -> waiters
        end
    end
  end

  defp start_requester(semaphore) do
    test = self()
    pid = spawn(fn -> request(semaphore, test) end)
    on_exit(fn -> Process.exit(pid, :kill) end)

    assert_receive {:requested, ^pid, outcome}, @deadline

    {pid, outcome}
  end

  defp request(semaphore, test) do
    outcome = Semaphore.request(semaphore)
    send(test, {:requested, self(), outcome})

    receive do
      :stop -> :ok
    end
  end

  # Kills a waiter rather than releasing it: a client that gave up is the way
  # a queue actually drains under the load this endpoint reports on, and the
  # `DOWN` is what tells the semaphore.
  #
  # Waits for the depth to have actually moved before returning. The
  # semaphore's `DOWN` and this test's next call reach it from different
  # senders, so nothing orders them — polling the gauge is what makes the
  # `check/1` that follows sample a settled number rather than a race.
  defp drop(readiness, waiter) do
    semaphore = semaphore_id(readiness)
    before = Semaphore.stats(semaphore).queued

    Process.exit(waiter, :kill)

    await(fn -> Semaphore.stats(semaphore).queued < before end)
  end

  defp await(condition, remaining \\ @deadline) do
    cond do
      condition.() -> :ok
      remaining <= 0 -> flunk("queue depth did not settle within #{@deadline}ms")
      true -> Process.sleep(10) && await(condition, remaining - 10)
    end
  end
end
