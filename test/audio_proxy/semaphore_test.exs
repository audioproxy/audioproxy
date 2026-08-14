defmodule AudioProxy.SemaphoreTest do
  @moduledoc """
  Granting, queueing, rejecting, and every way a slot can come back.

  Each test runs its own semaphore with pinned limits — a slot budget is global
  state, and pinning it is what lets these run `async: true` alongside the rest
  of the suite while still saying `capacity: 1` and meaning it.

  The holders are real processes rather than the test process, because that is
  what the module is about: a slot belongs to a pid, and the interesting paths
  are the ones where that pid dies without saying anything.
  """

  use ExUnit.Case, async: true

  import AudioProxy.Eventually

  alias AudioProxy.Semaphore

  @deadline 2_000

  describe "granting" do
    test "grants up to capacity and queues after it" do
      semaphore = start_semaphore(capacity: 2, queue_size: 2)

      assert {_first, :granted} = start_holder(semaphore)
      assert {_second, :granted} = start_holder(semaphore)
      assert {_third, :queued} = start_holder(semaphore)

      assert %{held: 2, queued: 1, capacity: 2, queue_size: 2} = Semaphore.stats(semaphore)
    end

    test "rejects with a Retry-After hint once the queue is full" do
      semaphore = start_semaphore(capacity: 1, queue_size: 1)

      assert {_holder, :granted} = start_holder(semaphore)
      assert {_waiter, :queued} = start_holder(semaphore)

      assert {_rejected, {:error, {:queue_full, retry_after}}} = start_holder(semaphore)
      assert is_integer(retry_after) and retry_after >= 1

      # The rejection left nothing behind: it is not queued, and it is not
      # holding anything.
      assert %{held: 1, queued: 1} = Semaphore.stats(semaphore)
    end

    test "AP_QUEUE_SIZE of zero means no waiting at all" do
      semaphore = start_semaphore(capacity: 1, queue_size: 0)

      assert {_holder, :granted} = start_holder(semaphore)
      assert {_rejected, {:error, {:queue_full, _retry_after}}} = start_holder(semaphore)
    end

    test "a release grants the next waiter, in arrival order" do
      semaphore = start_semaphore(capacity: 1, queue_size: 3)

      {holder, :granted} = start_holder(semaphore)
      # Sequential rather than spawned in a burst: `start_holder/2` waits for
      # each request to be answered before the next one is made, so "arrival
      # order" is a fact about this test rather than a hope about scheduling.
      {first, :queued} = start_holder(semaphore)
      {second, :queued} = start_holder(semaphore)
      {third, :queued} = start_holder(semaphore)

      release(holder)
      assert_receive {:granted, ^first}, @deadline
      refute_received {:granted, ^second}

      release(first)
      assert_receive {:granted, ^second}, @deadline

      release(second)
      assert_receive {:granted, ^third}, @deadline

      release(third)
      assert %{held: 0, queued: 0} = Semaphore.stats(semaphore)
    end

    test "a second request from a process that already holds a slot is refused" do
      semaphore = start_semaphore(capacity: 4, queue_size: 4)

      assert Semaphore.request(semaphore) == :granted
      assert Semaphore.request(semaphore) == {:error, :already_held}

      # And it did not quietly consume a second one.
      assert %{held: 1} = Semaphore.stats(semaphore)
    end
  end

  describe "acquire/1" do
    test "returns once a slot comes free" do
      semaphore = start_semaphore(capacity: 1, queue_size: 1)
      {holder, :granted} = start_holder(semaphore)

      waiter = Task.async(fn -> Semaphore.acquire(server: semaphore) end)

      # Still waiting: the slot is not free yet.
      assert Task.yield(waiter, 100) == nil
      release(holder)

      assert Task.await(waiter, @deadline) == :ok
    end

    test "passes a full queue straight back to the caller" do
      semaphore = start_semaphore(capacity: 1, queue_size: 0)
      {_holder, :granted} = start_holder(semaphore)

      assert {:error, {:queue_full, _retry_after}} = Semaphore.acquire(server: semaphore)
    end

    test "a caller that times out leaks neither a slot nor a stray grant" do
      semaphore = start_semaphore(capacity: 1, queue_size: 4)

      # The race: a grant landing between the timeout firing and the caller
      # doing anything about it. Which side of it a run falls on cannot be
      # dictated from out here — a release racing a 1 ms wait is the closest
      # thing to aiming at the window — so the run is repeated, and what is
      # asserted is what must hold on *either* side of it.
      for _ <- 1..25 do
        {holder, :granted} = start_holder(semaphore)

        task =
          Task.async(fn ->
            result = Semaphore.acquire(server: semaphore, timeout: 1)
            if result == :ok, do: Semaphore.release(semaphore)

            # Nothing the semaphore sent may be left behind: in production this
            # is a connection process, and a stray grant would sit in its
            # mailbox for the life of a keep-alive connection.
            {result, receive_after_zero()}
          end)

        release(holder)

        assert {result, :empty} = Task.await(task, @deadline)
        assert result in [:ok, {:error, :timeout}]
      end

      assert %{held: 0, queued: 0} = Semaphore.stats(semaphore)
    end
  end

  describe "crash safety" do
    test "a holder that dies releases its slot to the next waiter" do
      semaphore = start_semaphore(capacity: 1, queue_size: 2)

      {holder, :granted} = start_holder(semaphore)
      {waiter, :queued} = start_holder(semaphore)

      Process.exit(holder, :kill)

      assert_receive {:granted, ^waiter}, @deadline
      assert %{held: 1, queued: 0} = Semaphore.stats(semaphore)
    end

    test "a waiter that dies is dropped, and never granted a slot" do
      semaphore = start_semaphore(capacity: 1, queue_size: 3)

      {holder, :granted} = start_holder(semaphore)
      {doomed, :queued} = start_holder(semaphore)
      {survivor, :queued} = start_holder(semaphore)

      Process.exit(doomed, :kill)
      # The drop is observable before anything is released, which is the half
      # of this that a "the survivor got it" assertion alone would not prove.
      wait_until(fn -> Semaphore.stats(semaphore).queued == 1 end, @deadline)

      release(holder)

      assert_receive {:granted, ^survivor}, @deadline
      refute Process.alive?(doomed)
    end

    test "waiters that abandon leave nothing behind in the queue" do
      semaphore = start_semaphore(capacity: 1, queue_size: 4)
      {_holder, :granted} = start_holder(semaphore)

      # No grant ever happens here — the one slot is never released — so
      # nothing sweeps the queue on the way past. An implementation that
      # deletes a departing waiter's *bookkeeping* but leaves its place in the
      # ordering behind grows by one entry per abandonment, and `AP_QUEUE_SIZE`
      # stops bounding what the queue costs. Measured at 200/200 before the fix.
      for _ <- 1..50 do
        {waiter, :queued} = start_holder(semaphore)
        Process.exit(waiter, :kill)
        wait_until(fn -> Semaphore.stats(semaphore).queued == 0 end, @deadline)
      end

      assert %{held: 1, queued: 0} = Semaphore.stats(semaphore)
      assert queue_length(semaphore) == 0
    end

    test "releasing twice, or without holding, is :ok" do
      semaphore = start_semaphore(capacity: 1, queue_size: 1)

      assert Semaphore.release(semaphore) == :ok
      assert Semaphore.request(semaphore) == :granted
      assert Semaphore.release(semaphore) == :ok
      assert Semaphore.release(semaphore) == :ok

      assert %{held: 0} = Semaphore.stats(semaphore)
    end

    test "releasing into a semaphore that is gone is :ok" do
      semaphore = start_semaphore(capacity: 1, queue_size: 1)
      assert Semaphore.request(semaphore) == :granted

      stop_supervised!(semaphore)

      # `AudioProxy.RenderCoordinator` releases from `terminate/2`, and at VM
      # shutdown the semaphore may already have stopped. Crashing there would
      # turn an orderly shutdown into a crash report per in-flight render.
      assert Semaphore.release(semaphore) == :ok
    end
  end

  describe "Retry-After" do
    test "grows with the depth of the queue in front of the caller" do
      # Two semaphores rather than two moments of one: the depth at which a
      # caller is rejected *is* the queue size, so comparing depths means
      # comparing configurations.
      empty_queue = start_semaphore(capacity: 1, queue_size: 0)
      {_holder, :granted} = start_holder(empty_queue)
      {_rejected, {:error, {:queue_full, shallow}}} = start_holder(empty_queue)

      full_queue = start_semaphore(capacity: 1, queue_size: 4)
      {_holder, :granted} = start_holder(full_queue)
      for _ <- 1..4, do: {_waiter, :queued} = start_holder(full_queue)
      {_rejected, {:error, {:queue_full, deep}}} = start_holder(full_queue)

      assert deep > shallow
    end

    test "is at least one second before any render has been measured" do
      semaphore = start_semaphore(capacity: 8, queue_size: 0)
      for _ <- 1..8, do: start_holder(semaphore)

      assert {_rejected, {:error, {:queue_full, retry_after}}} = start_holder(semaphore)
      assert retry_after >= 1
    end
  end

  describe "telemetry" do
    test "every outcome fires its event with occupancy and depth" do
      semaphore = start_semaphore(capacity: 1, queue_size: 1)
      attach(semaphore)

      {holder, :granted} = start_holder(semaphore)
      assert_receive {:event, :acquired, %{held: 1, queued: 0, wait: 0}, meta}
      assert meta == %{capacity: 1, queue_size: 1, class: :interactive}

      {waiter, :queued} = start_holder(semaphore)
      assert_receive {:event, :queued, %{held: 1, queued: 1}, _meta}

      {_rejected, {:error, {:queue_full, retry_after}}} = start_holder(semaphore)
      assert_receive {:event, :rejected, %{held: 1, queued: 1, retry_after: ^retry_after}, _meta}

      release(holder)
      assert_receive {:event, :released, %{held: 0, queued: 1, duration: duration}, _meta}
      assert duration > 0

      # The grant that the release triggered, with the queueing time on it.
      assert_receive {:event, :acquired, %{held: 1, queued: 0, wait: wait}, _meta}
      assert wait > 0

      release(waiter)
      assert_receive {:event, :released, %{held: 0, queued: 0}, _meta}
    end

    test "a waiter leaving the queue is its own event, so depth stays live" do
      semaphore = start_semaphore(capacity: 1, queue_size: 2)

      {_holder, :granted} = start_holder(semaphore)
      {waiter, :queued} = start_holder(semaphore)

      attach(semaphore)
      Process.exit(waiter, :kill)

      assert_receive {:event, :abandoned, %{held: 1, queued: 0}, _meta}
    end
  end

  describe "admission classes" do
    test "a release grants the highest class waiting, not the oldest" do
      semaphore = start_semaphore(capacity: 1, queue_size: 4)

      {holder, :granted} = start_holder(semaphore)

      # Queued worst-first, so that arrival order and class order disagree on
      # every pair: a FIFO queue would grant these back in exactly this order.
      {low, :queued} = start_holder(semaphore, class: :low)
      {normal, :queued} = start_holder(semaphore, class: :normal)
      {high, :queued} = start_holder(semaphore, class: :high)
      {interactive, :queued} = start_holder(semaphore, class: :interactive)

      release(holder)
      assert_receive {:granted, ^interactive}, @deadline

      release(interactive)
      assert_receive {:granted, ^high}, @deadline

      release(high)
      assert_receive {:granted, ^normal}, @deadline

      release(normal)
      assert_receive {:granted, ^low}, @deadline
    end

    test "FIFO holds within a class" do
      semaphore = start_semaphore(capacity: 1, queue_size: 3)

      {holder, :granted} = start_holder(semaphore)
      {first, :queued} = start_holder(semaphore, class: :low)
      {second, :queued} = start_holder(semaphore, class: :low)

      release(holder)
      assert_receive {:granted, ^first}, @deadline
      refute_received {:granted, ^second}

      release(first)
      assert_receive {:granted, ^second}, @deadline
    end

    test "an unnamed class is interactive, which nothing outranks" do
      semaphore = start_semaphore(capacity: 1, queue_size: 2)

      {holder, :granted} = start_holder(semaphore)
      {classless, :queued} = start_holder(semaphore)
      {high, :queued} = start_holder(semaphore, class: :high)

      release(holder)

      # The classless caller arrived first *and* is in the top class, so this
      # is what "invisible to callers that say nothing" means at the grant.
      assert_receive {:granted, ^classless}, @deadline
      refute_received {:granted, ^high}
    end

    test "an unknown class is refused before it reaches the server" do
      semaphore = start_semaphore(capacity: 1, queue_size: 1)

      assert_raise ArgumentError, ~r/unknown admission class :urgent/, fn ->
        Semaphore.request(semaphore, class: :urgent)
      end

      assert %{held: 0, queued: 0} = Semaphore.stats(semaphore)
    end

    test "classes/0 is the order the queue enforces" do
      assert Semaphore.classes() == [:interactive, :high, :normal, :low]
    end
  end

  describe "class-aware overflow" do
    test "a higher class displaces the newest waiter of the lowest class" do
      semaphore = start_semaphore(capacity: 1, queue_size: 3)

      {_holder, :granted} = start_holder(semaphore)
      {oldest_low, :queued} = start_holder(semaphore, class: :low)
      {newest_low, :queued} = start_holder(semaphore, class: :low)
      {_normal, :queued} = start_holder(semaphore, class: :normal)

      # Full. The `high` arrival outranks both `low` and `normal`; `low` is the
      # lowest class present, and within it the newest waiter goes.
      assert {_high, :queued} = start_holder(semaphore, class: :high)

      assert_receive {:displaced, ^newest_low, retry_after}, @deadline
      assert is_integer(retry_after) and retry_after >= 1
      refute_received {:displaced, ^oldest_low, _retry_after}

      # One out, one in: the displacement made room rather than growing the
      # queue past its bound.
      assert %{held: 1, queued: 3, queue_size: 3} = Semaphore.stats(semaphore)
    end

    test "an arrival that outranks nothing queued is refused, and displaces nothing" do
      semaphore = start_semaphore(capacity: 1, queue_size: 2)

      {_holder, :granted} = start_holder(semaphore)
      {first, :queued} = start_holder(semaphore, class: :high)
      {second, :queued} = start_holder(semaphore, class: :high)

      assert {_rejected, {:error, {:queue_full, _retry_after}}} =
               start_holder(semaphore, class: :normal)

      refute_received {:displaced, ^first, _retry_after}
      refute_received {:displaced, ^second, _retry_after}
      assert %{held: 1, queued: 2} = Semaphore.stats(semaphore)
    end

    test "a same-class arrival is refused rather than displacing its peers" do
      semaphore = start_semaphore(capacity: 1, queue_size: 2)

      {_holder, :granted} = start_holder(semaphore)
      {first, :queued} = start_holder(semaphore, class: :low)
      {second, :queued} = start_holder(semaphore, class: :low)

      assert {_rejected, {:error, {:queue_full, _retry_after}}} =
               start_holder(semaphore, class: :low)

      refute_received {:displaced, ^first, _retry_after}
      refute_received {:displaced, ^second, _retry_after}
    end

    test "an interactive waiter is never displaced, whatever arrives" do
      semaphore = start_semaphore(capacity: 1, queue_size: 2)

      {_holder, :granted} = start_holder(semaphore)
      {first, :queued} = start_holder(semaphore)
      {second, :queued} = start_holder(semaphore)

      # `interactive` is the top class, so an interactive arrival outranks
      # nothing queued — there is no class above it to arrive from, and this is
      # the closest an arrival can get to displacing a listener. Two things
      # stop it, the ordering and `@evictable`, and this test is what fails
      # when both go.
      assert {_rejected, {:error, {:queue_full, _retry_after}}} = start_holder(semaphore)

      refute_received {:displaced, ^first, _retry_after}
      refute_received {:displaced, ^second, _retry_after}
      assert %{queued: 2} = Semaphore.stats(semaphore)
    end

    test "acquire/1 reports a displacement distinctly from a full queue" do
      semaphore = start_semaphore(capacity: 1, queue_size: 1)
      {_holder, :granted} = start_holder(semaphore)

      waiter = Task.async(fn -> Semaphore.acquire(server: semaphore, class: :low) end)

      wait_until(fn -> Semaphore.stats(semaphore).queued == 1 end, @deadline)
      assert {_high, :queued} = start_holder(semaphore, class: :high)

      assert {:error, {:displaced, retry_after}} = Task.await(waiter, @deadline)
      assert is_integer(retry_after) and retry_after >= 1
    end

    test "a displaced waiter leaves no monitor and no queue entry behind" do
      semaphore = start_semaphore(capacity: 1, queue_size: 1)

      {_holder, :granted} = start_holder(semaphore)
      {displaced, :queued} = start_holder(semaphore, class: :low)
      {_high, :queued} = start_holder(semaphore, class: :high)

      assert_receive {:displaced, ^displaced, _retry_after}, @deadline

      # The waiter's own `DOWN` must not arrive later and be mistaken for an
      # abandonment of a queue place it no longer has.
      refute displaced in monitored(semaphore)
      assert queue_length(semaphore) == 1
      assert %{held: 1, queued: 1} = Semaphore.stats(semaphore)
    end

    test "a displaced waiter that dies afterwards changes nothing" do
      semaphore = start_semaphore(capacity: 1, queue_size: 1)

      {holder, :granted} = start_holder(semaphore)
      {displaced, :queued} = start_holder(semaphore, class: :low)
      {high, :queued} = start_holder(semaphore, class: :high)

      assert_receive {:displaced, ^displaced, _retry_after}, @deadline
      Process.exit(displaced, :kill)

      # The queue is unmoved by the death of something that already left it,
      # and the slot still goes where it was going.
      release(holder)
      assert_receive {:granted, ^high}, @deadline
      assert %{held: 1, queued: 0} = Semaphore.stats(semaphore)
    end
  end

  describe "crash safety across classes" do
    test "a waiter that dies is dropped from its own class queue" do
      semaphore = start_semaphore(capacity: 1, queue_size: 4)

      {holder, :granted} = start_holder(semaphore)
      {doomed, :queued} = start_holder(semaphore, class: :low)
      {survivor, :queued} = start_holder(semaphore, class: :low)
      {top, :queued} = start_holder(semaphore, class: :high)

      Process.exit(doomed, :kill)
      wait_until(fn -> Semaphore.stats(semaphore).queued == 2 end, @deadline)

      # Dropped from the ordering too, not left as a tombstone for the next
      # grant to skip — and dropped from `low` rather than from whichever queue
      # happened to be first.
      assert queue_length(semaphore) == 2

      release(holder)
      assert_receive {:granted, ^top}, @deadline

      release(top)
      assert_receive {:granted, ^survivor}, @deadline
    end

    test "a holder that dies grants by class, not by arrival" do
      semaphore = start_semaphore(capacity: 1, queue_size: 2)

      {holder, :granted} = start_holder(semaphore, class: :low)
      {_low, :queued} = start_holder(semaphore, class: :low)
      {high, :queued} = start_holder(semaphore, class: :high)

      Process.exit(holder, :kill)

      assert_receive {:granted, ^high}, @deadline
      assert %{held: 1, queued: 1} = Semaphore.stats(semaphore)
    end
  end

  describe "class telemetry" do
    test "every event carries the class it is about and the depth of each class" do
      semaphore = start_semaphore(capacity: 1, queue_size: 2)
      attach(semaphore)

      {holder, :granted} = start_holder(semaphore, class: :normal)
      assert_receive {:event, :acquired, measurements, meta}
      assert meta.class == :normal
      assert measurements.queued_interactive == 0

      {_low, :queued} = start_holder(semaphore, class: :low)
      assert_receive {:event, :queued, %{queued: 1, queued_low: 1}, %{class: :low}}

      {_high, :queued} = start_holder(semaphore, class: :high)
      assert_receive {:event, :queued, measurements, %{class: :high}}

      # Two waiters, two classes, reported apart rather than as a depth of 2 —
      # and the starved class keeps reporting while nothing of its own happens.
      assert %{queued: 2, queued_high: 1, queued_low: 1, queued_normal: 0} = measurements

      {_displaced, :queued} = start_holder(semaphore, class: :interactive)
      # The displacement is reported as it happens — the room it made is
      # visible, the arrival that will take it is not yet queued — and the
      # class labelling it is the victim's, not the arrival's.
      assert_receive {:event, :displaced, measurements, %{class: :low}}
      assert %{queued: 1, queued_low: 0, queued_high: 1, queued_interactive: 0} = measurements
      assert measurements.retry_after >= 1

      assert_receive {:event, :queued, %{queued_interactive: 1}, %{class: :interactive}}

      release(holder)
      assert_receive {:event, :released, _measurements, %{class: :normal}}
      assert_receive {:event, :acquired, _measurements, %{class: :interactive}}
    end
  end

  ## Helpers

  defp start_semaphore(opts) do
    name = :"semaphore_#{System.unique_integer([:positive, :monotonic])}"

    start_supervised!({Semaphore, Keyword.put(opts, :name, name)}, id: name)

    name
  end

  # A holder is a process of its own, so that killing it means something. It
  # reports what it was told, reports again if a grant arrives later, and then
  # sits there holding the slot until this test releases it.
  defp start_holder(semaphore, opts \\ []) do
    test = self()
    pid = spawn(fn -> hold(semaphore, test, opts) end)
    on_exit(fn -> Process.exit(pid, :kill) end)

    assert_receive {:requested, ^pid, outcome}, @deadline

    {pid, outcome}
  end

  defp hold(semaphore, test, opts) do
    outcome = Semaphore.request(semaphore, opts)
    send(test, {:requested, self(), outcome})

    if outcome == :queued do
      receive do
        {Semaphore, :granted} ->
          send(test, {:granted, self()})

        # A displaced waiter is no longer waiting for anything, so it says so
        # and stops — the `:release` receive below would otherwise hang a test
        # that never granted it a slot.
        {Semaphore, {:displaced, retry_after}} ->
          send(test, {:displaced, self(), retry_after})
          exit(:normal)
      end
    end

    receive do
      :release ->
        Semaphore.release(semaphore)
        send(test, {:released, self()})
    end
  end

  defp release(holder) do
    send(holder, :release)
    assert_receive {:released, ^holder}, @deadline
  end

  # Handlers are global and this suite is async, so the filter is not a nicety:
  # another test's semaphore emits the same event names. A handler runs in the
  # process that emitted, which for these events is the semaphore itself — so
  # `self()` inside it is the exact identity to match on.
  defp attach(semaphore) do
    test = self()
    server = Process.whereis(semaphore)
    handler = "semaphore-test-#{inspect(server)}"

    events =
      for event <- [:acquired, :queued, :rejected, :released, :abandoned, :displaced],
          do: [:audio_proxy, :semaphore, event]

    :telemetry.attach_many(
      handler,
      events,
      fn [:audio_proxy, :semaphore, event], measurements, meta, _config ->
        if self() == server, do: send(test, {:event, event, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # White-box: `stats/1` reports live waiters, which is exactly the number that
  # stays right when the ordering queue is leaking underneath it. The leak is
  # only visible in the queues themselves — every class, since a leak in one is
  # a leak.
  defp queue_length(semaphore) do
    semaphore
    |> :sys.get_state()
    |> Map.fetch!(:order)
    |> Enum.map(fn {_class, queue} -> :queue.len(queue) end)
    |> Enum.sum()
  end

  # Who the semaphore is still watching. A displaced waiter that stayed
  # monitored would fire a `DOWN` for a queue place it no longer holds, which
  # `stats/1` cannot show and `queue_length/1` only shows once it is too late.
  defp monitored(semaphore) do
    {:monitors, monitors} = semaphore |> Process.whereis() |> Process.info(:monitors)

    for {:process, pid} <- monitors, do: pid
  end

  defp receive_after_zero do
    receive do
      message -> message
    after
      0 -> :empty
    end
  end
end
