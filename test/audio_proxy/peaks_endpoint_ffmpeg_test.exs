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
  import AudioProxy.ConfigHelper

  alias AudioProxy.{RawHttp, Signature}

  @moduletag :ffmpeg
  @moduletag timeout: 120_000

  @key Base.decode16!("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")
  @salt Base.decode16!("FFEEDDCCBBAA99887766554433221100")

  @deadline 60_000

  # Full scale in the s16 domain, which is what `bits: 16` peaks are in.
  @full_scale 32_767

  # The fixtures' own amplitude, stated here rather than inherited from an
  # ffmpeg default — `lavfi`'s bare `sine` source is not full scale, and a test
  # asserting it was would be asserting a version of ffmpeg. `aevalsrc` takes
  # the amplitude as an argument, so the number below is the fixture's by
  # construction and the peaks have something exact to be compared against.
  @amplitude 0.9
  @expected_peak round(@amplitude * @full_scale)

  # ±5 % of full scale for a sine's own peaks (design.md's band), and 1 % for
  # "this is silence" — a lossless decode of digital silence is exactly zero,
  # but the band is what makes the assertion survive a fixture regenerated
  # through a lossy path.
  @signal_tolerance @full_scale * 0.05
  @silence_ceiling @full_scale * 0.01

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "audio_proxy_peaks_fixtures-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    # A 1 kHz sine at @amplitude, 4 s. Loud everywhere.
    generate(Path.join(root, "sine.wav"), sine(4))

    # 4 s of digital silence.
    generate(Path.join(root, "silence.wav"), "anullsrc=r=44100:cl=stereo:d=4")

    # Loud, except for the silent window t=0.5..2.5 — which comfortably
    # contains the second `t:1:1` selects, so a trim that is ignored shows up
    # as a loud waveform where a flat line belongs. The margin either side is
    # deliberate: a timeline filter mutes from the first *frame* past its
    # boundary, and ~20 ms of slop there is not what this test is about.
    generate(Path.join(root, "gap.wav"), sine(4), [
      "-af",
      "volume=enable='between(t,0.5,2.5)':volume=0"
    ])

    {:ok, root: root}
  end

  setup %{root: root, tmp_dir: tmp_dir} do
    store = Path.join(tmp_dir, "store")
    File.mkdir_p!(store)

    put_config(%{
      key: @key,
      salt: @salt,
      allow_insecure: false,
      local_root: root,
      max_src_bytes: 2_000_000_000,
      max_variant_bytes: 2_000_000_000,
      render_timeout: 60,
      variant_store: {:file, store},
      serve_mode: :proxy
    })

    reset_coordinators()

    bandit =
      start_supervised!(
        {Bandit, plug: AudioProxy.Router, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
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
      assert eventually(fn -> render(rest, port).head =~ "x-audio-proxy: hit" end)

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
      cover = Path.join(root, "cover.png")

      {_output, 0} =
        System.cmd(
          "ffmpeg",
          [
            "-y",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "color=c=red:s=16x16:d=1",
            "-frames:v",
            "1",
            cover
          ],
          stderr_to_stdout: true
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

  defp pairs(peaks) do
    peaks["data"] |> Enum.chunk_every(2) |> Enum.map(fn [min, max] -> {min, max} end)
  end

  defp etag(response) do
    Regex.run(~r/etag: (\S+)/, response.head) |> List.last()
  end

  defp render(rest, port) do
    "/#{Signature.sign(rest, @key, @salt)}#{rest}"
    |> RawHttp.get(port)
    |> RawHttp.read(@deadline)
  end

  defp eventually(check, attempts \\ 40) do
    cond do
      check.() -> true
      attempts <= 1 -> false
      true -> Process.sleep(50) && eventually(check, attempts - 1)
    end
  end

  defp sine(seconds) do
    "aevalsrc=#{@amplitude}*sin(2*PI*1000*t):d=#{seconds}:s=44100:c=stereo"
  end

  defp generate(path, source, extra \\ []) do
    {_output, 0} =
      System.cmd(
        "ffmpeg",
        ["-y", "-loglevel", "error", "-f", "lavfi", "-i", source] ++
          extra ++ ["-ac", "2", "-ar", "44100", path],
        stderr_to_stdout: true
      )
  end
end
