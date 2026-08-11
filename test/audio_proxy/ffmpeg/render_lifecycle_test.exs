defmodule AudioProxy.Ffmpeg.RenderLifecycleTest do
  @moduledoc """
  The orphan guarantee, the timeout, and failure classification.

  These are the tests the slice exists for. "No ffmpeg process outlives its
  render" is not a claim a mock can settle — it is a claim about the operating
  system — so every case here reads the subprocess' real OS pid and probes it
  with `kill -0` until it is gone or a deadline passes.

  `fake_cmd.sh` rather than ffmpeg, because one of the cases needs a process
  that *refuses* to die on `SIGTERM`, and the real encoder cannot be asked to
  do that on demand.
  """

  use ExUnit.Case, async: true

  import AudioProxy.Eventually

  alias AudioProxy.Ffmpeg.Render
  alias AudioProxy.Ffmpeg.RenderSupervisor
  alias AudioProxy.RenderHarness

  # The kill discipline's own grace is 2 s; a deadline comfortably past it
  # separates "escalated late" from "never escalated" without making a failure
  # wait forever.
  @deadline 5_000

  setup do
    {:ok, fake_cmd: RenderHarness.fake_cmd()}
  end

  describe "no orphan processes" do
    test "kills the subprocess when the consumer dies", %{fake_cmd: fake_cmd} do
      consumer = spawn_idle_consumer()
      {render, os_pid} = start_hanging_render(fake_cmd, consumer: consumer)
      down = Process.monitor(render)

      # The consumer, not the render: the render has to notice the death of the
      # process it was streaming to, and take its subprocess with it.
      Process.exit(consumer, :kill)

      assert gone_within?(os_pid, @deadline), "the subprocess outlived its consumer"

      # Waited for rather than asserted outright: the subprocess dying and the
      # render process finishing its own shutdown are two events, in that
      # order, and checking the second one the instant the first lands is a
      # race the test would lose intermittently.
      assert_receive {:DOWN, ^down, :process, ^render, _reason}, 1_000
    end

    test "kills the subprocess on cancel/1", %{fake_cmd: fake_cmd} do
      {render, os_pid} = start_hanging_render(fake_cmd)

      assert :ok = Render.cancel(render)

      # No deadline: `cancel/1` returns from the far side of the kill, so if it
      # has come back and the process is still there, that is the bug.
      refute alive?(os_pid), "cancel/1 returned before the subprocess was gone"
    end

    test "cancel/1 tells the consumer why the stream ended", %{fake_cmd: fake_cmd} do
      {render, _os_pid} = start_hanging_render(fake_cmd)

      :ok = Render.cancel(render)

      assert_receive {:error, ^render, %{class: :cancelled}}, 1_000
    end

    test "cancelling a finished render is not an error", %{fake_cmd: fake_cmd} do
      {:ok, render} = Render.start_link(executable: fake_cmd, args: ["emit", "16"])
      assert {:ok, _bytes, _info} = RenderHarness.collect(render)

      assert :ok = Render.cancel(render)
    end

    test "escalates to SIGKILL for a subprocess that ignores SIGTERM", %{fake_cmd: fake_cmd} do
      # The `emit` sits between the trap and the sleep deliberately. Signalling
      # a process that has been spawned but has not yet reached its `trap` is a
      # race the test would lose silently — TERM would simply work, and the
      # escalation this test exists for would never run. A chunk arriving is
      # proof that the trap is installed.
      {:ok, render} =
        Render.start_link(
          executable: fake_cmd,
          args: ["ignore-term", "emit", "8", "sleep", "60"]
        )

      os_pid = Render.os_pid(render)
      assert_receive {:chunk, ^render, _bytes}, 5_000
      assert alive?(os_pid)

      {elapsed, :ok} = :timer.tc(fn -> Render.cancel(render) end, :millisecond)

      # `gone_within?` rather than a bare `alive?`, for the reason every other
      # death assertion in this file uses it: SIGKILL delivery and reaping are
      # the kernel's business, and on a loaded machine they can outlast the
      # reap grace `cancel/1` waits out. What is under test is that the process
      # dies and that the escalation ran, not that the kernel is prompt.
      assert gone_within?(os_pid, @deadline), "a TERM-ignoring subprocess survived cancel/1"

      # The elapsed time is the assertion that matters, and it is why this test
      # is not merely a slower copy of the one above: a process that died on
      # SIGTERM would have been gone in milliseconds. Waiting out the full
      # grace is proof that TERM was tried, ignored, and escalated — the one
      # path that a process refusing to die actually exercises.
      assert elapsed >= 2_000, "cancel/1 returned in #{elapsed}ms without waiting out the grace"
    end

    test "kills the subprocess when the supervisor shuts the render down", %{fake_cmd: fake_cmd} do
      {:ok, render} =
        RenderSupervisor.start_render(
          executable: fake_cmd,
          args: ["sleep", "60"],
          consumer: self()
        )

      os_pid = Render.os_pid(render)

      # The path a release takes at VM stop: the supervisor terminates its
      # children, and each child's `terminate/2` runs.
      :ok = DynamicSupervisor.terminate_child(RenderSupervisor, render)

      assert gone_within?(os_pid, @deadline), "the subprocess outlived the supervisor's shutdown"
    end
  end

  describe "render timeout" do
    test "kills the subprocess and reports :timeout", %{fake_cmd: fake_cmd} do
      {:ok, render} = Render.start_link(executable: fake_cmd, args: ["sleep", "60"], timeout: 100)

      os_pid = Render.os_pid(render)

      assert_receive {:error, ^render, %{class: :timeout}}, 2_000
      assert gone_within?(os_pid, @deadline), "a timed-out render left its subprocess behind"
    end

    test "does not time out a finished render whose consumer is slow to ack", %{
      fake_cmd: fake_cmd
    } do
      # The regression this exists for: the subprocess exits cleanly, but the
      # consumer has not acked, so chunks are still queued and the completion
      # message is rightly withheld. With the timer still armed across that
      # wait, a successful encode was reported as `:timeout` — and would have
      # been answered 504.
      #
      # `AP_RENDER_TIMEOUT` bounds how long ffmpeg may run. ffmpeg has stopped.
      #
      # The two numbers are a ratio, not magic: the timeout has to be long
      # enough that writing 4 MB and exiting comfortably beats it on a loaded
      # machine — at 300 ms it did not, and the suite flaked as this test's own
      # regression — and the wait has to be several times the timeout, so that
      # a timer still armed would certainly have fired by the assertion.
      {:ok, render} =
        Render.start_link(
          executable: fake_cmd,
          args: ["emit", "#{4 * 1_048_576}"],
          timeout: 500
        )

      Process.sleep(1_500)

      refute_received {:error, ^render, %{class: :timeout}}

      # And the render still completes correctly once the consumer catches up.
      assert {:ok, bytes, %{exit_status: 0}} = RenderHarness.collect(render, idle_timeout: 5_000)
      assert byte_size(bytes) == 4 * 1_048_576
    end

    test "a render that finishes in time is unaffected", %{fake_cmd: fake_cmd} do
      {:ok, render} =
        Render.start_link(executable: fake_cmd, args: ["emit", "1024"], timeout: 30_000)

      assert {:ok, bytes, %{exit_status: 0}} = RenderHarness.collect(render)
      assert bytes == RenderHarness.pattern(1024)
    end

    test "arms the timer from AP_RENDER_TIMEOUT when not overridden", %{fake_cmd: fake_cmd} do
      # A wiring assertion: the deadline has to come from configuration rather
      # than from a constant nobody can change. Read off a render that is still
      # running, so there is nothing to race against.
      seconds = AudioProxy.Config.get(:render_timeout)
      assert seconds > 0

      {render, _os_pid} = start_hanging_render(fake_cmd)
      remaining = Process.read_timer(:sys.get_state(render).timer)

      assert is_integer(remaining)
      assert_in_delta remaining, seconds * 1_000, 1_000

      :ok = Render.cancel(render)
    end
  end

  describe "failure classification" do
    test "a missing input classifies as :not_found", %{fake_cmd: fake_cmd} do
      assert %{class: :not_found, exit_status: 1} =
               failure(fake_cmd, "prev.wav: No such file or directory", 1)
    end

    test "an HTTP 404 on the input classifies as :not_found", %{fake_cmd: fake_cmd} do
      assert %{class: :not_found} = failure(fake_cmd, "Server returned 404 Not Found", 1)
    end

    test "undecodable input classifies as :undecodable", %{fake_cmd: fake_cmd} do
      assert %{class: :undecodable} =
               failure(fake_cmd, "Invalid data found when processing input", 1)
    end

    test "anything else classifies as :render_failed", %{fake_cmd: fake_cmd} do
      assert %{class: :render_failed, exit_status: 137} =
               failure(fake_cmd, "Conversion failed!", 137)
    end

    test "carries the stderr tail back to the consumer", %{fake_cmd: fake_cmd} do
      assert %{stderr: stderr} = failure(fake_cmd, "Invalid data found when processing input", 1)
      assert stderr =~ "Invalid data found when processing input"
    end

    test "truncates the stderr tail to a fixed budget", %{fake_cmd: fake_cmd} do
      # 16 KiB of complaint, of which only the tail may survive. The marker sits
      # at the end, because the *tail* is what a diagnostic wants: ffmpeg's last
      # word on a failure is the useful one.
      noise = String.duplicate("x", 16_384) <> "\nConversion failed!"

      assert %{stderr: stderr} = failure(fake_cmd, noise, 1)
      assert byte_size(stderr) <= 4_096
      assert stderr =~ "Conversion failed!"
    end

    test "a clean exit is never classified as a failure", %{fake_cmd: fake_cmd} do
      # ffmpeg writes to stderr on success too. A render that exited 0 must not
      # be classified out of existence by whatever it happened to say.
      {:ok, render} =
        Render.start_link(
          executable: fake_cmd,
          args: ["stderr", "Invalid data found when processing input", "emit", "32"]
        )

      assert {:ok, bytes, %{exit_status: 0}} = RenderHarness.collect(render)
      assert bytes == RenderHarness.pattern(32)
    end
  end

  describe "scratch files" do
    test "the stderr file is deleted when the render ends", %{fake_cmd: fake_cmd} do
      {render, _os_pid} = start_hanging_render(fake_cmd)

      path = :sys.get_state(render).stderr_path

      # The file appears when the wrapper shell applies its redirect, which is
      # a moment after the port opens rather than at the same instant.
      assert eventually?(fn -> File.exists?(path) end, 2_000), "stderr file was never created"

      :ok = Render.cancel(render)

      refute File.exists?(path)
    end
  end

  describe "scratch isolation" do
    test "scratch dir is per-instance, not per-node" do
      dir = Render.scratch_dir()

      refute dir == Path.join(System.tmp_dir!(), "audio_proxy_render-#{node()}")
      assert String.ends_with?(dir, "-#{System.pid()}")
    end

    test "sweep_scratch removes only orphaned sibling directories" do
      tmp = System.tmp_dir!()
      prefix = "audio_proxy_render-#{node()}"

      # A live sibling must not be the current VM's own directory, or the
      # `reject(&(&1 == own))` filter would hide a broken liveness predicate.
      # Spawn a real subprocess and use its OS pid.
      live_pid_file = Path.join(tmp, "live_pid_#{System.unique_integer([:positive])}.txt")

      System.cmd("sh", [
        "-c",
        "sleep 60 > /dev/null 2>&1 & echo $! > #{live_pid_file}"
      ])

      live_pid = live_pid_file |> File.read!() |> String.trim() |> String.to_integer()
      assert AudioProxy.OsProcess.alive?(live_pid), "live subprocess was not alive"

      live_dir = Path.join(tmp, "#{prefix}-#{live_pid}")
      File.mkdir_p!(live_dir)
      File.write!(Path.join(live_dir, "live.log"), "live")

      {dead_pid_str, 0} =
        System.cmd("sh", ["-c", "echo $$; exit 0"], stderr_to_stdout: true)

      dead_pid = dead_pid_str |> String.trim() |> String.to_integer()
      refute AudioProxy.OsProcess.alive?(dead_pid), "dead fixture pid was reused before the test"

      dead_dir = Path.join(tmp, "#{prefix}-#{dead_pid}")
      File.mkdir_p!(dead_dir)
      File.write!(Path.join(dead_dir, "dead.log"), "dead")

      unknown_dir =
        Path.join(tmp, "audio_proxy_render-unknown-#{System.unique_integer([:positive])}-fixture")

      File.mkdir_p!(unknown_dir)
      File.write!(Path.join(unknown_dir, "unknown.log"), "unknown")

      on_exit(fn ->
        AudioProxy.OsProcess.signal(live_pid, "KILL")
        File.rm(live_pid_file)
        File.rm_rf(live_dir)
        File.rm_rf(dead_dir)
        File.rm_rf(unknown_dir)
      end)

      RenderSupervisor.sweep_scratch()

      assert File.exists?(live_dir), "live instance's scratch was swept"
      refute File.exists?(dead_dir), "dead instance's scratch was not swept"
      assert File.exists?(unknown_dir), "unowned scratch was swept"
    end
  end

  ## Helpers

  defp failure(fake_cmd, stderr, exit_status) do
    {:ok, render} =
      Render.start_link(
        executable: fake_cmd,
        args: ["stderr", stderr, "exit", "#{exit_status}"]
      )

    assert {:error, failure, _bytes} = RenderHarness.collect(render)
    failure
  end

  # A render whose subprocess will not end on its own, so that only the kill
  # discipline can end it.
  defp start_hanging_render(fake_cmd, opts \\ []) do
    opts = Keyword.merge([executable: fake_cmd, args: ["sleep", "60"]], opts)
    {:ok, render} = Render.start_link(opts)

    os_pid = Render.os_pid(render)
    assert is_integer(os_pid) and alive?(os_pid)

    {render, os_pid}
  end

  # Stays alive until killed, so a test can choose the moment.
  defp spawn_idle_consumer do
    spawn(fn ->
      receive do
        :never -> :ok
      end
    end)
  end
end
