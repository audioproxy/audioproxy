defmodule AudioProxy.VideoPolicyFfmpegTest do
  @moduledoc """
  The `:extract` verdict against the real binaries: a genuine video mp4 in, an
  mp3 of its audio track out, and `/info` describing that track.

  `AudioProxy.VideoPolicyTest` pins the seam against hand-built probe maps,
  which is what makes it exhaustive; this is what keeps it honest, and it is
  the only place OSS runs the second verdict end to end. Two things a unit test
  cannot say are said here: ffmpeg accepts the argv for a source it has to
  demux video out of, and the bytes that come back carry no video stream —
  the egress guarantee observed in the output rather than inferred from the
  argv.

  The policy is installed through application env, which is the whole point of
  the seam. Nothing in `lib/` selects a module but the default, so this file is
  the only producer in the repository.

  Tagged `:ffmpeg` and not `:integration`, for the reason
  `AudioProxy.RenderEndpointFfmpegTest` gives — the tags are exclusion filters,
  and including one would drag this into the CI job with no ffmpeg installed.
  """

  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper
  import AudioProxy.SignedRequest
  import AudioProxy.CoalesceHelper
  import AudioProxy.ProbeCoalesceHelper

  alias AudioProxy.Fixtures
  alias AudioProxy.RawHttp
  alias AudioProxy.TestServer

  @moduletag :ffmpeg
  @moduletag tmp_dir: "video_policy"
  @moduletag timeout: 120_000

  @deadline 60_000

  defmodule ExtractPolicy do
    @moduledoc false
    @behaviour AudioProxy.VideoPolicy

    @impl true
    def verdict(_probe), do: :extract
  end

  setup_all do
    root = Fixtures.root!("video_policy")

    # The same generator `AudioProxy.RenderEndpointFfmpegTest` refuses: a real
    # mpeg4 video track alongside a real aac audio track, with no
    # `attached_pic` disposition anywhere in it.
    Fixtures.video(Path.join(root, "video.mp4"))

    {:ok, root: root}
  end

  setup %{root: root} do
    put_config(base_config(local_root: root, render_timeout: 60, probe_timeout: 30))

    Application.put_env(:audio_proxy, :video_policy, ExtractPolicy)
    on_exit(fn -> Application.delete_env(:audio_proxy, :video_policy) end)

    reset_coordinators()
    reset_probes()

    %{port: port} = TestServer.start!(AudioProxy.Router)

    {:ok, port: port}
  end

  describe "the :extract verdict, against the real binaries" do
    test "a video mp4 renders as an mp3 of its audio track", %{port: port, tmp_dir: tmp_dir} do
      response = request("/f:mp3/br:96/plain/local://video.mp4", port)

      assert response.head =~ "http/1.1 200 ok"
      assert response.head =~ "content-type: audio/mpeg"
      assert RawHttp.complete?(response.body)

      probe = probe(RawHttp.dechunk(response.body), "mp3", tmp_dir)

      assert probe["format"]["format_name"] =~ "mp3"

      # The fixture is two seconds of 440 Hz under two seconds of `testsrc`;
      # what came back is the audio, at the length the audio had.
      assert_in_delta String.to_float(probe["format"]["duration"]), 2.0, 0.3
    end

    test "the rendered bytes carry no video stream", %{port: port, tmp_dir: tmp_dir} do
      # The egress guarantee, observed. `-vn -sn -dn` is in every argv whatever
      # the verdict, and this is that claim measured on the output rather than
      # read off the command builder: an extraction that shipped the video
      # track would be the seam having reached a layer it must not.
      response = request("/f:mp3/br:96/plain/local://video.mp4", port)

      streams = probe(RawHttp.dechunk(response.body), "mp3", tmp_dir)["streams"]

      assert Enum.any?(streams, &(&1["codec_type"] == "audio"))
      refute Enum.any?(streams, &(&1["codec_type"] == "video"))
    end

    test "/info describes the audio stream", %{port: port} do
      response =
        signed("/info/plain/local://video.mp4")
        |> RawHttp.get(port)
        |> RawHttp.read_one()

      assert response.head =~ "http/1.1 200 ok"

      info = JSON.decode!(response.body)

      # §4's object describes an audio stream and has no vocabulary for any
      # other kind, so "describes the audio" is what the contract's own fields
      # mean: a rate, a channel count and a duration the aac track has.
      assert info["sample_rate"] > 0
      assert info["channels"] > 0
      assert_in_delta info["duration"], 2.0, 0.3

      # The mp4 family's API token, per §3.1 — the container is described as
      # itself, which is not the same as the proxy offering to emit video.
      assert info["format"] == "m4a"
    end

    test "the fixture really is video, so the tests above mean what they claim",
         %{root: root} do
      # The tripwire `AudioProxy.RenderEndpointFfmpegTest` carries for the
      # other direction. If a future ffmpeg wrote this file with an
      # `attached_pic` video stream, every assertion here would go green
      # without the policy ever having been consulted.
      streams = probe_file(Path.join(root, "video.mp4"))["streams"]

      assert Enum.any?(streams, fn stream ->
               stream["codec_type"] == "video" and stream["disposition"]["attached_pic"] != 1
             end)

      assert AudioProxy.Ffprobe.has_video?(probe_file(Path.join(root, "video.mp4")))
    end
  end

  ## Helpers

  defp request(rest, port) do
    signed(rest)
    |> RawHttp.get(port)
    |> RawHttp.read(@deadline)
  end

  defp probe_file(path) do
    {json, 0} =
      System.cmd("ffprobe", [
        "-v",
        "error",
        "-print_format",
        "json",
        "-show_format",
        "-show_streams",
        path
      ])

    JSON.decode!(json)
  end

  # Written to the test's own `:tmp_dir` and probed from a file rather than a
  # pipe, for the reason `AudioProxy.RenderEndpointFfmpegTest` states: seeking
  # is how ffprobe reads a container's index, and a response written out to be
  # probed is an output, never a fixture.
  defp probe(audio, extension, tmp_dir) do
    path = Path.join(tmp_dir, "probe.#{extension}")

    File.write!(path, audio)

    probe_file(path)
  end
end
