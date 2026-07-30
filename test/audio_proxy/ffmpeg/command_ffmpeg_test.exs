defmodule AudioProxy.Ffmpeg.CommandFfmpegTest do
  @moduledoc """
  Runs the built argv through the real ffmpeg binary.

  The unit and property suites pin the argv's *shape*; only ffmpeg can say
  whether that shape is a command it accepts. Every encoder name, muxer name
  and flag in `AudioProxy.Ffmpeg.Command` is an assumption about a binary
  this repo does not ship, so each one gets exercised here — a typo in a
  codec name is otherwise a runtime 500 with a green test suite behind it.

  Tagged `:ffmpeg`, so it is excluded by default and runs in the devcontainer
  and in CI's ffmpeg job.
  """

  use ExUnit.Case, async: true

  alias AudioProxy.Ffmpeg.Command
  alias AudioProxy.Options

  @moduletag :ffmpeg

  @duration 20
  @sample_rate 44_100

  setup_all do
    source = Path.join(System.tmp_dir!(), "audio_proxy_command_test_tone.wav")

    unless File.exists?(source) do
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
          "sine=frequency=440:duration=#{@duration}:sample_rate=#{@sample_rate}",
          "-ac",
          "2",
          "-c:a",
          "pcm_s16le",
          source
        ])
    end

    on_exit(fn -> File.rm(source) end)

    {:ok, source: source}
  end

  defp render(options, source) do
    {:ok, opts} = Options.parse(options)
    argv = Command.build(opts, source)

    port =
      Port.open({:spawn_executable, System.find_executable("ffmpeg")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: argv
      ])

    collect(port, [])
  end

  defp collect(port, chunks) do
    receive do
      {^port, {:data, chunk}} -> collect(port, [chunk | chunks])
      {^port, {:exit_status, status}} -> {IO.iodata_to_binary(Enum.reverse(chunks)), status}
    after
      30_000 -> flunk("ffmpeg did not finish within 30s")
    end
  end

  # `-loglevel error` keeps stderr silent on success, so anything that comes
  # back alongside a zero exit status is a diagnostic worth failing on.
  defp assert_renders(options, source, minimum_bytes \\ 1_000) do
    {output, status} = render(options, source)

    assert status == 0, "#{options} exited #{status}: #{inspect(binary_part(output, 0, 400))}"
    assert byte_size(output) >= minimum_bytes, "#{options} produced #{byte_size(output)} bytes"

    output
  end

  describe "every format encodes" do
    test "lossy formats", %{source: source} do
      assert_renders("f:mp3/br:128", source)
      assert_renders("f:opus/br:96", source)
      assert_renders("f:ogg/q:5", source)
      assert_renders("f:aac/br:128", source)
      assert_renders("f:m4a/br:128", source)
    end

    test "lossless formats at every bit depth", %{source: source} do
      assert_renders("f:flac/bd:16", source)
      assert_renders("f:flac/bd:24", source)
      assert_renders("f:wav/bd:16", source)
      assert_renders("f:wav/bd:24", source)
      assert_renders("f:wav/bd:32f", source)
    end

    test "the quality knob each codec actually has", %{source: source} do
      assert_renders("f:mp3/q:2", source)
      assert_renders("f:ogg/q:5", source)
      assert_renders("f:aac/q:1.5", source)
      assert_renders("f:opus/q:8", source)
      assert_renders("f:flac/q:8", source)
    end
  end

  describe "every filter applies" do
    test "trim, fade, gain, norm and resample", %{source: source} do
      assert_renders("t:2.5:5", source)
      assert_renders("t:0:10/fade:0.5:1", source)
      assert_renders("gain:-3.5", source)
      assert_renders("norm:ebu", source)
      assert_renders("norm:ebu:-14:-1:9/gain:-3/sr:44100", source)
      assert_renders("sr:22050/ch:1", source)
    end

    test "the API doc §1 preview", %{source: source} do
      assert_renders("f:opus/br:96/t:2.5:5/fade:0.5:1", source)
    end
  end

  describe "output shape" do
    # 5 s of mono 16-bit at the source rate, exactly — proof that the trim is
    # honoured and that nothing re-encodes what the peak reducer will read.
    test "peaks are raw PCM of a predictable size", %{source: source} do
      output = assert_renders("f:peaks/t:0:5/ch:1", source)

      assert byte_size(output) == 5 * @sample_rate * 2
    end

    test "fragmented mp4 needs no seekable output", %{source: source} do
      output = assert_renders("f:m4a/br:96", source)

      # An empty moov up front is what makes the stream playable as it
      # arrives; a plain mp4 would have failed on pipe:1 long before this.
      assert binary_part(output, 0, 12) =~ "ftyp"
    end

    test "a hostile filename is data, not syntax", %{source: source} do
      hostile = Path.join(System.tmp_dir!(), "a b;$(id)'\".wav")
      File.cp!(source, hostile)
      on_exit(fn -> File.rm(hostile) end)

      assert_renders("f:mp3/br:96/t:0:2", hostile)
    end
  end
end
