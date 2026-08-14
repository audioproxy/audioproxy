defmodule AudioProxy.VideoPolicyTest do
  @moduledoc """
  The verdict seam, both of its values, and the two things it must not be able
  to reach.

  The *default* is not tested here beyond a unit assertion, and deliberately:
  what pins it is `AudioProxy.RenderEndpointFfmpegTest` and
  `AudioProxy.InfoEndpointFfmpegTest` continuing to answer 415 for a video
  source without either file having been edited for this seam. A new test
  asserting "the default rejects" would pass just as happily against a gate
  that had quietly grown a second behaviour; the untouched suite is the
  stronger claim.

  What this file adds is the half OSS otherwise ships unexercised — `:extract`,
  reachable only through an application env no `AP_` variable writes — and the
  boundary either side of it: a policy is asked about video and nothing else,
  and its answer changes what is *admitted* without reaching what is *emitted*.
  """

  use ExUnit.Case, async: false

  import AudioProxy.ConfigHelper
  import ExUnit.CaptureLog

  alias AudioProxy.Ffmpeg.Command
  alias AudioProxy.{Options, VideoPolicy}

  doctest AudioProxy.VideoPolicy

  defmodule ExtractPolicy do
    @moduledoc false
    @behaviour VideoPolicy

    @impl true
    def verdict(_probe), do: :extract
  end

  defmodule RaisingPolicy do
    @moduledoc false
    @behaviour VideoPolicy

    @impl true
    def verdict(_probe), do: raise("a policy was consulted about an audio-only source")
  end

  defmodule NonsensePolicy do
    @moduledoc false
    @behaviour VideoPolicy

    @impl true
    def verdict(_probe), do: :transcode_the_video
  end

  # Application env rather than `put_config/1`: that is the whole point of the
  # seam, and a test that installed it through the `AP_` surface would be
  # asserting the opposite of what the change decided.
  defp put_policy(module) do
    Application.put_env(:audio_proxy, :video_policy, module)
    on_exit(fn -> Application.delete_env(:audio_proxy, :video_policy) end)
  end

  defp video, do: %{"streams" => [audio(), %{"codec_type" => "video", "codec_name" => "h264"}]}
  defp audio_only, do: %{"streams" => [audio()]}
  defp audio, do: %{"codec_type" => "audio", "codec_name" => "aac"}

  describe "the verdict" do
    test "nothing configured refuses video" do
      assert VideoPolicy.admit(video()) == {:error, :video_source}
      assert VideoPolicy.verdict(video()) == :reject
    end

    test "a policy answering :extract admits it" do
      put_policy(ExtractPolicy)

      assert VideoPolicy.admit(video()) == :ok
    end

    test "an audio-only source never reaches the policy" do
      # The invariant `admit/1` exists to hold: a policy decides about video,
      # so a catalogue of tagged mp3s cannot be affected by installing one —
      # not even by a broken one, which is what raising states in the sharpest
      # available terms.
      put_policy(RaisingPolicy)

      assert VideoPolicy.admit(audio_only()) == :ok
      assert VideoPolicy.admit(%{}) == :ok
    end

    test "cover art is not video, under a policy that would extract it" do
      put_policy(ExtractPolicy)

      cover = %{
        "streams" => [
          audio(),
          %{
            "codec_type" => "video",
            "codec_name" => "mjpeg",
            "disposition" => %{"attached_pic" => 1}
          }
        ]
      }

      # Not a tautology worth skipping: `has_video?/1` is what makes this a
      # non-video source, and if the seam had been cut on the other side of it
      # every tagged mp3 in a catalogue would start taking the extraction path.
      assert VideoPolicy.admit(cover) == :ok
    end

    test "a verdict outside the enum refuses, and says whose fault it is" do
      put_policy(NonsensePolicy)

      log =
        capture_log(fn ->
          assert VideoPolicy.admit(video()) == {:error, :video_source}
        end)

      assert log =~ "NonsensePolicy"
      assert log =~ ":transcode_the_video"
    end
  end

  describe "egress is a different layer" do
    setup do
      put_config(AudioProxy.ConfigHelper.byte_limits([]))
      :ok
    end

    test "the argv is byte-identical under either verdict" do
      # The structural claim, asserted rather than argued: `Command.build/3`
      # takes the options, the input and the source type, and no policy is
      # among them. So the encode a `:extract` request runs is the same encode
      # every other request runs, and `-vn -sn -dn` cannot be conditional on a
      # verdict it never sees.
      argv = fn -> build("f:mp3/br:128") end

      rejecting = argv.()

      put_policy(ExtractPolicy)

      assert argv.() == rejecting
    end

    test "every format's argv drops video, subtitles and data" do
      for format <- ~w(mp3 aac m4a ogg opus flac wav) do
        argv = build("f:#{format}")

        assert ["-vn", "-sn", "-dn"] == drop_until_vn(argv),
               "f:#{format} does not disable non-audio streams"
      end
    end

    test "no format reaches a video encoder" do
      # `-c:v` is the token that would carry one, and the vocabulary check is
      # the second half: an argv naming a video codec at all — as a value, in
      # any position — would be a policy having reached egress.
      video_codecs = ~w(mpeg4 h264 libx264 hevc libx265 vp8 vp9 av1 libaom-av1 copy)

      for format <- ~w(mp3 aac m4a ogg opus flac wav peaks) do
        argv = build("f:#{format}")

        refute "-c:v" in argv, "f:#{format} names a video encoder switch"

        for codec <- video_codecs do
          refute codec in argv, "f:#{format} carries the video codec token #{codec}"
        end
      end
    end
  end

  defp build(options) do
    {:ok, parsed} = Options.parse(options)
    Command.build(parsed, "/srv/audio/source.mp4", type: :local)
  end

  # The three flags as a contiguous run, so a reordering that separated them —
  # or a format that emitted only two — fails rather than passing on membership.
  defp drop_until_vn(argv) do
    argv |> Enum.drop_while(&(&1 != "-vn")) |> Enum.take(3)
  end
end
