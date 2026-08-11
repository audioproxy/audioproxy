defmodule AudioProxy.Fixtures do
  @moduledoc """
  Generated audio fixtures for the `:ffmpeg`-tagged suite, and the one place
  the generating `ffmpeg` invocation lives.

  Fixtures are generated rather than committed on purpose: no binary blobs in
  git, and a fixture is exactly what *this* ffmpeg produces, which is the whole
  point of the tag. What each file generates stays in that file's `setup_all`
  — the list is the file's subject. Only the argv is shared.

  ## The fixture root is unique per run, and that is a bug fix

  `root!/1` is the only way to get a fixture directory, and it always appends
  `System.unique_integer/1`. There is no opt-out, because the opt-out is what
  broke.

  This project's workflow is parallel worktrees, each with its own devcontainer,
  isolated by directory and port. `System.tmp_dir!()` is isolated by neither.
  Two files used to name fixed paths under it —
  `audio_proxy_render_fixtures/` and `audio_proxy_command_test_tone.wav` — and
  two concurrent `mix test --only ffmpeg` runs therefore shared them. The
  command fixture compounded it: it was cached on `File.exists?` and removed by
  `on_exit`, so one run deleted the file another run was caching on.

  It presents as a failure in a test with nothing wrong with it. Reproduced
  from two checkouts at once, first round:

      2) test every filter applies trim, fade, gain, norm and resample
         t:0:10/fade:0.5:1 exited 254: "Error opening input file
         /var/folders/…/T/audio_proxy_command_test_tone.wav.
         No such file or directory"

  Nothing in that test is about a missing file. The other run owned it.

  So: a generated fixture path is never a fixed name under
  `System.tmp_dir!()`. And a test that writes a file *in order to probe it*
  writes it to its own `:tmp_dir`, not into the module's fixture root — an
  output beside the inputs is the same collision with the file it truncates
  being the one under assertion.

  ## Two sine generators, because their amplitudes differ by 21 dB

  `tone/2` is `lavfi`'s bare `sine` source. It is **not full scale**: measured
  at -21.1 dB peak (ffmpeg 8.1.1, `volumedetect`), against 0.0 dB for a unit
  `aevalsrc`. That is fine for a test asking whether a transcode transcoded,
  and it is why `sine/2` exists for the tests that read the *signal*.

  `sine/2` takes its amplitude as an argument, and the number is the fixture's
  by construction. A peaks assertion against a source whose level came from an
  ffmpeg default would be asserting a version of ffmpeg rather than a contract.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @rate 44_100

  @doc """
  A fixture directory unique to this run, removed when the run ends.

  The label names the suite that made it, so a directory left behind by a
  crashed run says where it came from.
  """
  @spec root!(String.t()) :: Path.t()
  def root!(label) do
    root =
      Path.join(
        System.tmp_dir!(),
        "audio_proxy_#{label}_fixtures-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    root
  end

  @doc """
  Encodes a `lavfi` source to `path`, with `options` between input and output.

  The source expression and the output options both stay at the call site:
  they are what the five callers actually differ in, and folding either one in
  here would make this a switch statement over five files' needs.
  """
  @spec encode!(Path.t(), String.t(), [String.t()]) :: Path.t()
  def encode!(path, source, options \\ []) do
    ffmpeg!(["-f", "lavfi", "-i", source] ++ options ++ [path])

    path
  end

  @doc """
  A 440 Hz `lavfi` sine — the plain one, ~-21 dB, for tests about transcoding
  rather than about level. Pass `:amplitude` to `sine/2` instead when the test
  reads the signal.

  Options: `:duration` (required), `:frequency`, `:rate`, and `:extra` for
  output options this fixture needs beyond stereo at `:rate`.
  """
  @spec tone(Path.t(), keyword()) :: Path.t()
  def tone(path, opts) do
    duration = Keyword.fetch!(opts, :duration)
    frequency = Keyword.get(opts, :frequency, 440)
    rate = Keyword.get(opts, :rate, @rate)

    encode!(
      path,
      "sine=frequency=#{frequency}:duration=#{duration}:sample_rate=#{rate}",
      ["-ac", "2", "-ar", to_string(rate)] ++ Keyword.get(opts, :extra, [])
    )
  end

  @doc """
  A sine at a stated amplitude, via `aevalsrc` — 1.0 is full scale.

  Options: `:amplitude` and `:duration` (both required), `:frequency`, `:rate`,
  and `:extra`.
  """
  @spec sine(Path.t(), keyword()) :: Path.t()
  def sine(path, opts) do
    amplitude = Keyword.fetch!(opts, :amplitude)
    duration = Keyword.fetch!(opts, :duration)
    frequency = Keyword.get(opts, :frequency, 1_000)
    rate = Keyword.get(opts, :rate, @rate)

    encode!(
      path,
      "aevalsrc=#{amplitude}*sin(2*PI*#{frequency}*t):d=#{duration}:s=#{rate}:c=stereo",
      ["-ac", "2", "-ar", to_string(rate)] ++ Keyword.get(opts, :extra, [])
    )
  end

  @doc """
  Digital silence. Options: `:duration` (required), `:rate`, `:extra`.
  """
  @spec silence(Path.t(), keyword()) :: Path.t()
  def silence(path, opts) do
    duration = Keyword.fetch!(opts, :duration)
    rate = Keyword.get(opts, :rate, @rate)

    encode!(
      path,
      "anullsrc=r=#{rate}:cl=stereo:d=#{duration}",
      ["-ac", "2", "-ar", to_string(rate)] ++ Keyword.get(opts, :extra, [])
    )
  end

  @doc """
  A short video-plus-audio mp4.

  `mpeg4` rather than `libx264`: the native encoder is in every build, and what
  this fixture needs is a genuine video stream, not a particular codec.
  """
  @spec video(Path.t()) :: Path.t()
  def video(path) do
    ffmpeg!([
      "-f",
      "lavfi",
      "-i",
      "testsrc=duration=2:size=320x240:rate=10",
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:duration=2",
      "-c:v",
      "mpeg4",
      "-c:a",
      "aac",
      "-shortest",
      path
    ])

    path
  end

  @doc """
  An mp3 with a real attached picture — the cover art every tagged file in a
  catalogue carries, and the case the audio-only gate must not refuse.

  `scratch` is a directory to build the two inputs in; pass the fixture root.
  """
  @spec tagged_mp3(Path.t(), Path.t()) :: Path.t()
  def tagged_mp3(path, scratch) do
    audio = tone(Path.join(scratch, "cover-source.wav"), duration: 3)
    artwork = encode!(Path.join(scratch, "cover-art.png"), "color=c=red:s=64x64", ~w(-frames:v 1))

    ffmpeg!([
      "-i",
      audio,
      "-i",
      artwork,
      "-map",
      "0:a",
      "-map",
      "1:v",
      "-c:a",
      "libmp3lame",
      "-c:v",
      "copy",
      "-id3v2_version",
      "3",
      "-disposition:v",
      "attached_pic",
      path
    ])

    path
  end

  # `-nostdin` because a fixture is generated from a test process that owns no
  # terminal, and `-loglevel error` so a successful generation is silent —
  # which makes the exit status the whole contract, asserted here rather than
  # in five setup blocks.
  defp ffmpeg!(args) do
    {_output, 0} =
      System.cmd("ffmpeg", ["-nostdin", "-hide_banner", "-y", "-loglevel", "error"] ++ args,
        stderr_to_stdout: true
      )

    :ok
  end
end
