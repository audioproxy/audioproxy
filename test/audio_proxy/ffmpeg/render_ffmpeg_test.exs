defmodule AudioProxy.Ffmpeg.RenderFfmpegTest do
  @moduledoc """
  The render pipeline driven by the real ffmpeg binary.

  `AudioProxy.Ffmpeg.RenderTest` and `RenderLifecycleTest` pin the mechanism
  with a fake subprocess, which is the only way to test a process that refuses
  to die — but a fake cannot say whether the argv
  `AudioProxy.Ffmpeg.Command` builds is a command ffmpeg accepts, whether the
  bytes coming back down the port are a decodable file, or whether a decode
  failure looks the way the classifier thinks it does. That is this file.

  Tagged `:ffmpeg`, so it is excluded by default and runs in the devcontainer
  and in CI's ffmpeg job. Fixtures are generated at setup rather than committed:
  no binary blobs in git, and the source is exactly reproducible from the
  `lavfi` expression that made it.
  """

  use ExUnit.Case, async: true

  import AudioProxy.Eventually

  alias AudioProxy.Ffmpeg.Command
  alias AudioProxy.Ffmpeg.Render
  alias AudioProxy.Options
  alias AudioProxy.RenderHarness

  @moduletag :ffmpeg

  @duration 20
  @sample_rate 44_100

  setup_all do
    dir = Path.join(System.tmp_dir!(), "audio_proxy_render_fixtures")
    File.mkdir_p!(dir)

    {:ok, source: sine_wav(dir), noise: noise_wav(dir), dir: dir}
  end

  describe "a real render" do
    test "produces a decodable mp3 of the requested length", %{source: source, dir: dir} do
      {:ok, options} = Options.parse("f:mp3/br:96/t:0:5")

      bytes = render!(options, source)

      # Not a size check: an encoder that emitted five seconds of silence, or a
      # truncated file, would pass one of those. ffprobe reading it back is the
      # only assertion that means "this is an mp3 a player would accept".
      output = Path.join(dir, "out.mp3")
      File.write!(output, bytes)

      assert probe(output, "codec_name") == "mp3"
      assert_in_delta parse_float(probe(output, "duration")), 5.0, 0.3
    end

    test "the trim is applied by ffmpeg, not merely requested", %{source: source, dir: dir} do
      {:ok, options} = Options.parse("f:wav/t:2:3")

      output = Path.join(dir, "trimmed.wav")
      File.write!(output, render!(options, source))

      # The fixture is 20 s; a render that ignored `-t` would come back as 20.
      assert_in_delta parse_float(probe(output, "duration")), 3.0, 0.1
    end

    test "streams in more than one chunk", %{noise: noise} do
      # Worth pinning against the real encoder: chunked delivery is only
      # chunked if ffmpeg actually writes progressively rather than at EOF.
      # Noise rather than the sine, because a pure tone compresses down to a
      # size that might arrive in a single read and pass this vacuously.
      {:ok, options} = Options.parse("f:wav")
      {:ok, render} = start(options, noise)

      assert length(collect_chunks(render, [])) > 1
    end
  end

  describe "real failures" do
    test "a nonexistent input classifies as :not_found" do
      {:ok, options} = Options.parse("f:mp3")
      {:ok, render} = start(options, "/nonexistent/definitely-not-here.wav")

      assert {:error, %{class: :not_found, stderr: stderr}, _bytes} =
               RenderHarness.collect(render, idle_timeout: 30_000)

      assert stderr != ""
    end

    test "a non-audio input classifies as :undecodable", %{dir: dir} do
      text = Path.join(dir, "not-audio.wav")
      File.write!(text, String.duplicate("this is not audio, whatever the extension says\n", 64))

      {:ok, options} = Options.parse("f:mp3")
      {:ok, render} = start(options, text)

      assert {:error, %{class: :undecodable, exit_status: status}, _bytes} =
               RenderHarness.collect(render, idle_timeout: 30_000)

      assert status != 0
    end

    test "a timeout kills a real ffmpeg", %{source: source} do
      {:ok, options} = Options.parse("f:mp3")

      # The timeout has to fit inside a window: long enough that this process
      # can still ask for the OS pid before the render times out and stops,
      # short enough that it fires well before a 20-second sine finishes
      # encoding (a few hundred milliseconds).
      #
      # It was 1 ms, which is under the scheduling latency of the very next
      # line on a loaded runner: the render had already begun stopping, and
      # `Render.os_pid/1` exited with `:normal` from inside
      # `GenServer.call/3`. That flaked on main before it flaked on a branch.
      {:ok, render} =
        Render.start_link(
          args: Command.build(options, source, type: :local),
          timeout: 100
        )

      os_pid = Render.os_pid(render)

      assert_receive {:error, ^render, %{class: :timeout}}, 5_000

      # The guarantee, against the binary it is actually about.
      assert gone_within?(os_pid, 5_000), "ffmpeg outlived its render timeout"
    end
  end

  ## Helpers

  defp start(options, input) do
    Render.start_link(args: Command.build(options, input, type: :local))
  end

  defp render!(options, input) do
    {:ok, render} = start(options, input)

    # Real encodes are slower than the fake subprocess; a generous idle timeout
    # here is about CI machines, not about the render timeout under test.
    assert {:ok, bytes, %{exit_status: 0}} = RenderHarness.collect(render, idle_timeout: 30_000)
    assert bytes != ""

    bytes
  end

  defp collect_chunks(render, acc) do
    receive do
      {:chunk, ^render, chunk} ->
        Render.ack(render, byte_size(chunk))
        collect_chunks(render, [chunk | acc])

      {:done, ^render, _info} ->
        Enum.reverse(acc)

      {:error, ^render, failure} ->
        flunk("render failed: #{inspect(failure)}")
    after
      30_000 -> flunk("render did not finish")
    end
  end

  defp sine_wav(dir) do
    generate(
      dir,
      "sine.wav",
      "sine=frequency=440:duration=#{@duration}:sample_rate=#{@sample_rate}"
    )
  end

  # Noise rather than a tone where the point is that bytes differ: a sine wave
  # compresses so well that a truncated encode can look plausible.
  defp noise_wav(dir) do
    generate(dir, "noise.wav", "anoisesrc=duration=#{@duration}:sample_rate=#{@sample_rate}")
  end

  defp generate(dir, name, lavfi) do
    path = Path.join(dir, name)

    unless File.exists?(path) do
      {_output, 0} =
        System.cmd("ffmpeg", [
          "-nostdin",
          "-hide_banner",
          "-loglevel",
          "error",
          "-y",
          "-f",
          "lavfi",
          "-i",
          lavfi,
          "-ac",
          "2",
          path
        ])
    end

    path
  end

  defp probe(path, field) do
    {output, 0} =
      System.cmd("ffprobe", [
        "-v",
        "error",
        "-select_streams",
        "a:0",
        "-show_entries",
        "stream=#{field}",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        path
      ])

    String.trim(output)
  end

  defp parse_float(string) do
    {value, _rest} = Float.parse(string)
    value
  end
end
