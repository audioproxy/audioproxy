defmodule AudioProxy.SemaphorePropertyTest do
  @moduledoc """
  The cap, under a crowd that leaves by every exit there is.

  `AudioProxy.SemaphoreTest` pins each path on its own: a release, a kill, a
  caller that gave up. What it cannot show is those paths interleaving — a
  holder crashing while a waiter times out while a release is granting the next
  one is where an accounting slip would actually live, and no hand-written
  ordering is the one that finds it.

  So the *mix* of exits is generated, many more processes than slots are pointed
  at the semaphore at once, and two things are asserted: occupancy never exceeds
  capacity while it runs, and nothing at all is held or queued once it stops.
  The second is the one that catches a leak, since a leaked slot is invisible
  until the thing that should have released it is gone.
  """

  use ExUnit.Case, async: true

  import AudioProxy.Eventually
  use ExUnitProperties

  alias AudioProxy.Semaphore

  @capacity 3
  @deadline 10_000

  property "occupancy stays within capacity, and everything is given back" do
    check all(exits <- list_of(exit_style(), length: 24), max_runs: 12) do
      semaphore = start_semaphore()

      # Deep enough that nobody is rejected: this property is about slots being
      # accounted for, and a rejected caller never takes one.
      #
      # `spawn_monitor` rather than `Task.async`, because one of the three exit
      # styles is an abnormal exit — a linked task would take this test process
      # down with it, which is the opposite of the point.
      workers =
        for {style, index} <- Enum.with_index(exits) do
          spawn_monitor(fn -> work(semaphore, style, index) end)
        end

      pids = Enum.map(workers, &elem(&1, 0))
      sampler = Task.async(fn -> sample(semaphore, pids) end)

      for {pid, monitor} <- workers do
        assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, @deadline
      end

      # The high-water mark is what stops the verdict from being vacuous: a
      # sampler that only ever looked at an idle semaphore would report
      # `:within_capacity` for a module that has no cap at all.
      assert {:within_capacity, high_water} = Task.await(sampler, @deadline)
      assert high_water >= 1

      # Every worker has returned, so every slot has been released, crashed out
      # of, or timed out of — and the monitors that cover the last two have
      # fired, because the pids are gone.
      wait_until(fn -> Semaphore.stats(semaphore) == empty() end, @deadline)
    end
  end

  # Three ways a holder stops mattering, which are the three the module has to
  # survive: it says so, it dies, or it never waited long enough to be granted.
  defp exit_style, do: member_of([:release, :crash, :give_up])

  defp work(semaphore, :give_up, _index) do
    # A wait short enough to expire under contention but not always — so some
    # of these are the caller-timeout race and some are ordinary grants.
    case Semaphore.acquire(server: semaphore, timeout: 1) do
      :ok -> Semaphore.release(semaphore)
      {:error, :timeout} -> :ok
    end
  end

  defp work(semaphore, style, index) do
    :ok = Semaphore.acquire(server: semaphore)

    # Uneven holds, so releases do not arrive in the order the slots were
    # granted; `index` rather than a random number, because scripts have to be
    # replayable for a shrunk counterexample to mean anything.
    Process.sleep(rem(index, 4))

    case style do
      :release -> Semaphore.release(semaphore)
      # No release, no farewell: the monitor is the only thing that can recover
      # this slot.
      :crash -> exit(:killed_mid_render)
    end
  end

  # Polls until every worker is done. Occupancy above capacity at any sample is
  # the failure this exists for; the return value carries the verdict so a
  # failing sample cannot be swallowed by the task exiting quietly.
  defp sample(semaphore, pids, high_water \\ 0) do
    stats = Semaphore.stats(semaphore)
    high_water = max(high_water, stats.held)

    cond do
      stats.held > @capacity -> {:over_capacity, stats}
      Enum.any?(pids, &Process.alive?/1) -> sample(semaphore, pids, high_water)
      true -> {:within_capacity, high_water}
    end
  end

  defp start_semaphore do
    name = :"semaphore_property_#{System.unique_integer([:positive, :monotonic])}"

    start_supervised!({Semaphore, name: name, capacity: @capacity, queue_size: 64}, id: name)

    name
  end

  defp empty, do: %{held: 0, queued: 0, capacity: @capacity, queue_size: 64}
end
