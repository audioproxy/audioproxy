defmodule AudioProxy.Ffmpeg.ProbeTest do
  use ExUnit.Case, async: true

  alias AudioProxy.Ffmpeg.Probe

  doctest Probe

  describe "args/1" do
    test "asks for one audio stream and nothing it does not need" do
      args = Probe.args("https://example.test/a.wav")

      assert List.last(args) == "https://example.test/a.wav"
      assert "-select_streams" in args
      assert "a:0" in args
      assert "json" in args
    end

    test "a hostile URL is one argument, exactly as the render argv is" do
      source = "https://evil.test/a.wav; rm -rf /"

      assert Enum.count(Probe.args(source), &(&1 == source)) == 1
      assert length(Probe.args(source)) == length(Probe.args("s3://b/k.wav"))
    end
  end

  describe "parse/1" do
    test "reads the fields peaks need" do
      json = ~s({
        "streams": [{"sample_rate": "48000", "channels": 2}],
        "format": {"duration": "123.456"}
      })

      assert {:ok, %{duration: 123.456, sample_rate: 48_000, channels: 2}} = Probe.parse(json)
    end

    test "accepts numbers as well as the strings ffprobe usually writes" do
      json = ~s({"streams": [{"sample_rate": 44100, "channels": 1}], "format": {"duration": 3}})

      assert {:ok, %{duration: 3.0, sample_rate: 44_100, channels: 1}} = Probe.parse(json)
    end

    # Not an error: a raw stream has no container duration, and it is the
    # caller — peaks, which cannot place buckets without one — that decides
    # whether a missing duration is fatal.
    test "a duration ffprobe could not determine is nil" do
      json =
        ~s({"streams": [{"sample_rate": "44100", "channels": 1}], "format": {"duration": "N/A"}})

      assert {:ok, %{duration: nil, sample_rate: 44_100}} = Probe.parse(json)

      assert {:ok, %{duration: nil}} =
               Probe.parse(~s({"streams": [{"sample_rate": "44100", "channels": 1}]}))
    end

    test "a source with no audio stream says so" do
      assert Probe.parse(~s({"streams": [], "format": {"duration": "10"}})) ==
               {:error, :no_audio_stream}

      assert Probe.parse(~s({"format": {"duration": "10"}})) == {:error, :no_audio_stream}
    end

    test "anything unreadable is an error, not a crash" do
      assert Probe.parse("") == {:error, :unreadable_probe}
      assert Probe.parse("not json") == {:error, :unreadable_probe}
      assert Probe.parse("[1, 2]") == {:error, :unreadable_probe}
      assert Probe.parse(~s({"streams": [{"channels": 1}]})) == {:error, :unreadable_probe}

      assert Probe.parse(~s({"streams": [{"sample_rate": "0", "channels": 1}]})) ==
               {:error, :unreadable_probe}
    end

    # Every one of these raised before: the `with` matched the stream list and
    # enumerated the failures it expected, and none of these was among them.
    # ffprobe writes none of them either, which is exactly why the catch-all
    # matters — the module's contract is that it turns *bytes* into a tuple.
    test "a streams value of the wrong shape is an error, not a raise" do
      for output <- [
            ~s({"streams": {}}),
            ~s({"streams": "nope"}),
            ~s({"streams": null}),
            ~s({"streams": [42]}),
            ~s({"streams": ["a string"]})
          ] do
        assert {:error, reason} = Probe.parse(output)
        assert reason in [:no_audio_stream, :unreadable_probe]
      end
    end
  end

  describe "executable/1" do
    test "an explicit path must exist" do
      assert {:error, {:executable_not_found, "/nope/ffprobe"}} =
               Probe.executable("/nope/ffprobe")
    end

    test "an existing path is taken as given" do
      assert {:ok, path} = Probe.executable(AudioProxy.FakeFfmpeg.path())
      assert path == AudioProxy.FakeFfmpeg.path()
    end
  end
end
