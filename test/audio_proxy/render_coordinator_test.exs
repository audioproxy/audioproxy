defmodule AudioProxy.RenderCoordinatorTest do
  @moduledoc """
  Single-flight, catch-up and teardown, driven against `fake_cmd.sh`.

  Everything here is a property of the coordinator rather than of ffmpeg: how
  many renders a burst starts, what a subscriber that joins late is handed, and
  what happens to the subprocess when the last one leaves. The stand-in
  subprocess is what makes the timing controllable — `emit`/`sleep` pairs
  produce chunks on a schedule, which is the only way to have "joined after two
  chunks" mean something.

  `async: false`, because the registry and the config are global.
  """

  use ExUnit.Case, async: false

  import AudioProxy.CoalesceHelper
  import AudioProxy.ProbeCoalesceHelper
  import AudioProxy.ConfigHelper
  import AudioProxy.Eventually

  alias AudioProxy.RenderCoordinator
  alias AudioProxy.RenderHarness

  # Three chunks with gaps, so a test can join "after N chunks" by waiting.
  @paced ["emit", "63", "sleep", "0.2", "emit", "63", "sleep", "0.2", "emit", "63"]
  @paced_bytes RenderHarness.pattern(189)

  @deadline 5_000

  setup do
    put_config(%{max_src_bytes: 2_000_000_000, max_variant_bytes: 2_000_000_000})
    reset_coordinators()
    reset_probes()
    :ok
  end

  describe "single flight" do
    test "a concurrent burst on one key starts exactly one render" do
      key = unique_key()

      results =
        1..20
        |> Task.async_stream(fn _ -> subscribe_and_collect(key, @paced) end,
          max_concurrency: 20,
          timeout: @deadline
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert length(results) == 20

      # One starter, nineteen joiners — the property, stated as the count.
      assert Enum.count(results, &(&1.status == :miss)) == 1
      assert Enum.count(results, &(&1.status == :coalesced)) == 19

      assert [_only_one] = Enum.uniq(Enum.map(results, & &1.render))

      for result <- results do
        assert result.outcome == :ok
        assert result.bytes == @paced_bytes
      end
    end

    test "a burst starts exactly one subprocess, counted while it is running" do
      key = unique_key()
      test = self()

      # A render that is still going when the count is taken — the burst test
      # above can only assert on statuses and pids, because by the time its
      # tasks return there is nothing left to count. This is the property
      # stated as a number: one subprocess for twenty subscribers.
      subscribers =
        for _ <- 1..20, do: spawn(fn -> subscribe_and_wait(key, ["sleep", "30"], test) end)

      # They sleep forever by design, so nothing else will ever end them.
      on_exit(fn -> Enum.each(subscribers, &Process.exit(&1, :kill)) end)

      renders =
        for _ <- 1..20 do
          assert_receive {:subscribed, render}, @deadline
          render
        end

      assert [coordinator] = Enum.uniq(renders)
      assert length(renders_for(coordinator)) == 1
    end

    test "distinct keys render independently" do
      one = Task.async(fn -> subscribe_and_collect(unique_key(), @paced) end)
      other = Task.async(fn -> subscribe_and_collect(unique_key(), @paced) end)

      one = Task.await(one, @deadline)
      other = Task.await(other, @deadline)

      assert one.status == :miss
      assert other.status == :miss
      refute one.render == other.render

      assert one.bytes == @paced_bytes
      assert other.bytes == @paced_bytes
    end
  end

  describe "late joiners" do
    test "joining before any chunk exists is the whole stream, live" do
      key = unique_key()
      first = Task.async(fn -> subscribe_and_collect(key, @paced) end)

      # No wait: the render has barely started, so the backlog is empty and
      # everything arrives as a live chunk.
      second = Task.async(fn -> subscribe_and_collect(key, @paced) end)

      assert Task.await(first, @deadline).bytes == @paced_bytes
      assert Task.await(second, @deadline).bytes == @paced_bytes
    end

    test "joining mid-render is backlog then live chunks, with no seam" do
      key = unique_key()
      test = self()
      first = Task.async(fn -> subscribe_and_collect(key, @paced, announce_to: test) end)

      # Joined on the render's own progress, not on a clock: the first chunk
      # having been delivered is exactly the precondition this test needs, and
      # a `sleep` long enough to imply it on a fast machine is not long enough
      # on a loaded CI runner — where the backlog would come back empty and the
      # assertion below would fail for a reason that is not a bug.
      assert_receive {:first_chunk, _render}, @deadline

      second = Task.async(fn -> subscribe_and_collect(key, @paced) end)

      first = Task.await(first, @deadline)
      second = Task.await(second, @deadline)

      assert second.status == :coalesced
      refute second.backlog == []

      # Byte equality is the seam test: a dropped chunk shortens it, a repeated
      # one lengthens it, and `fake_cmd.sh`'s 63-byte period means a reordering
      # changes it too.
      assert second.bytes == first.bytes
      assert second.bytes == @paced_bytes
    end

    test "joining after the render finished is the finished bytes, from the linger" do
      key = unique_key()

      first = subscribe_and_collect(key, @paced)
      second = subscribe_and_collect(key, @paced)

      assert second.status == :coalesced
      # Nothing was live to receive: the whole stream came out of the backlog,
      # with `{:done, _, _}` right behind it.
      assert IO.iodata_to_binary(second.backlog) == @paced_bytes
      assert second.bytes == first.bytes
      assert second.outcome == :ok
    end
  end

  describe "subscriber lifecycle" do
    test "one subscriber dying leaves the render running for the others" do
      key = unique_key()
      test = self()

      survivors =
        for _ <- 1..2, do: Task.async(fn -> subscribe_and_collect(key, @paced) end)

      doomed = spawn(fn -> subscribe_and_wait(key, @paced, test) end)

      # Attached, on its own say-so rather than after a sleep.
      assert_receive {:subscribed, render}, @deadline
      assert doomed in subscribers(render)

      Process.exit(doomed, :kill)

      for survivor <- survivors do
        assert Task.await(survivor, @deadline).bytes == @paced_bytes
      end

      # Both halves, because only asserting the survivors finish would pass
      # against a coordinator that never removed a dead subscriber at all —
      # and that coordinator would then never reach "last subscriber gone" and
      # would leak the render.
      refute doomed in subscribers(render)
    end

    test "the last subscriber leaving cancels the render and kills the subprocess" do
      key = unique_key()
      # Long enough that it cannot plausibly have finished on its own.
      {:ok, :miss, render, []} = RenderCoordinator.subscribe(key, spec(["sleep", "30"]))

      os_pid = subprocess_pid(render)
      coordinator = Process.monitor(render)

      # Returns only once the subprocess is gone, the way `Render.cancel/1`
      # does — so this is an assertion about state, not a request to reach it.
      assert :ok = RenderCoordinator.unsubscribe(render)

      refute alive?(os_pid), "the render outlived the last subscriber that wanted it"
      assert_receive {:DOWN, ^coordinator, :process, ^render, _reason}, @deadline
    end

    test "the last subscriber dying does the same, without being asked" do
      key = unique_key()
      parent = self()

      subscriber =
        spawn(fn ->
          {:ok, :miss, render, []} = RenderCoordinator.subscribe(key, spec(["sleep", "30"]))
          send(parent, {:render, render})
          Process.sleep(:infinity)
        end)

      assert_receive {:render, render}, @deadline
      os_pid = subprocess_pid(render)
      coordinator = Process.monitor(render)

      Process.exit(subscriber, :kill)

      assert_receive {:DOWN, ^coordinator, :process, ^render, _reason}, @deadline
      assert gone_within?(os_pid, @deadline)
    end
  end

  describe "losing the race to a coordinator that is going away" do
    test "a join that finds the winner already gone retries into a fresh render" do
      key = unique_key()

      # Occupy the key with something that will refuse the join and vanish —
      # which is what a coordinator does between failing (it unregisters) and
      # actually stopping. Reproducing it with a real coordinator would mean
      # racing that window; this makes it the only outcome.
      placeholder =
        spawn(fn ->
          {:ok, _} = Registry.register(AudioProxy.RenderCoordinator.Registry, key, nil)

          receive do
            _join_call ->
              # Unregister before dying: the Registry cleans up after a dead
              # owner asynchronously, and the retry must find the key free.
              Registry.unregister(AudioProxy.RenderCoordinator.Registry, key)
              exit(:gone)
          end
        end)

      wait_until(fn -> Registry.lookup(AudioProxy.RenderCoordinator.Registry, key) != [] end)

      result = subscribe_and_collect(key, @paced)

      refute Process.alive?(placeholder)
      assert result.status == :miss
      assert result.bytes == @paced_bytes
    end

    test "leaving a coordinator that has already stopped is :ok, not an exit" do
      key = unique_key()
      {:ok, :miss, render, []} = RenderCoordinator.subscribe(key, spec(["exit", "0"]))

      monitor = Process.monitor(render)
      assert_receive {:DOWN, ^monitor, :process, ^render, _reason}, @deadline

      # The caller is a request that has just finished with a render; that the
      # render tidied itself away first must not turn its cleanup into a crash.
      assert :ok = RenderCoordinator.unsubscribe(render)
    end
  end

  describe "failure" do
    test "a mid-render failure reaches every subscriber, once" do
      key = unique_key()
      failing = ["emit", "63", "sleep", "0.3", "stderr", "boom", "exit", "3"]

      results =
        1..3
        |> Task.async_stream(fn _ -> subscribe_and_collect(key, failing) end,
          max_concurrency: 3,
          timeout: @deadline
        )
        |> Enum.map(fn {:ok, result} -> result end)

      for result <- results do
        assert {:error, %{class: :render_failed, exit_status: 3}} = result.outcome
        # Delivered exactly once: a second terminal message would have been
        # collected as a duplicate and shown up here.
        assert result.terminal_messages == 1
      end
    end

    test "a failed key is retryable, not poisoned" do
      key = unique_key()

      failed = subscribe_and_collect(key, ["exit", "1"])
      assert {:error, _failure} = failed.outcome

      # The key was unregistered on failure rather than lingering, so this is a
      # fresh render and not an attachment to the corpse.
      retried = subscribe_and_collect(key, @paced)

      assert retried.status == :miss
      refute retried.render == failed.render
      assert retried.bytes == @paced_bytes
    end

    test "output past the retention cap fails the render" do
      # Well under what `emit` below produces, so the cap is what stops it.
      put_config(%{max_variant_bytes: 100})

      key = unique_key()
      result = subscribe_and_collect(key, ["emit", "4096"])

      assert {:error, %{class: :render_failed, detail: detail}} = result.outcome
      assert detail =~ "AP_MAX_VARIANT_BYTES"
      assert detail =~ "100-byte"

      # Failed cleanly: no subprocess left behind, and the key is free again.
      assert %{status: :miss} = subscribe_and_collect(key, ["emit", "10"])
    end

    test "the cap is a ceiling, not a fence: output of exactly it survives" do
      # The threshold, stated on both sides. `@paced` produces exactly
      # `@paced_bytes`, so a cap of that size is the last value that passes and
      # one byte less is the first that does not — which is what makes "the
      # same threshold as before the split" a checkable claim rather than a
      # hope about a 2 GB number nothing in this suite can reach.
      put_config(%{max_variant_bytes: byte_size(@paced_bytes)})
      assert subscribe_and_collect(unique_key(), @paced).outcome == :ok

      put_config(%{max_variant_bytes: byte_size(@paced_bytes) - 1})

      assert {:error, %{class: :render_failed}} =
               subscribe_and_collect(unique_key(), @paced).outcome
    end

    test "the source ceiling no longer bounds retention" do
      # The point of the split. A source ceiling far below the output is now
      # simply irrelevant here — it is spent in `Plugs.RenderAction`, against
      # the source, before this coordinator exists.
      put_config(%{max_src_bytes: 10, max_variant_bytes: 2_000_000_000})

      assert subscribe_and_collect(unique_key(), @paced).outcome == :ok
    end

    test "a breach fails every attached subscriber and releases the key" do
      put_config(%{max_variant_bytes: 100})

      key = unique_key()

      results =
        1..5
        |> Task.async_stream(fn _ -> subscribe_and_collect(key, ["emit", "4096"]) end,
          max_concurrency: 5,
          timeout: @deadline
        )
        |> Enum.map(fn {:ok, result} -> result end)

      # One render, five subscribers, five failures: nobody is left holding a
      # truncated stream that never terminates.
      assert [_one_render] = Enum.uniq(Enum.map(results, & &1.render))

      for result <- results do
        assert {:error, %{class: :render_failed, detail: detail}} = result.outcome
        assert detail =~ "AP_MAX_VARIANT_BYTES"
        assert result.terminal_messages == 1
      end

      # And the key went with the render, so the next request renders afresh
      # rather than joining a corpse.
      put_config(%{max_variant_bytes: 2_000_000_000})
      assert %{status: :miss, outcome: :ok} = subscribe_and_collect(key, ["emit", "10"])
    end
  end

  ## Helpers

  defp unique_key, do: "key-#{System.unique_integer([:positive, :monotonic])}"

  defp spec(directives), do: [args: directives, executable: RenderHarness.fake_cmd()]

  # Subscribes, drains to the terminal message, and reports what this
  # subscriber saw: its status, the coordinator it attached to, the catch-up it
  # was handed, and the concatenation of everything — which is the thing all
  # the equality assertions above are about.
  #
  # `:announce_to` gets `{:subscribed, render}` the moment this subscriber is
  # attached, and `{:first_chunk, render}` when its first live chunk lands.
  # Those are what let a test join "after the render is under way" without
  # guessing at a clock.
  defp subscribe_and_collect(key, directives, opts \\ []) do
    {:ok, status, render, backlog} = RenderCoordinator.subscribe(key, spec(directives))

    announce(opts, {:subscribed, render})

    collect(render, %{
      status: status,
      render: render,
      backlog: backlog,
      chunks: Enum.reverse(backlog),
      terminal_messages: 0,
      outcome: nil,
      bytes: nil,
      announce_to: Keyword.get(opts, :announce_to)
    })
  end

  defp announce(opts, message) do
    with pid when is_pid(pid) <- Keyword.get(opts, :announce_to), do: send(pid, message)
  end

  # Subscribes and then does nothing at all — a subscriber whose only job is to
  # exist until something kills it.
  defp subscribe_and_wait(key, directives, announce_to) do
    {:ok, _status, render, _backlog} = RenderCoordinator.subscribe(key, spec(directives))

    send(announce_to, {:subscribed, render})

    Process.sleep(:infinity)
  end

  defp collect(render, acc) do
    receive do
      {:chunk, ^render, data} ->
        if acc.announce_to, do: send(acc.announce_to, {:first_chunk, render})
        collect(render, %{acc | chunks: [data | acc.chunks], announce_to: nil})

      {:done, ^render, _info} ->
        # Kept receiving for a moment after the terminal message, so a second
        # one — the failure tests' "exactly once" — would be counted rather
        # than left unread in the mailbox.
        drain(render, %{acc | outcome: :ok, terminal_messages: acc.terminal_messages + 1})

      {:error, ^render, failure} ->
        drain(render, %{
          acc
          | outcome: {:error, failure},
            terminal_messages: acc.terminal_messages + 1
        })
    after
      @deadline -> %{acc | outcome: :timeout, bytes: joined(acc)}
    end
  end

  defp drain(render, acc) do
    receive do
      {:chunk, ^render, data} ->
        drain(render, %{acc | chunks: [data | acc.chunks]})

      {:done, ^render, _info} ->
        drain(render, %{acc | terminal_messages: acc.terminal_messages + 1})

      {:error, ^render, _failure} ->
        drain(render, %{acc | terminal_messages: acc.terminal_messages + 1})
    after
      50 -> %{acc | bytes: joined(acc)}
    end
  end

  defp joined(acc), do: acc.chunks |> Enum.reverse() |> IO.iodata_to_binary()

  ## Coordinator and subprocess probing

  # White-box, deliberately. The subscriber set has no public accessor and
  # wants none — but "the dead one was removed" is not observable from the
  # outside without waiting for a consequence, and a test that waits for a
  # consequence cannot tell "removed" from "not yet removed".
  defp subscribers(coordinator) do
    coordinator |> :sys.get_state() |> Map.fetch!(:subscribers) |> Map.keys()
  end

  # Every render the supervisor is holding for this coordinator. The count is
  # the single-flight property stated directly: one coordinator spawning two
  # subprocesses, or two coordinators for one key, both show up here as a
  # number other than 1.
  defp renders_for(coordinator) do
    AudioProxy.Ffmpeg.RenderSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
    |> Enum.filter(&(consumer(&1) == coordinator))
  end

  defp subprocess_pid(coordinator) do
    assert [render] = renders_for(coordinator)

    AudioProxy.Ffmpeg.Render.os_pid(render)
  end

  defp consumer(render) do
    render |> :sys.get_state() |> Map.get(:consumer)
  end
end
