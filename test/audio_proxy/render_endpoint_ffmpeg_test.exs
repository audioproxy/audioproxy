defmodule AudioProxy.RenderEndpointFfmpegTest do
  @moduledoc """
  The whole thing, for real: a signed URL in, a file `ffprobe` agrees is the
  variant that was asked for out.

  Everywhere else the encoder is a stand-in, because the HTTP lifecycle is a
  property of the action rather than of ffmpeg
  (`AudioProxy.RenderEndpointStreamTest` explains the split). This is the test
  that would catch the two things a stand-in cannot: argv that ffmpeg refuses,
  and bytes that are not the format the `Content-Type` claims. It runs the
  production `AudioProxy.Router`, over Bandit, with `AP_LOCAL_ROOT` pointed at
  fixtures this module generates.

  Tagged `:ffmpeg` and *not* `:integration`, even though it binds a socket:
  the tags are exclusion filters, and an include of one would drag this into
  the CI job that has no ffmpeg installed.
  """

  use ExUnit.Case, async: false

  import AudioProxy.CoalesceHelper
  import AudioProxy.ProbeCoalesceHelper
  import AudioProxy.ConfigHelper
  import AudioProxy.SignedRequest

  alias AudioProxy.Fixtures
  alias AudioProxy.RawHttp
  alias AudioProxy.TestServer

  @moduletag :ffmpeg

  # Probed responses are written here, one directory per test.
  @moduletag tmp_dir: "render_endpoint"

  # Encoding the long fixture is what the streaming assertions need to be
  # slower than a single mailbox round trip; 60 s is the ExUnit default.
  @moduletag timeout: 120_000

  @deadline 60_000

  # A 440 Hz sine, which is all a transcode needs to be a transcode, and a much
  # longer one for the timing assertion. Both are generated once for the module
  # — a ten-minute WAV is ~100 MB, and writing it per test would dominate the
  # run.
  setup_all do
    root = Fixtures.root!("render_endpoint")

    Fixtures.tone(Path.join(root, "piece.wav"), duration: 5)
    Fixtures.tone(Path.join(root, "long.wav"), duration: 600)
    File.write!(Path.join(root, "notaudio.txt"), "definitely not audio")

    # The audio-only gate's two halves, generated rather than committed so the
    # fixtures are what this ffmpeg produces: a real video-plus-audio mp4, and a
    # real mp3 carrying real cover art. Canned ffprobe JSON pins the *mapping*
    # elsewhere; only these say the mapping matches what the binary emits.
    Fixtures.video(Path.join(root, "video.mp4"))
    Fixtures.tagged_mp3(Path.join(root, "cover.mp3"), root)

    {:ok, root: root}
  end

  setup %{root: root} do
    put_config(base_config(local_root: root, render_timeout: 60))

    reset_coordinators()
    reset_probes()

    %{port: port} = TestServer.start!(AudioProxy.Router)

    {:ok, port: port}
  end

  describe "end-to-end render" do
    test "a trimmed mp3 arrives as a decodable mp3 of the requested length",
         %{port: port, tmp_dir: tmp_dir} do
      response = render("/f:mp3/br:128/t:0:2/plain/local://piece.wav", port)

      assert response.head =~ "http/1.1 200 ok"
      assert response.head =~ "content-type: audio/mpeg"

      audio = RawHttp.dechunk(response.body)
      assert RawHttp.complete?(response.body)

      probe = probe(audio, "mp3", tmp_dir)
      assert probe["format"]["format_name"] =~ "mp3"
      assert_in_delta String.to_float(probe["format"]["duration"]), 2.0, 0.2
    end

    test "the same source renders as Opus when the options say so",
         %{port: port, tmp_dir: tmp_dir} do
      response = render("/f:opus/br:96/t:0:2/plain/local://piece.wav", port)

      assert response.head =~ "content-type: audio/ogg"

      probe = probe(RawHttp.dechunk(response.body), "ogg", tmp_dir)
      assert probe["streams"] |> hd() |> Map.fetch!("codec_name") == "opus"
    end

    test "the §5 headers describe the variant, dl included", %{port: port} do
      rest = "/f:mp3/t:0:2/dl:preview.mp3/plain/local://piece.wav"
      response = render(rest, port)

      key = AudioProxy.CacheKey.derive!("f:mp3/t:0:2/dl:preview.mp3", "local://piece.wav")

      assert response.head =~ "content-type: audio/mpeg"
      assert response.head =~ "cache-control: public, max-age=31536000, immutable"
      assert response.head =~ ~s(etag: "#{key}")
      assert response.head =~ "x-audio-proxy: miss"
      assert response.head =~ ~s(content-disposition: attachment; filename="preview.mp3")

      # §5: chunked, so neither of these may be present.
      refute response.head =~ "content-length:"
      refute response.head =~ "accept-ranges:"
    end

    test "bytes arrive long before the render finishes", %{port: port} do
      # The ten-minute source takes seconds to encode. If the response were
      # buffered, the first byte and the last would land together.
      response = render("/f:mp3/plain/local://long.wav", port)

      assert response.head =~ "http/1.1 200 ok"
      assert RawHttp.complete?(response.body)

      streamed_for = response.closed_at - response.first_byte_at

      assert streamed_for > 500,
             "the whole response arrived within #{streamed_for}ms, which is what buffering looks like"
    end

    test "a second client for the same variant shares one ffmpeg", %{port: port} do
      # The ten-minute source is what makes the overlap real: the second
      # request lands while ffmpeg is still encoding, so it exercises the
      # backlog-then-live seam rather than the post-completion linger.
      rest = "/f:mp3/plain/local://long.wav"
      path = signed(rest)

      first = Task.async(fn -> path |> RawHttp.get(port) |> RawHttp.read(@deadline) end)
      Process.sleep(500)
      second = Task.async(fn -> path |> RawHttp.get(port) |> RawHttp.read(@deadline) end)

      first = Task.await(first, @deadline)
      second = Task.await(second, @deadline)

      assert first.head =~ "x-audio-proxy: miss"
      assert second.head =~ "x-audio-proxy: coalesced"

      assert RawHttp.complete?(first.body)
      assert RawHttp.complete?(second.body)

      # The whole point, stated in bytes: the joiner's stream is the starter's
      # stream, not a second encode that merely resembles it.
      assert RawHttp.dechunk(second.body) == RawHttp.dechunk(first.body)
    end

    test "a source neither binary can read is a 415", %{port: port} do
      # Named for what it now proves. Before the audio-only gate this was
      # ffmpeg's verdict, reached while decoding; with the gate live, real
      # ffprobe refuses a text file first and ffmpeg never runs. Same status and
      # same `error`, so the client contract is unchanged — but the encoder's own
      # classification path is exercised by `AudioProxy.Ffmpeg.RenderTest`
      # against its stderr patterns, not here, and a test claiming otherwise
      # would be claiming coverage it does not have.
      response = render("/f:mp3/plain/local://notaudio.txt", port)

      assert response.head =~ "http/1.1 415"
      assert JSON.decode!(response.body)["error"] == "undecodable_source"
    end
  end

  describe "the audio-only gate, against the real prober" do
    test "an mp4 carrying video is refused, and nothing is encoded", %{port: port} do
      response = render("/f:mp3/plain/local://video.mp4", port)

      assert response.head =~ "http/1.1 415"
      assert JSON.decode!(response.body)["error"] == "video_source"

      # The refusal is the gate's, not the encoder's: extracting the audio track
      # is precisely what this policy exists not to do.
      refute JSON.decode!(response.body)["error"] == "undecodable_source"
    end

    test "an mp3 with embedded cover art renders", %{port: port, tmp_dir: tmp_dir} do
      # The other half, and the reason the gate cannot simply refuse every
      # video-typed stream: real ffprobe reports this file's artwork as a video
      # stream, and virtually every tagged mp3 in a real catalogue has one.
      response = render("/f:mp3/br:96/t:0:2/plain/local://cover.mp3", port)

      assert response.head =~ "http/1.1 200 ok"
      assert RawHttp.complete?(response.body)

      audio = RawHttp.dechunk(response.body)
      assert probe(audio, "mp3", tmp_dir)["format"]["format_name"] =~ "mp3"
    end

    test "the fixture really is what the test claims: cover art, not video",
         %{root: root} do
      # A tripwire on the fixture itself. If a future ffmpeg stops writing the
      # `attached_pic` disposition, the test above would go green for the wrong
      # reason — the gate would be exempting it as a single-frame image, or the
      # mp3 would have no artwork at all.
      streams = probe_file(Path.join(root, "cover.mp3"))["streams"]

      assert Enum.any?(streams, &(&1["codec_type"] == "audio"))

      assert Enum.any?(streams, fn stream ->
               stream["codec_type"] == "video" and stream["disposition"]["attached_pic"] == 1
             end)

      assert AudioProxy.Ffprobe.has_video?(probe_file(Path.join(root, "video.mp4")))
      refute AudioProxy.Ffprobe.has_video?(probe_file(Path.join(root, "cover.mp3")))
    end
  end

  defp render(rest, port) do
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

  # ffprobe reads a file rather than a pipe here on purpose: seeking is how it
  # reads a container's index, and a piped mp3 reports no duration.
  #
  # The bytes land in the test's own `:tmp_dir`, never beside the fixtures and
  # never at a name under the system temp dir: a response written out to be
  # probed is an output, and an output two runs can collide on is the sharper
  # half of the bug `AudioProxy.Fixtures` documents.
  defp probe(audio, extension, tmp_dir) do
    path = Path.join(tmp_dir, "probe.#{extension}")

    File.write!(path, audio)

    probe_file(path)
  end
end
