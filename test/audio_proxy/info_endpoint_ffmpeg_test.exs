defmodule AudioProxy.InfoEndpointFfmpegTest do
  @moduledoc """
  The info endpoint for real: a signed URL in, `ffprobe`'s own account of a
  generated fixture out.

  `AudioProxy.FfprobeTest` pins the mapping against canned output, which is
  what makes it exhaustive across containers; this is what keeps that canned
  output honest. It is the only test that would catch the two things a fixture
  cannot: ffprobe renaming or dropping a field, and argv it refuses.

  Tagged `:ffmpeg` and not `:integration`, for the reason
  `AudioProxy.RenderEndpointFfmpegTest` gives — the tags are exclusion filters,
  and including one would drag this into the CI job with no ffmpeg installed.
  """

  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper

  alias AudioProxy.{RawHttp, Signature}

  @moduletag :ffmpeg
  @moduletag timeout: 120_000

  @key Base.decode16!("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")
  @salt Base.decode16!("FFEEDDCCBBAA99887766554433221100")

  @duration 3

  # One fixture per container the contract has a rule about, generated once:
  # what differs between them is exactly what the mapping has to absorb.
  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "audio_proxy_info_fixtures-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    encode(root, "piece.wav", ~w(-ar 48000 -ac 2 -c:a pcm_s16le))

    encode(
      root,
      "deep.flac",
      ~w(-ar 44100 -ac 2 -c:a flac -sample_fmt s32 -bits_per_raw_sample 24)
    )

    encode(root, "piece.mp3", ~w(-ar 44100 -ac 2 -c:a libmp3lame -b:a 128k))
    encode(root, "piece.opus", ~w(-ac 2 -c:a libopus -b:a 96k))
    encode(root, "surround.wav", ~w(-ar 96000 -ac 6 -c:a pcm_s24le))

    encode(
      root,
      "tagged.mp3",
      ~w(-ar 44100 -ac 2 -c:a libmp3lame -b:a 128k) ++
        ~w(-metadata title=SeaChange -metadata artist=TestArtist)
    )

    File.write!(Path.join(root, "notaudio.txt"), "definitely not audio")

    {:ok, root: root}
  end

  setup %{root: root} do
    put_config(%{
      key: @key,
      salt: @salt,
      allow_insecure: false,
      local_root: root,
      max_src_bytes: 2_000_000_000,
      probe_timeout: 30
    })

    bandit =
      start_supervised!(
        {Bandit, plug: AudioProxy.Router, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    {:ok, port: port}
  end

  describe "the §4 contract, from the real prober" do
    test "a WAV reports format, duration, rate, channels, depth and size", ctx do
      info = info("piece.wav", ctx)

      assert info["format"] == "wav"
      assert_in_delta info["duration"], @duration, 0.1
      assert info["sample_rate"] == 48_000
      assert info["channels"] == 2
      assert info["bit_depth"] == 16
      assert info["size"] == size("piece.wav", ctx)
    end

    test "a 24-bit FLAC reports its real depth, not its sample format", ctx do
      info = info("deep.flac", ctx)

      assert info["format"] == "flac"
      assert info["bit_depth"] == 24
    end

    test "an mp3 has a bitrate and no bit depth", ctx do
      info = info("piece.mp3", ctx)

      assert info["format"] == "mp3"
      assert info["bitrate"] > 0
      refute Map.has_key?(info, "bit_depth")
    end

    test "opus in Ogg reports the API's own token", ctx do
      assert info("piece.opus", ctx)["format"] == "opus"
    end

    test "a multichannel source reports every channel", ctx do
      info = info("surround.wav", ctx)

      assert info["channels"] == 6
      assert info["sample_rate"] == 96_000
      assert info["bit_depth"] == 24
    end

    test "tags carried by the source appear under tags", ctx do
      info = info("tagged.mp3", ctx)

      assert info["tags"]["title"] == "SeaChange"
      assert info["tags"]["artist"] == "TestArtist"
    end
  end

  describe "caching and errors, against the real prober" do
    test "the ETag round-trips as a 304", ctx do
      first = request("/info/plain/local://piece.wav", ctx)

      assert first.head =~ "http/1.1 200 ok"
      assert etag = header(first.head, "etag")

      second = request("/info/plain/local://piece.wav", ctx, headers: [{"if-none-match", etag}])

      assert second.head =~ "http/1.1 304 not modified"
    end

    test "a text file is 415 with a JSON error", ctx do
      response = request("/info/plain/local://notaudio.txt", ctx)

      assert response.head =~ "http/1.1 415"
      assert JSON.decode!(response.body)["error"] == "undecodable_source"
    end

    test "options with info are 422 before ffprobe is reached", ctx do
      response = request("/info/br:128/plain/local://piece.wav", ctx)

      assert response.head =~ "http/1.1 422"
      assert JSON.decode!(response.body)["error"] == "invalid_options"
    end
  end

  ## Helpers

  defp info(fixture, ctx) do
    response = request("/info/plain/local://#{fixture}", ctx)

    assert response.head =~ "http/1.1 200 ok"
    JSON.decode!(response.body)
  end

  # Info responses are `Content-Length`-framed, never chunked, so `read_one/1`
  # is the right reader: it stops at the declared length rather than waiting on
  # the close, which keeps a wrong length visible as a hang rather than hidden.
  defp request(rest, %{port: port}, opts \\ []) do
    "/#{Signature.sign(rest, @key, @salt)}#{rest}"
    |> RawHttp.get(port, opts)
    |> RawHttp.read_one()
  end

  defp size(fixture, %{root: root}) do
    File.stat!(Path.join(root, fixture)).size
  end

  defp header(head, name) do
    case Regex.run(~r/^#{name}: (.*)$/mi, head) do
      [_whole, value] -> String.trim(value)
      nil -> nil
    end
  end

  defp encode(root, name, args) do
    {_output, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -loglevel error -f lavfi -i sine=frequency=440:duration=#{@duration}) ++
          args ++ [Path.join(root, name)],
        stderr_to_stdout: true
      )
  end
end
