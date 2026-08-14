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
  use ExUnitProperties

  import AudioProxy.Eventually

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

  @model_capacity 2
  @model_queue_size 3

  property "classless traffic is indistinguishable from plain FIFO" do
    # Admission classes are only invisible if nothing about a classless
    # workload changed, and "nothing changed" is a claim about *every*
    # interleaving of arrivals and releases rather than about the handful this
    # suite writes out. So the FIFO the semaphore had before classes existed is
    # written here as a model — a list, a queue, and no notion of a class — and
    # a generated script is run against both.
    #
    # The script is executed one operation at a time, each fully answered
    # before the next is issued, which is what makes a deterministic model the
    # right oracle: the concurrency this module has to survive is the other
    # property's subject, and mixing the two would make disagreement mean
    # either.
    check all(script <- list_of(operation(), min_length: 1, max_length: 40), max_runs: 25) do
      semaphore =
        start_semaphore(capacity: @model_capacity, queue_size: @model_queue_size)

      Enum.reduce(script, {new_model(), %{}}, fn operation, {model, pids} ->
        step(semaphore, operation, model, pids)
      end)
    end
  end

  defp operation, do: one_of([constant(:request), tuple({constant(:release), integer(0..9)})])

  defp step(semaphore, :request, model, pids) do
    id = map_size(pids)
    {expected, model} = model_request(model, id)

    {pid, outcome} = start_holder(semaphore)

    case {expected, outcome} do
      {:granted, :granted} -> :ok
      {:queued, :queued} -> :ok
      {:queue_full, {:error, {:queue_full, _retry_after}}} -> :ok
      {expected, actual} -> flunk("model said #{inspect(expected)}, semaphore said #{inspect(actual)}")
    end

    # A rejected caller is not part of the run's identity space — the model
    # forgot it too — so it is not recorded, and its id is reused by the next
    # arrival. Nothing downstream can address it.
    if expected == :queue_full, do: {model, pids}, else: {model, Map.put(pids, id, pid)}
  end

  defp step(_semaphore, {:release, nth}, model, pids) do
    case model_release(model, nth) do
      :none ->
        {model, pids}

      {released, granted, model} ->
        release(pids[released])

        case granted do
          nil ->
            refute_receive {:granted, _pid}, 50

          id ->
            pid = pids[id]
            assert_receive {:granted, ^pid}, @deadline
        end

        {model, pids}
    end
  end

  ## The model: the semaphore as it was before classes, in three lines of state

  defp new_model, do: %{held: [], queue: []}

  defp model_request(model, id) do
    cond do
      length(model.held) < @model_capacity -> {:granted, %{model | held: model.held ++ [id]}}
      length(model.queue) < @model_queue_size -> {:queued, %{model | queue: model.queue ++ [id]}}
      true -> {:queue_full, model}
    end
  end

  # `nth` indexes the holders rather than naming one, so a shrunk script stays
  # meaningful: the generator cannot know which ids are held by the time this
  # operation runs.
  defp model_release(%{held: []}, _nth), do: :none

  defp model_release(model, nth) do
    released = Enum.at(model.held, rem(nth, length(model.held)))
    held = List.delete(model.held, released)

    case model.queue do
      [] -> {released, nil, %{model | held: held}}
      [next | rest] -> {released, next, %{model | held: held ++ [next], queue: rest}}
    end
  end

  # A holder for the model comparison: the same shape as the one in
  # `AudioProxy.SemaphoreTest`, and classless on purpose — that is the whole
  # subject.
  defp start_holder(semaphore) do
    test = self()

    pid =
      spawn(fn ->
        outcome = Semaphore.request(semaphore)
        send(test, {:requested, self(), outcome})

        if outcome == :queued do
          receive do
            {Semaphore, :granted} -> send(test, {:granted, self()})
          end
        end

        receive do
          :release ->
            Semaphore.release(semaphore)
            send(test, {:released, self()})
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)

    assert_receive {:requested, ^pid, outcome}, @deadline

    {pid, outcome}
  end

  defp release(holder) do
    send(holder, :release)
    assert_receive {:released, ^holder}, @deadline
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

  defp start_semaphore(opts \\ [capacity: @capacity, queue_size: 64]) do
    name = :"semaphore_property_#{System.unique_integer([:positive, :monotonic])}"

    start_supervised!({Semaphore, Keyword.put(opts, :name, name)}, id: name)

    name
  end

  defp empty, do: %{held: 0, queued: 0, capacity: @capacity, queue_size: 64}
end
