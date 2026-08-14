defmodule AudioProxy.Ffmpeg.CommandEnhanceFfmpegTest do
  @moduledoc """
  Renders `enhance:voice` through the real ffmpeg binary and measures it.

  The unit suite pins the chain's *characters*; this file asks whether those
  characters do anything to audio. A preset is a promise that the proxy cleaned
  something up, and a filter that ffmpeg accepts and silently ignores — a
  de-esser left at its default zero intensity, a limiter whose auto-level puts
  back exactly what it took off — keeps every argv assertion green while
  shipping the source back unchanged.

  ## One probe per stage, because a whole-chain assertion is not enough

  The first version of this file asserted three bands on one fixture, and an
  adversarial review found that it stayed green with `acompressor` deleted.
  Mutating each filter in turn showed the gap was wider than reported: dropping
  `afftdn` passed too. Two of four stages were pinned only as characters.

  So each stage now has a fixture built to isolate it, and each assertion was
  checked by deleting its stage and watching it fail:

  | Stage | Fixture | Assertion |
  |---|---|---|
  | `highpass` | tones at 40/200/7000 Hz plus noise | energy below 60 Hz drops ≥ 6 dB |
  | `deesser` | the same | energy above 6 kHz drops ≥ 2 dB |
  | `afftdn` | broadband noise alone | overall level drops ≥ 3 dB |
  | `acompressor` | a loud half and a quiet half | the gap between them narrows ≥ 4 dB |
  | `alimiter` | 5 ms bursts over a quiet bed | no sample exceeds the ceiling |

  The speech-band assertion belongs to none of them: it is what stops the whole
  file passing for `volume=-20dB`, which would satisfy every "drops by" line
  above.

  ## Why the assertions are spectral rather than golden bytes

  Golden bytes would pin the encoder, the filter implementations and the ffmpeg
  version all at once, and fail on a distro bump that changed none of the
  behaviour this preset promises. The measurements below were identical under
  ffmpeg 7.1.5 (the shipped image) and 8.1.1, to the tenth of a dB, and every
  threshold sits at least 2 dB inside the measured value.

  Tagged `:ffmpeg`, so it runs in the devcontainer and CI's ffmpeg job.
  """

  use ExUnit.Case, async: true

  alias AudioProxy.Ffmpeg.Command
  alias AudioProxy.Fixtures
  alias AudioProxy.Options

  @moduletag :ffmpeg

  @rate 44_100
  @duration 5

  # `lowpass`/`highpass`/`bandpass` here are *measurement* filters, not the
  # preset's. `w=40` is a narrow band around the speech tone, so that reading is
  # the tone rather than what its neighbours left behind.
  @rumble_band "lowpass=f=60"
  @speech_band "bandpass=f=200:width_type=h:w=40"
  @sibilance_band "highpass=f=6000"

  # The whole file, for the fixtures whose subject is a level rather than a band.
  @full_band "anull"

  # The limiter's ceiling is −0.2 dBFS (`limit=0.977`). −0.1 is the assertion:
  # above it means the ceiling is not holding, and 0.0 is what clipping reads as
  # once the samples have been written as s16.
  @ceiling_db -0.1

  setup_all do
    root = Fixtures.root!("command_enhance")

    # Three tones and a noise bed. Each tone stands for what one stage is aimed
    # at: 40 Hz for the rumble `highpass` removes, 200 Hz for the speech band
    # that must survive it, 7 kHz for the sibilance `deesser` works on.
    sibilant =
      Fixtures.encode!(
        Path.join(root, "sibilant.wav"),
        "aevalsrc=" <>
          "0.25*sin(2*PI*200*t)+0.2*sin(2*PI*7000*t)+0.25*sin(2*PI*40*t)+" <>
          "0.05*(random(0)-0.5)" <>
          ":d=#{@duration}:s=#{@rate}:c=stereo",
        pcm()
      )

    # Noise with no tone in it at all. The tones had to go: a bandpass around
    # 3 kHz on the fixture above reads mostly skirt leakage from the 7 kHz tone,
    # which is how the first attempt at an `afftdn` assertion measured the wrong
    # thing and concluded the stage was useless.
    noise =
      Fixtures.encode!(
        Path.join(root, "noise.wav"),
        "aevalsrc=0.05*(random(0)-0.5):d=#{@duration}:s=#{@rate}:c=stereo",
        pcm()
      )

    # Loud for half its length, then 20 dB quieter — a stand-in for a speaker
    # walking away from the mic, which is the thing `acompressor` is there for.
    dynamic =
      Fixtures.encode!(
        Path.join(root, "dynamic.wav"),
        "aevalsrc=sin(2*PI*300*t)*if(lt(t\\,2.5)\\,0.5\\,0.05)" <>
          ":d=#{@duration}:s=#{@rate}:c=stereo",
        pcm()
      )

    # 5 ms bursts at −3 dBFS over a quiet bed. The burst is far shorter than the
    # compressor's 20 ms attack, so it passes through uncompressed and then
    # takes the full makeup — the case that clipped before the limiter existed.
    hot =
      Fixtures.encode!(
        Path.join(root, "hot.wav"),
        "aevalsrc=0.7*sin(2*PI*1000*t)*if(lt(mod(t\\,1)\\,0.005)\\,1\\,0.03)" <>
          ":d=#{@duration}:s=#{@rate}:c=stereo",
        pcm()
      )

    {:ok, root: root, sibilant: sibilant, noise: noise, dynamic: dynamic, hot: hot}
  end

  defp pcm, do: ["-ac", "2", "-ar", to_string(@rate), "-c:a", "pcm_s16le"]

  describe "enhance:voice, rendered" do
    @tag :tmp_dir
    test "the high-pass removes rumble and leaves the speech band alone", context do
      plain = render!("f:wav", context.sibilant)
      enhanced = render!("enhance:voice/f:wav", context.sibilant)
      measure = probe(context.tmp_dir)

      # `highpass=f=80`, measured an octave below its corner.
      assert measure.(plain, @rumble_band).mean - measure.(enhanced, @rumble_band).mean >= 6.0

      # …and not by simply turning everything down. The band the preset exists
      # to serve comes back where it went in, which is what stops every "drops
      # by" assertion in this file from being satisfied by `volume=-20dB`.
      assert abs(measure.(plain, @speech_band).mean - measure.(enhanced, @speech_band).mean) <=
               3.0
    end

    @tag :tmp_dir
    test "the de-esser takes down the band above the voice", context do
      plain = render!("f:wav", context.sibilant)
      enhanced = render!("enhance:voice/f:wav", context.sibilant)
      measure = probe(context.tmp_dir)

      assert measure.(plain, @sibilance_band).mean - measure.(enhanced, @sibilance_band).mean >=
               2.0
    end

    # Measured 6.0 dB down with the chain, and 5.9 dB *up* without `afftdn` —
    # the makeup gain with nothing to remove. The assertion is one-sided on
    # purpose: it fails in both directions of that split.
    @tag :tmp_dir
    test "the denoiser lowers a broadband noise floor rather than amplifying it", context do
      plain = render!("f:wav", context.noise)
      enhanced = render!("enhance:voice/f:wav", context.noise)
      measure = probe(context.tmp_dir)

      assert measure.(plain, @full_band).mean - measure.(enhanced, @full_band).mean >= 3.0
    end

    # The compressor is invisible on the steady tones above: on a signal that
    # does not vary, compression is just a gain. It needs material that moves.
    @tag :tmp_dir
    test "the compressor narrows the gap between a loud and a quiet passage", context do
      plain = render!("f:wav", context.dynamic)
      enhanced = render!("enhance:voice/f:wav", context.dynamic)
      measure = probe(context.tmp_dir)

      assert gap(measure, plain) - gap(measure, enhanced) >= 4.0
    end

    # The finding this stage exists for: without the limiter this render peaks
    # at 0.0 dBFS from a source that peaked at −3.1, i.e. the preset introduced
    # clipping that was not in the source.
    @tag :tmp_dir
    test "the limiter holds the ceiling on a transient the compressor lets through", context do
      plain = render!("f:wav", context.hot)
      enhanced = render!("enhance:voice/f:wav", context.hot)
      measure = probe(context.tmp_dir)

      assert measure.(plain, @full_band).max < @ceiling_db
      assert measure.(enhanced, @full_band).max <= @ceiling_db
    end

    test "composes with norm rather than being replaced by it", context do
      assert byte_size(render!("enhance:voice/norm:ebu/f:wav", context.sibilant)) > 1_000
    end
  end

  # The loud half against the quiet half, in dB. `atrim` stays clear of both
  # edges so neither reading includes the step between them.
  defp gap(measure, wav) do
    measure.(wav, "atrim=start=0.5:end=2").mean - measure.(wav, "atrim=start=3:end=4.8").mean
  end

  # Renders through the production argv builder — the claim is that *this*
  # command does this, not that these filters exist in some ffmpeg.
  defp render!(options, source) do
    {:ok, opts} = Options.parse(options)
    argv = Command.build(opts, source, type: :local)

    {output, status} = ffmpeg(argv)

    assert status == 0, "#{options} exited #{status}: #{inspect(binary_slice(output, 0, 400))}"

    output
  end

  defp probe(tmp_dir), do: &measure(&1, &2, tmp_dir)

  # Mean and peak level behind a measurement filter, in dBFS. The rendered bytes
  # go to the test's own `:tmp_dir` rather than beside the fixtures: this is an
  # output, and an output two parallel runs collide on is the one under
  # assertion.
  defp measure(wav, filter, tmp_dir) do
    path = Path.join(tmp_dir, "measure-#{System.unique_integer([:positive])}.wav")
    File.write!(path, wav)

    {output, 0} =
      System.cmd(
        "ffmpeg",
        ["-nostdin", "-hide_banner", "-i", path, "-af", "#{filter},volumedetect"] ++
          ["-f", "null", "-"],
        stderr_to_stdout: true
      )

    %{mean: decibels(output, "mean_volume"), max: decibels(output, "max_volume")}
  end

  # `volumedetect` prints `-inf` for digital silence, which no fixture here is,
  # so a missing reading means the measurement did not run rather than that the
  # band was empty — worth a named failure instead of a MatchError.
  defp decibels(output, field) do
    case Regex.run(~r/#{field}:\s*(-?\d+(?:\.\d+)?) dB/, output) do
      [_line, value] -> String.to_float(value)
      nil -> flunk("no #{field} in volumedetect output: #{inspect(binary_slice(output, 0, 400))}")
    end
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
