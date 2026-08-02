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
  import AudioProxy.ConfigHelper

  alias AudioProxy.RenderCoordinator
  alias AudioProxy.RenderHarness

  # Three chunks with gaps, so a test can join "after N chunks" by waiting.
  @paced ["emit", "63", "sleep", "0.2", "emit", "63", "sleep", "0.2", "emit", "63"]
  @paced_bytes RenderHarness.pattern(189)

  @deadline 5_000

  setup do
    put_config(%{max_src_bytes: 2_000_000_000})
    reset_coordinators()
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

      # And one render, which is what the count of coordinators means: each
      # spawns exactly one subprocess in `init/1`.
      assert [_only_one] = Enum.uniq(Enum.map(results, & &1.render))

      for result <- results do
        assert result.outcome == :ok
        assert result.bytes == @paced_bytes
      end
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
      first = Task.async(fn -> subscribe_and_collect(key, @paced) end)

      # Past the first emit and inside the first sleep, so there is something
      # to catch up on and something still to come.
      Process.sleep(150)
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

      survivors =
        for _ <- 1..2, do: Task.async(fn -> subscribe_and_collect(key, @paced) end)

      doomed = spawn(fn -> subscribe_and_wait(key, @paced) end)
      Process.sleep(150)
      Process.exit(doomed, :kill)

      for survivor <- survivors do
        assert Task.await(survivor, @deadline).bytes == @paced_bytes
      end
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

    test "output past the retention cap fails the render for everyone" do
      # Well under what `emit` below produces, so the cap is what stops it.
      put_config(%{max_src_bytes: 100})

      key = unique_key()
      result = subscribe_and_collect(key, ["emit", "4096"])

      assert {:error, %{class: :render_failed, detail: detail}} = result.outcome
      assert detail =~ "AP_MAX_SRC_BYTES"

      # Failed cleanly: no subprocess left behind, and the key is free again.
      assert %{status: :miss} = subscribe_and_collect(key, ["emit", "10"])
    end
  end

  ## Helpers

  defp unique_key, do: "key-#{System.unique_integer([:positive, :monotonic])}"

  defp spec(directives), do: [args: directives, executable: RenderHarness.fake_cmd()]

  # Subscribes, drains to the terminal message, and reports what this
  # subscriber saw: its status, the coordinator it attached to, the catch-up it
  # was handed, and the concatenation of everything — which is the thing all
  # the equality assertions above are about.
  defp subscribe_and_collect(key, directives) do
    {:ok, status, render, backlog} = RenderCoordinator.subscribe(key, spec(directives))

    collect(render, %{
      status: status,
      render: render,
      backlog: backlog,
      chunks: Enum.reverse(backlog),
      terminal_messages: 0,
      outcome: nil,
      bytes: nil
    })
  end

  # Subscribes and then does nothing at all — a subscriber whose only job is to
  # exist until something kills it.
  defp subscribe_and_wait(key, directives) do
    {:ok, _status, _render, _backlog} = RenderCoordinator.subscribe(key, spec(directives))
    Process.sleep(:infinity)
  end

  defp collect(render, acc) do
    receive do
      {:chunk, ^render, data} ->
        collect(render, %{acc | chunks: [data | acc.chunks]})

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

  ## Subprocess probing

  # The coordinator's render is the newest child of the render supervisor, and
  # the coordinator is its consumer — which is what identifies it here.
  defp subprocess_pid(coordinator) do
    os_pid =
      AudioProxy.Ffmpeg.RenderSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
      |> Enum.find_value(fn render ->
        if consumer(render) == coordinator, do: AudioProxy.Ffmpeg.Render.os_pid(render)
      end)

    assert os_pid, "no render found with the coordinator as its consumer"
    os_pid
  end

  defp consumer(render) do
    render |> :sys.get_state() |> Map.get(:consumer)
  end

  defp alive?(os_pid) do
    match?({_output, 0}, System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true))
  end

  defp gone_within?(_os_pid, remaining) when remaining <= 0, do: false

  defp gone_within?(os_pid, remaining) do
    if alive?(os_pid) do
      Process.sleep(25)
      gone_within?(os_pid, remaining - 25)
    else
      true
    end
  end
end
