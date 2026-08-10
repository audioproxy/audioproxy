defmodule AudioProxy.ProbeLimiterTest do
  @moduledoc """
  The probe ceiling on its own: what it grants, what it refuses, and every way
  a slot comes back.

  A limiter of this test's own throughout — `start_supervised!` with `:name` and
  `:capacity` pinned — so nothing here depends on the application's, and a test
  that leaks a slot cannot make the next one fail.
  """

  # `async: false` for one test's sake: "the limit is read per operation" moves
  # `AP_MAX_PROBE_CONCURRENCY`, which lives in `:persistent_term` and is
  # therefore everyone's.
  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper
  import AudioProxy.Eventually

  alias AudioProxy.ProbeLimiter

  @deadline 5_000

  describe "the ceiling" do
    test "grants up to capacity and then refuses" do
      limiter = start_limiter(2)

      holders = for _ <- 1..2, do: hold(limiter)

      assert ProbeLimiter.stats(limiter) == %{held: 2, capacity: 2}
      assert {:error, {:queue_full, retry_after}} = acquire_from(limiter)
      assert retry_after == ProbeLimiter.retry_after()

      Enum.each(holders, &release_holder/1)
      wait_until(fn -> ProbeLimiter.stats(limiter).held == 0 end)
    end

    test "refuses rather than queues" do
      # The whole difference from `AudioProxy.Semaphore`. A refused caller is
      # told to come back; it is not enqueued, so the freed slot goes to
      # whoever asks next rather than to whoever asked first.
      limiter = start_limiter(1)
      holder = hold(limiter)

      # A refused caller that stays alive, so a queue — if there were one —
      # would still be holding it when the slot frees.
      refused = hold_refused(limiter)

      release_holder(holder)

      # The freed slot was not handed to the refused caller: occupancy is zero,
      # not one. Asserting on a grant *message* would prove nothing, since this
      # module sends no messages at all and never has — the assertion has to be
      # about the slot.
      wait_until(fn -> ProbeLimiter.stats(limiter).held == 0 end)

      # And it is still available to the next asker, which is what "not queued"
      # buys.
      assert :ok = acquire_from(limiter)

      release_holder(refused)
    end

    test "acquiring twice from one process is an accounting error, not a wait" do
      limiter = start_limiter(4)

      assert :ok = ProbeLimiter.acquire(limiter)
      assert {:error, :already_held} = ProbeLimiter.acquire(limiter)
      assert ProbeLimiter.stats(limiter) == %{held: 1, capacity: 4}
    end
  end

  describe "slots come back" do
    test "when released" do
      limiter = start_limiter(1)

      assert :ok = ProbeLimiter.acquire(limiter)
      assert :ok = ProbeLimiter.release(limiter)
      assert ProbeLimiter.stats(limiter).held == 0
    end

    test "when the holder dies without releasing" do
      limiter = start_limiter(1)
      holder = hold(limiter)

      assert ProbeLimiter.stats(limiter).held == 1

      Process.exit(holder.pid, :kill)

      wait_until(fn -> ProbeLimiter.stats(limiter).held == 0 end)
    end

    test "releasing twice, or without holding, is :ok" do
      limiter = start_limiter(1)

      assert :ok = ProbeLimiter.release(limiter)
      assert :ok = ProbeLimiter.acquire(limiter)
      assert :ok = ProbeLimiter.release(limiter)
      assert :ok = ProbeLimiter.release(limiter)
      assert ProbeLimiter.stats(limiter).held == 0
    end

    test "release is :ok even when the limiter is gone" do
      # A coordinator releases from `terminate/2`, which during shutdown can run
      # after the limiter has already stopped.
      limiter = start_limiter(1)
      assert :ok = ProbeLimiter.acquire(limiter)

      stop_supervised!(:probe_limiter)

      assert :ok = ProbeLimiter.release(limiter)
    end
  end

  describe "the limit" do
    test "is read per operation, not pinned at start" do
      # No `:capacity`, so it reads `AP_MAX_PROBE_CONCURRENCY` every time —
      # which is what lets `put_config/1` in a test take effect without
      # restarting a supervised process.
      put_config(%{max_probe_concurrency: 1})
      limiter = start_limiter(nil)

      holder = hold(limiter)
      assert {:error, {:queue_full, _}} = acquire_from(limiter)

      put_config(%{max_probe_concurrency: 2})
      assert {:ok, _} = acquire_from(limiter) |> wrap()

      release_holder(holder)
    end
  end

  describe "telemetry" do
    test "acquired, rejected and released all carry the occupancy after the event" do
      limiter = start_limiter(1)
      attach([:acquired, :rejected, :released])

      holder = hold(limiter)
      assert_receive {:event, :acquired, %{held: 1}, %{capacity: 1}}, @deadline

      assert {:error, {:queue_full, _}} = acquire_from(limiter)
      assert_receive {:event, :rejected, %{held: 1, retry_after: 1}, %{capacity: 1}}, @deadline

      release_holder(holder)
      assert_receive {:event, :released, %{held: 0, duration: duration}, _}, @deadline
      assert duration >= 0
    end
  end

  ## Helpers

  defp start_limiter(capacity) do
    name = :"probe_limiter_#{System.unique_integer([:positive])}"
    opts = [name: name] ++ if(capacity, do: [capacity: capacity], else: [])

    start_supervised!(%{id: :probe_limiter, start: {ProbeLimiter, :start_link, [opts]}})

    name
  end

  # A slot held by a process of its own, so the test process can go on asking
  # the limiter things while it is held.
  defp hold(limiter) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:held, self(), ProbeLimiter.acquire(limiter)})

        receive do
          :release ->
            ProbeLimiter.release(limiter)
            send(test, {:released, self()})
        end
      end)

    assert_receive {:held, ^pid, :ok}, @deadline

    %{pid: pid, limiter: limiter}
  end

  # A process that asked, was refused, and stays alive. If this module ever
  # grew a queue, this is the caller that would be sitting in it when a slot
  # frees — which is what makes the occupancy assertion above meaningful rather
  # than a statement about an idle limiter.
  defp hold_refused(limiter) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:refused, self(), ProbeLimiter.acquire(limiter)})

        receive do
          :release -> send(test, {:released, self()})
        end
      end)

    assert_receive {:refused, ^pid, {:error, {:queue_full, _}}}, @deadline

    %{pid: pid, limiter: limiter}
  end

  defp release_holder(%{pid: pid}) do
    send(pid, :release)
    assert_receive {:released, ^pid}, @deadline
  end

  # An acquire from a process that is not this one, so the `:already_held`
  # clause is never what is being measured.
  defp acquire_from(limiter) do
    Task.await(Task.async(fn -> ProbeLimiter.acquire(limiter) end), @deadline)
  end

  defp wrap(:ok), do: {:ok, :granted}
  defp wrap(other), do: other

  defp attach(events) do
    test = self()
    id = "probe-limiter-test-#{inspect(self())}"

    :telemetry.attach_many(
      id,
      Enum.map(events, &[:audio_proxy, :probe_limiter, &1]),
      fn event, measurements, metadata, _config ->
        send(test, {:event, List.last(event), measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end
end
