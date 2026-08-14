defmodule AudioProxy.PeaksEndpointFfmpegTest do
  @moduledoc """
  `f:peaks` end to end, against real ffmpeg and real ffprobe.

  The reduction itself is pinned by `AudioProxy.PeaksTest` on PCM built by
  hand; what only this test can show is that the two subprocesses agree with
  it — that the argv `AudioProxy.Ffmpeg.Command` writes really does produce
  `s16le` frames in the interleaving the reducer assumes, and that the probe's
  duration really does place buckets over the region the decode produced.
  Every assertion here is therefore about *signal*: a full-scale sine reaches
  full scale, silence stays at zero, and a trim moves the window.

  Tolerances rather than equalities, for the reason `AudioProxy.PeaksTest`
  does not need them: a WAV decode is exact, but ffmpeg's resampling and the
  sine generator's own phase are not something to pin to the last bit.

  Tagged `:ffmpeg` and not `:integration`, exactly as
  `AudioProxy.RenderEndpointFfmpegTest` is, and for the same reason.
  """

  use ExUnit.Case, async: false

  import AudioProxy.CoalesceHelper
  import AudioProxy.ProbeCoalesceHelper
  import AudioProxy.ConfigHelper
  import AudioProxy.SignedRequest
  import AudioProxy.Eventually

  alias AudioProxy.Fixtures
  alias AudioProxy.RawHttp
  alias AudioProxy.TestServer

  @moduletag :ffmpeg
  @moduletag timeout: 120_000

  @deadline 60_000

  # Full scale in the s16 domain, which is what `bits: 16` peaks are in.
  @full_scale 32_767

  # The fixtures' own amplitude, stated here rather than inherited from an
  # ffmpeg default, so the peaks have something exact to be compared against.
  # `AudioProxy.Fixtures.sine/2` is the generator that takes it as an argument,
  # and its moduledoc carries the measurement behind that choice.
  @amplitude 0.9
  @expected_peak round(@amplitude * @full_scale)

  # ±5 % of full scale for a sine's own peaks (design.md's band), and 1 % for
  # "this is silence" — a lossless decode of digital silence is exactly zero,
  # but the band is what makes the assertion survive a fixture regenerated
  # through a lossy path.
  @signal_tolerance @full_scale * 0.05
  @silence_ceiling @full_scale * 0.01

  setup_all do
    root = Fixtures.root!("peaks")

    # A 1 kHz sine at @amplitude, 4 s. Loud everywhere.
    sine(root, "sine.wav")

    # 4 s of digital silence.
    Fixtures.silence(Path.join(root, "silence.wav"), duration: 4)

    # Loud, except for the silent window t=0.5..2.5 — which comfortably
    # contains the second `t:1:1` selects, so a trim that is ignored shows up
    # as a loud waveform where a flat line belongs. The margin either side is
    # deliberate: a timeline filter mutes from the first *frame* past its
    # boundary, and ~20 ms of slop there is not what this test is about.
    sine(root, "gap.wav", ["-af", "volume=enable='between(t,0.5,2.5)':volume=0"])

    # Loud, then silent for the last 0.4 s — the one fixture shape that can see
    # a decode outrunning the reducer's budget. A steady tone cannot: a final
    # bucket that has absorbed the overrun is drawn from the same signal as
    # every other bucket, so it reads identically. With the tail silent, the
    # last bucket is silent only if the decode ended where the budget said it
    # would. Measured at 32 buckets over this fixture: 0 at the source's rate,
    # 5411 when the decode runs at 48 kHz against a 44.1 kHz budget.
    sine(root, "tail.wav", ["-af", "volume=enable='gte(t,3.6)':volume=0"])

    # Loud 40 Hz rumble, an octave below the preset's 80 Hz high-pass corner,
    # so `enhance:voice` has something unambiguous to remove from the picture.
    Fixtures.sine(Path.join(root, "rumble.wav"),
      amplitude: @amplitude,
      duration: 4,
      frequency: 40
    )

    {:ok, root: root}
  end

  setup %{root: root, tmp_dir: tmp_dir} do
    store = Path.join(tmp_dir, "store")
    File.mkdir_p!(store)

    put_config(
      base_config(
        local_root: root,
        render_timeout: 60,
        variant_store: {:file, store},
        serve_mode: :proxy
      )
    )

    reset_coordinators()
    reset_probes()

    %{port: port} = TestServer.start!(AudioProxy.Router)

    {:ok, port: port, store: store}
  end

  @moduletag tmp_dir: "peaks_endpoint"

  describe "the peaks response" do
    test "a sine reaches its own amplitude in every bucket", %{port: port} do
      peaks = json("/f:peaks/pts:64/plain/local://sine.wav", port)

      assert peaks["version"] == 2
      assert peaks["channels"] == 1
      assert peaks["bits"] == 16
      assert peaks["sample_rate"] == 44_100
      assert peaks["length"] == 64
      assert length(peaks["data"]) == 64 * 2

      for {min, max} <- pairs(peaks) do
        assert_in_delta min, -@expected_peak, @signal_tolerance
        assert_in_delta max, @expected_peak, @signal_tolerance
      end
    end

    test "silence is pairs of ~0", %{port: port} do
      peaks = json("/f:peaks/pts:32/plain/local://silence.wav", port)

      for {min, max} <- pairs(peaks) do
        assert abs(min) < @silence_ceiling
        assert abs(max) < @silence_ceiling
      end
    end

    test "a trim selects the region the peaks are drawn from", %{port: port} do
      silent_window = json("/f:peaks/pts:32/t:1:1/plain/local://gap.wav", port)
      whole_file = json("/f:peaks/pts:32/plain/local://gap.wav", port)

      # The trimmed second is the silent one, all of it.
      for {min, max} <- pairs(silent_window) do
        assert abs(min) < @silence_ceiling
        assert abs(max) < @silence_ceiling
      end

      # And the same fixture untrimmed is loud, which is what makes the above
      # a statement about the trim rather than about the fixture.
      assert Enum.any?(pairs(whole_file), fn {_min, max} ->
               max > @expected_peak - @signal_tolerance
             end)
    end

    # The waveform is drawn under audio the listener hears, so a processed
    # render has to move the picture. `enhance:voice` is the case that makes it
    # visible: its high-pass removes the fixture's entire signal.
    test "the enhance preset changes the picture, without moving the buckets", %{port: port} do
      plain = json("/f:peaks/pts:32/plain/local://rumble.wav", port)
      enhanced = json("/f:peaks/pts:32/enhance:voice/plain/local://rumble.wav", port)

      assert Enum.any?(pairs(plain), fn {_min, max} ->
               max > @expected_peak - @signal_tolerance
             end)

      for {min, max} <- pairs(enhanced) do
        assert abs(min) < @expected_peak / 2
        assert abs(max) < @expected_peak / 2
      end

      # And the bucket budget is untouched, which is what makes every filter
      # safe here: the chain preserves the frame count `Peaks.Render` budgeted
      # from the probe. A chain that re-rated the decode would show up here as a
      # different span.
      assert enhanced["samples_per_pixel"] == plain["samples_per_pixel"]
      assert enhanced["sample_rate"] == plain["sample_rate"]
      assert length(enhanced["data"]) == length(plain["data"])
    end

    # `gain` is arithmetic on every sample, so the picture scales with it and
    # nothing else moves. Both halves are asserted: a waveform that ignored
    # `gain` would sit under a player that did not.
    test "gain scales the picture and leaves the buckets alone", %{port: port} do
      plain = json("/f:peaks/pts:32/plain/local://sine.wav", port)
      quieter = json("/f:peaks/pts:32/gain:-6/plain/local://sine.wav", port)

      # −6 dB is a factor of 0.501, and the source is a sine at a known
      # amplitude, so this is an equality within the sine's own band.
      for {min, max} <- pairs(quieter) do
        assert_in_delta min, -@expected_peak / 2, @signal_tolerance
        assert_in_delta max, @expected_peak / 2, @signal_tolerance
      end

      assert_same_buckets(quieter, plain)
    end

    # The case the rate fix was for. Single-pass `loudnorm` hands its output
    # back at 192 kHz, and the reducer budgets its buckets from the source's
    # probed rate — so before `AudioProxy.Ffmpeg.Command` resampled back to that
    # rate, the decode outran the budget and the overrun folded into the final
    # bucket as a spike, under a header still claiming the source's rate.
    test "a normalized render draws a normalized waveform over the same buckets",
         %{port: port} do
      plain = json("/f:peaks/pts:32/plain/local://sine.wav", port)
      normalized = json("/f:peaks/pts:32/norm:ebu/plain/local://sine.wav", port)

      # A full-amplitude 1 kHz sine measures near −4 LUFS, so normalizing it to
      # −16 attenuates by roughly 12 dB. Bounded on both sides rather than
      # pinned: single-pass loudnorm is an estimate, and what this asserts is
      # that the normalization reached the picture at all.
      loudest = normalized["data"] |> Enum.map(&abs/1) |> Enum.max()

      assert loudest < @expected_peak / 2
      assert loudest > @silence_ceiling

      assert_same_buckets(normalized, plain)
    end

    # The scenario the rate fix is *for*, and the only assertion in this file
    # that can see it fail. `loudnorm` emits 192 kHz; without the resample back
    # to the source's rate the decode runs 8.8 % long against a budget computed
    # before it started, and the surplus folds into the final bucket — audio
    # from a region the last pixel does not cover, drawn as if it did.
    #
    # `tail.wav` is silent for its last 0.4 s, so the final bucket is silent
    # exactly when the decode ended where the budget said. Deliberately not the
    # steady sine: that fixture reads identically either way, which is how this
    # guarantee went unguarded end to end in the first place.
    test "a normalized decode ends where the reducer budgeted, not past it",
         %{port: port} do
      normalized = json("/f:peaks/pts:32/norm:ebu/plain/local://tail.wav", port)
      plain = json("/f:peaks/pts:32/plain/local://tail.wav", port)

      {last_min, last_max} = normalized |> pairs() |> List.last()

      assert abs(last_min) < @silence_ceiling
      assert abs(last_max) < @silence_ceiling

      # And the fixture is loud where it should be, so the assertion above is
      # about the budget rather than about a silent file.
      assert Enum.any?(pairs(normalized), fn {_min, max} -> max > @silence_ceiling * 10 end)
      assert_same_buckets(normalized, plain)
    end

    test "samples_per_pixel spans the trimmed region, not the whole source", %{port: port} do
      peaks = json("/f:peaks/pts:100/t:0:2/plain/local://sine.wav", port)

      # 2 s at 44.1 kHz over 100 pixels.
      assert peaks["samples_per_pixel"] == 882
    end

    test "ch:2 gives per-channel pairs and keeps them interleaved", %{port: port} do
      peaks = json("/f:peaks/pts:16/ch:2/plain/local://sine.wav", port)

      assert peaks["channels"] == 2
      assert length(peaks["data"]) == 16 * 2 * 2

      # A generated sine is the same signal on both channels, so the two
      # channels' pairs have to agree — which they only can if the reducer read
      # the interleaving the way ffmpeg wrote it.
      #
      # A *list* pattern, deliberately. `for <<a, b, c, d>> <- list` is a
      # binary generator: every element of a list of lists fails the pattern
      # and is silently filtered, so the version of this loop that used one
      # ran zero times and asserted nothing while passing.
      channel_pairs = Enum.chunk_every(peaks["data"], 4)
      assert length(channel_pairs) == 16

      for [left_min, left_max, right_min, right_max] <- channel_pairs do
        assert_in_delta left_min, right_min, @signal_tolerance
        assert_in_delta left_max, right_max, @signal_tolerance
      end

      # The loop above is comparing channels, so it would also pass on all
      # zeros. This is what says there is a waveform in there at all.
      assert Enum.any?(peaks["data"], &(abs(&1) > @expected_peak - @signal_tolerance))
    end
  end

  describe "the two serializations" do
    test "json and dat carry the same numbers", %{port: port} do
      peaks = json("/f:peaks/pts:48/plain/local://sine.wav", port)
      response = render("/f:peaks/pts:48/pk_fmt:dat/plain/local://sine.wav", port)

      assert response.head =~ "content-type: application/octet-stream"

      body = RawHttp.dechunk(response.body)

      assert <<
               version::little-signed-32,
               _flags::little-unsigned-32,
               sample_rate::little-signed-32,
               samples_per_pixel::little-signed-32,
               length::little-unsigned-32,
               channels::little-signed-32,
               data::binary
             >> = body

      assert version == peaks["version"]
      assert sample_rate == peaks["sample_rate"]
      assert samples_per_pixel == peaks["samples_per_pixel"]
      assert length == peaks["length"]
      assert channels == peaks["channels"]

      assert for(<<value::little-signed-16 <- data>>, do: value) == peaks["data"]
    end
  end

  describe "peaks in the cache" do
    test "the second request for the same peaks URL is a HIT", %{port: port} do
      rest = "/f:peaks/pts:32/plain/local://sine.wav"

      first = render(rest, port)
      assert first.head =~ "x-audio-proxy: miss"

      # The write-back is a subscriber to the same render, so it may still be
      # finishing when the first response is complete.
      #
      # Each attempt is a full render through ffmpeg and ffprobe, so this budget
      # is several renders, not several polls — the deadline it replaced counted
      # 40 attempts, not 2 s of wall clock.
      assert eventually?(fn -> render(rest, port).head =~ "x-audio-proxy: hit" end, 10_000)

      second = render(rest, port)

      assert second.head =~ "x-audio-proxy: hit"
      assert second.head =~ "content-type: application/json"
      assert JSON.decode!(body(second)) == JSON.decode!(body(first))
    end

    test "a peaks URL and the audio URL beside it are different variants", %{port: port} do
      peaks = render("/f:peaks/pts:32/plain/local://sine.wav", port)
      audio = render("/f:mp3/br:64/t:0:1/plain/local://sine.wav", port)

      assert peaks.head =~ "content-type: application/json"
      assert audio.head =~ "content-type: audio/mpeg"
      refute etag(peaks) == etag(audio)
    end
  end

  describe "failures" do
    test "a source ffprobe cannot read fails before any decode", %{port: port, root: root} do
      File.write!(Path.join(root, "notaudio.txt"), "definitely not audio")

      response = render("/f:peaks/plain/local://notaudio.txt", port)

      assert response.head =~ "http/1.1 415"
      assert JSON.decode!(response.body)["error"] == "undecodable_source"
    end

    # This test's expectation moved when `add-audio-only-policy` merged, and the
    # divergence it used to record is the thing that closed.
    #
    # It read: peaks answer 415 `undecodable_source` for a file with no audio
    # stream, while the audio path answers **500** for the same file, because
    # ffmpeg says "Output file does not contain any stream" and no classifier
    # matches it — a gap belonging to the audio-only-policy slice.
    #
    # The gate closed it from the other side. A bare PNG is a video-typed stream
    # with `attached_pic: 0` and no `nb_frames`, so it is not exempt as cover
    # art, and the probe refuses it before either pipeline starts: both paths now
    # answer 415 `video_source`. That is the honest reason — ffmpeg models a PNG
    # as video, and this proxy does not serve video — and it is the same answer a
    # video-only MP4 gets, which is the consistency the policy is for. Both
    # halves are asserted below so the convergence stays pinned.
    test "a source with no audio stream is refused the same way on both paths",
         %{port: port, root: root} do
      cover =
        Fixtures.encode!(
          Path.join(root, "cover.png"),
          "color=c=red:s=16x16:d=1",
          ~w(-frames:v 1)
        )

      peaks = render("/f:peaks/plain/local://cover.png", port)

      assert peaks.head =~ "http/1.1 415"
      assert JSON.decode!(peaks.body)["error"] == "video_source"

      # The half that used to be a 500.
      audio = render("/f:mp3/plain/local://cover.png", port)

      assert audio.head =~ "http/1.1 415"
      assert JSON.decode!(audio.body)["error"] == "video_source"
    end
  end

  ## Helpers

  defp json(rest, port), do: rest |> render(port) |> body() |> JSON.decode!()

  # A MISS is chunked and a HIT is not — §5's two framings — so a test that
  # compares the two has to read both. Anything else would be comparing a
  # cached variant against an empty string and passing.
  defp body(%{head: head, body: body}) do
    if head =~ "transfer-encoding: chunked", do: RawHttp.dechunk(body), else: body
  end

  # What must not move when a filter changes the samples: the grid the pairs are
  # drawn over, and the rate the header says they describe.
  defp assert_same_buckets(processed, plain) do
    assert processed["samples_per_pixel"] == plain["samples_per_pixel"]
    assert processed["sample_rate"] == plain["sample_rate"]
    assert processed["length"] == plain["length"]
    assert length(processed["data"]) == length(plain["data"])
  end

  defp pairs(peaks) do
    peaks["data"] |> Enum.chunk_every(2) |> Enum.map(fn [min, max] -> {min, max} end)
  end

  defp etag(response) do
    Regex.run(~r/etag: (\S+)/, response.head) |> List.last()
  end

  defp render(rest, port) do
    signed(rest)
    |> RawHttp.get(port)
    |> RawHttp.read(@deadline)
  end

  # `@amplitude` is passed, never defaulted: `AudioProxy.Fixtures.sine/2` takes
  # it as an argument precisely so these assertions are about the contract
  # rather than about an ffmpeg default. See that module's moduledoc.
  defp sine(root, name, extra \\ []) do
    Fixtures.sine(Path.join(root, name),
      amplitude: @amplitude,
      duration: 4,
      extra: extra
    )
  end
end
