defmodule AudioProxy.ProbeLimiterPropertyTest do
  @moduledoc """
  The probe ceiling, under three times its worth of callers racing.

  `AudioProxy.ProbeLimiterTest` pins each path on its own: a grant, a refusal, a
  release, a holder that dies. What it cannot show is those paths interleaving,
  which is where an accounting slip would actually live — and the shape this
  module borrows from `AudioProxy.SemaphorePropertyTest` is exactly that, minus
  the queue this limiter deliberately does not have.

  Two things are asserted: occupancy never exceeds capacity while it runs, and
  nothing at all is held once it stops. The second is the one that catches a
  leak, since a leaked slot is invisible until whatever should have released it
  is gone.

  The refusals are part of the property rather than noise around it. With three
  times capacity racing, most callers *are* refused, and the module's contract
  is that a refused caller took nothing — a limiter that leaked a slot on the
  rejection path would show up here as an occupancy that only ever climbs.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AudioProxy.ProbeLimiter

  @capacity 4
  @callers @capacity * 3
  @deadline 10_000

  property "occupancy stays within capacity, and every slot is given back" do
    check all(exits <- list_of(exit_style(), length: @callers), max_runs: 12) do
      limiter = start_limiter()

      # `spawn_monitor` rather than `Task.async`, because one of the exit styles
      # is an abnormal exit — a linked task would take this test process down
      # with it, which is the opposite of the point.
      workers = for style <- exits, do: spawn_monitor(fn -> work(limiter, style) end)

      sampler = Task.async(fn -> sample(limiter, Enum.map(workers, &elem(&1, 0))) end)

      for {pid, monitor} <- workers do
        assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, @deadline
      end

      # The high-water mark is what stops the verdict from being vacuous: a
      # sampler that only ever looked at an idle limiter would report
      # `:within_capacity` for a module with no ceiling at all.
      assert {:within_capacity, high_water} = Task.await(sampler, @deadline)
      assert high_water >= 1

      wait_until(fn -> ProbeLimiter.stats(limiter).held == 0 end)
    end
  end

  # Three ways a caller stops mattering: it says so, it dies holding, or it was
  # refused and never held anything.
  defp exit_style, do: member_of([:release, :crash, :refused_or_released])

  defp work(limiter, :release) do
    case ProbeLimiter.acquire(limiter) do
      :ok -> ProbeLimiter.release(limiter)
      {:error, _reason} -> :ok
    end
  end

  defp work(limiter, :crash) do
    case ProbeLimiter.acquire(limiter) do
      # Exits holding the slot, so only the monitor can recover it.
      :ok -> exit(:boom)
      {:error, _reason} -> :ok
    end
  end

  defp work(limiter, :refused_or_released) do
    # Holds briefly before releasing, so the window in which others are refused
    # is a real one rather than a scheduling accident.
    case ProbeLimiter.acquire(limiter) do
      :ok ->
        Process.sleep(5)
        ProbeLimiter.release(limiter)

      {:error, {:queue_full, retry_after}} ->
        # A refusal is a refusal, not a deferred grant.
        assert retry_after >= 1
    end
  end

  # Samples until every worker is gone, then reports the verdict and the
  # high-water mark it saw.
  defp sample(limiter, pids, high_water \\ 0) do
    held = ProbeLimiter.stats(limiter).held

    cond do
      held > @capacity -> {:over_capacity, held}
      Enum.any?(pids, &Process.alive?/1) -> sample(limiter, pids, max(high_water, held))
      true -> {:within_capacity, max(high_water, held)}
    end
  end

  defp start_limiter do
    name = :"probe_limiter_property_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: name,
      start: {ProbeLimiter, :start_link, [[name: name, capacity: @capacity]]}
    })

    name
  end

  defp wait_until(condition, remaining \\ @deadline)

  defp wait_until(_condition, remaining) when remaining <= 0, do: flunk("condition never held")

  defp wait_until(condition, remaining) do
    unless condition.() do
      Process.sleep(10)
      wait_until(condition, remaining - 10)
    end
  end
end
