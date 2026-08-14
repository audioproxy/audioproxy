defmodule AudioProxy.Ffmpeg.CommandEnhanceFfmpegTest do
  @moduledoc """
  Renders `enhance:voice` through the real ffmpeg binary and reads the result.

  The unit suite pins the chain's *characters*; this file asks whether those
  characters do anything to audio. A preset is a promise that the proxy cleaned
  something up, and a filter name that ffmpeg silently accepts as a no-op —
  a de-esser at its default zero intensity, a denoiser below its own floor —
  keeps every argv assertion green while shipping the source back unchanged.

  ## Why the assertion is spectral, and why it is not golden bytes

  Golden bytes would pin the encoder, the filter implementations and the ffmpeg
  version all at once, and fail on a distro bump that changed none of the
  behaviour this preset promises. What the chain promises is a *shape*: energy
  below a speaking voice removed, the speech band left where it was. Measuring
  band energies states exactly that and survives everything else.

  The fixture is three tones plus noise, each standing in for what one stage of
  the chain is aimed at: 40 Hz for the rumble `highpass` removes, 200 Hz for the
  speech band that must survive it, 7 kHz for the sibilance the de-esser and
  denoiser work on. Deterministic tones, so the numbers are the filters' and not
  a random seed's.

  Measured identically under ffmpeg 7.1.5 (the shipped image) and 8.1.1, to the
  tenth of a dB; the thresholds below sit several dB inside those margins.

  Tagged `:ffmpeg`, so it runs in the devcontainer and CI's ffmpeg job.
  """

  use ExUnit.Case, async: true

  alias AudioProxy.Ffmpeg.Command
  alias AudioProxy.Fixtures
  alias AudioProxy.Options

  @moduletag :ffmpeg

  @rate 44_100
  @duration 5

  # The three components, and the band each is measured in. `w=40` is a narrow
  # bandpass around the speech tone, so the passband reading is that tone rather
  # than whatever the neighbouring stages left behind.
  @rumble_band "lowpass=f=60"
  @speech_band "bandpass=f=200:width_type=h:w=40"
  @sibilance_band "highpass=f=6000"

  setup_all do
    root = Fixtures.root!("command_enhance")

    source =
      Fixtures.encode!(
        Path.join(root, "sibilant.wav"),
        "aevalsrc=" <>
          "0.25*sin(2*PI*200*t)+0.2*sin(2*PI*7000*t)+0.25*sin(2*PI*40*t)+" <>
          "0.05*(random(0)-0.5)" <>
          ":d=#{@duration}:s=#{@rate}:c=stereo",
        ["-ac", "2", "-ar", to_string(@rate), "-c:a", "pcm_s16le"]
      )

    {:ok, root: root, source: source}
  end

  describe "enhance:voice, rendered" do
    @tag :tmp_dir
    test "reshapes the spectrum: rumble gone, speech band intact", context do
      plain = render!("f:wav", context)
      enhanced = render!("enhance:voice/f:wav", context)

      measure = &level(&1, &2, context.tmp_dir)

      # The high-pass, at a frequency an octave below its corner.
      assert measure.(plain, @rumble_band) - measure.(enhanced, @rumble_band) >= 6.0

      # …and not by simply turning everything down: the speech band the preset
      # exists to serve comes back at the level it went in at. Without this the
      # first assertion would pass for `volume=-20dB`.
      assert abs(measure.(plain, @speech_band) - measure.(enhanced, @speech_band)) <= 3.0

      # The denoise and de-ess stages, which work in the band above the voice.
      assert measure.(plain, @sibilance_band) - measure.(enhanced, @sibilance_band) >= 2.0
    end

    test "composes with norm rather than being replaced by it", context do
      assert byte_size(render!("enhance:voice/norm:ebu/f:wav", context)) > 1_000
    end
  end

  # Renders through the production argv builder — the point is that *this*
  # command runs, not that this chain of filters exists in some ffmpeg.
  defp render!(options, context) do
    {:ok, opts} = Options.parse(options)
    argv = Command.build(opts, context.source, type: :local)

    {output, status} = ffmpeg(argv)

    assert status == 0, "#{options} exited #{status}: #{inspect(binary_slice(output, 0, 400))}"

    output
  end

  # Mean volume in one band, in dBFS. The rendered bytes are written to the
  # test's own `:tmp_dir` rather than beside the fixture: this is an output, and
  # an output two parallel runs collide on is the one under assertion.
  defp level(wav, band, tmp_dir) do
    path = Path.join(tmp_dir, "measure-#{System.unique_integer([:positive])}.wav")
    File.write!(path, wav)

    {output, 0} =
      System.cmd(
        "ffmpeg",
        ["-nostdin", "-hide_banner", "-i", path, "-af", "#{band},volumedetect"] ++
          ["-f", "null", "-"],
        stderr_to_stdout: true
      )

    [_line, decibels] = Regex.run(~r/mean_volume:\s*(-?\d+(?:\.\d+)?) dB/, output)

    String.to_float(decibels)
  end

  defp ffmpeg(argv) do
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
end
