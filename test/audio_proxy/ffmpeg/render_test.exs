defmodule AudioProxy.Ffmpeg.RenderTest do
  @moduledoc """
  The render mechanism, driven by `test/support/fake_cmd.sh`.

  What is under test here is the plumbing — bytes in order, argv verbatim, the
  buffer holding when nobody acks — not ffmpeg. The real binary appears in
  `AudioProxy.Ffmpeg.RenderFfmpegTest`, tagged `:ffmpeg`.
  """

  use ExUnit.Case, async: true

  alias AudioProxy.Ffmpeg.Render
  alias AudioProxy.RenderHarness

  setup do
    {:ok, fake_cmd: RenderHarness.fake_cmd()}
  end

  describe "chunk streaming" do
    test "delivers the subprocess' stdout byte for byte", %{fake_cmd: fake_cmd} do
      size = 200_000
      {:ok, render} = Render.start_link(executable: fake_cmd, args: ["emit", "#{size}"])

      assert {:ok, bytes, info} = RenderHarness.collect(render)
      assert bytes == RenderHarness.pattern(size)
      assert info == %{exit_status: 0}
    end

    test "arrives as several chunks, in order", %{fake_cmd: fake_cmd} do
      {:ok, render} = Render.start_link(executable: fake_cmd, args: ["emit", "200000"])

      chunks = chunks_until_done(render, [])

      # Ordering is only meaningful if there was more than one chunk to order:
      # a single-chunk stream would pass a concatenation check trivially.
      assert length(chunks) > 1
      assert IO.iodata_to_binary(chunks) == RenderHarness.pattern(200_000)
    end

    test "an empty output still completes", %{fake_cmd: fake_cmd} do
      {:ok, render} = Render.start_link(executable: fake_cmd, args: ["exit", "0"])

      assert {:ok, "", %{exit_status: 0}} = RenderHarness.collect(render)
    end

    test "the render process stops once the consumer has been told", %{fake_cmd: fake_cmd} do
      {:ok, render} = Render.start_link(executable: fake_cmd, args: ["emit", "1024"])
      monitor = Process.monitor(render)

      assert {:ok, _bytes, _info} = RenderHarness.collect(render)
      assert_receive {:DOWN, ^monitor, :process, ^render, :normal}, 1_000
    end
  end

  describe "argv" do
    test "passes shell metacharacters through as data", %{fake_cmd: fake_cmd} do
      hostile = ["; $(id) `whoami` \"quoted\" *", "a b\tc", "--not-a-flag=$HOME"]

      {:ok, render} = Render.start_link(executable: fake_cmd, args: ["args" | hostile])

      assert {:ok, bytes, _info} = RenderHarness.collect(render)
      assert String.split(bytes, "\n", trim: true) == hostile
    end
  end

  describe "failure" do
    test "reports a nonzero exit status", %{fake_cmd: fake_cmd} do
      {:ok, render} = Render.start_link(executable: fake_cmd, args: ["exit", "3"])

      assert {:error, %{class: :render_failed, exit_status: 3, stderr: ""}, ""} =
               RenderHarness.collect(render)
    end

    test "delivers the bytes written before a nonzero exit", %{fake_cmd: fake_cmd} do
      args = ["emit", "4096", "exit", "1"]
      {:ok, render} = Render.start_link(executable: fake_cmd, args: args)

      assert {:error, %{exit_status: 1}, bytes} = RenderHarness.collect(render)
      assert bytes == RenderHarness.pattern(4096)
    end

    test "refuses to start on a missing executable" do
      assert {:error, {:executable_not_found, "/nonexistent/ffmpeg"}} =
               Render.start_link(executable: "/nonexistent/ffmpeg", args: [])
    end
  end

  describe "bounded buffer" do
    @high_water 1_048_576

    test "stops forwarding above the high-water mark, and resumes on ack", %{fake_cmd: fake_cmd} do
      size = 4 * @high_water
      {:ok, render} = Render.start_link(executable: fake_cmd, args: ["emit", "#{size}"])

      # A consumer that never acks: forwarding stalls, and the completion
      # message is withheld with it.
      assert {:timeout, stalled} = RenderHarness.collect(render, ack: false, idle_timeout: 1_000)

      # Both bounds are load-bearing, and the lower one especially: asserting
      # only that *something* arrived would pass a render that stalled after a
      # single byte, which is the opposite bug and would look identical here.
      #
      # The upper bound allows exactly one chunk to cross the mark. 64 KiB is
      # the port's read buffer rather than a documented guarantee, so this is
      # an empirical ceiling — generous enough not to be fragile, tight enough
      # that "forwarded everything" fails it.
      assert byte_size(stalled) >= @high_water
      assert byte_size(stalled) < @high_water + 65_536

      # Acking what was held releases the rest, and it is still the same stream.
      Render.ack(render, byte_size(stalled))

      assert {:ok, rest, %{exit_status: 0}} = RenderHarness.collect(render)
      assert stalled <> rest == RenderHarness.pattern(size)
    end
  end

  describe "supervision" do
    test "start_render/1 runs under the dynamic supervisor", %{fake_cmd: fake_cmd} do
      {:ok, render} =
        AudioProxy.Ffmpeg.RenderSupervisor.start_render(
          executable: fake_cmd,
          args: ["emit", "1024"],
          consumer: self()
        )

      assert {:ok, bytes, _info} = RenderHarness.collect(render)
      assert bytes == RenderHarness.pattern(1024)
    end

    test "refuses to start without an explicit consumer", %{fake_cmd: fake_cmd} do
      # Under the supervisor the caller is the supervisor, so inheriting
      # `Render.start_link/1`'s `self()` default would mail the stream into the
      # supervisor's mailbox and strand whoever wanted the bytes.
      assert_raise KeyError, fn ->
        AudioProxy.Ffmpeg.RenderSupervisor.start_render(
          executable: fake_cmd,
          args: ["emit", "16"]
        )
      end
    end
  end

  defp chunks_until_done(render, acc) do
    receive do
      {:chunk, ^render, chunk} ->
        Render.ack(render, byte_size(chunk))
        chunks_until_done(render, [chunk | acc])

      {:done, ^render, _info} ->
        Enum.reverse(acc)
    after
      2_000 -> flunk("render did not finish")
    end
  end
end
