defmodule AudioProxy.Ffmpeg.CommandTest do
  use ExUnit.Case, async: true

  alias AudioProxy.Ffmpeg.Command
  alias AudioProxy.Options

  doctest AudioProxy.Ffmpeg.Command

  @source "https://masters.example/2026/piece-final.wav"

  # The protocol set an `https://` source's argv carries.
  @remote ["-protocol_whitelist", "https,tls,tcp"]

  defp argv(options, source \\ @source) do
    {:ok, opts} = Options.parse(options)
    Command.build(opts, source, type: :http)
  end

  describe "build/3 — shape" do
    test "the API doc §1 preview renders exactly" do
      assert argv("f:opus/br:96/t:12.5:30/fade:0.5:1") == [
               "-nostdin",
               "-hide_banner",
               "-loglevel",
               "error",
               "-protocol_whitelist",
               "https,tls,tcp",
               "-ss",
               "12.5",
               "-t",
               "30",
               "-i",
               @source,
               "-vn",
               "-sn",
               "-dn",
               "-af",
               "afade=t=in:st=0:d=0.5,afade=t=out:st=29:d=1",
               "-c:a",
               "libopus",
               "-b:a",
               "96k",
               "-f",
               "ogg",
               "pipe:1"
             ]
    end

    test "the bare defaults are an mp3 transcode and nothing else" do
      assert argv("") == [
               "-nostdin",
               "-hide_banner",
               "-loglevel",
               "error",
               "-protocol_whitelist",
               "https,tls,tcp",
               "-i",
               @source,
               "-vn",
               "-sn",
               "-dn",
               "-c:a",
               "libmp3lame",
               "-f",
               "mp3",
               "pipe:1"
             ]
    end

    test "every argv ends at stdout behind an explicit muxer" do
      for format <- ~w(mp3 opus ogg aac m4a flac wav peaks) do
        assert ["-f", muxer, "pipe:1"] = argv("f:#{format}") |> Enum.take(-3)
        assert muxer != ""
      end
    end

    test "the input URL is one argument, immediately after -i" do
      built = argv("f:mp3")
      index = Enum.find_index(built, &(&1 == "-i"))

      assert Enum.at(built, index + 1) == @source
    end
  end

  describe "build/3 — input-side trim" do
    test "seeks before the input so the HTTP client can range" do
      built = argv("t:12.5:30")
      input = Enum.find_index(built, &(&1 == "-i"))

      assert Enum.find_index(built, &(&1 == "-ss")) < input
      assert Enum.find_index(built, &(&1 == "-t")) < input
    end

    test "an open-ended trim emits a seek and no duration" do
      assert Enum.slice(argv("t:30"), 6..7) == ["-ss", "30"]
      refute "-t" in argv("t:30")
    end

    test "no trim, no seek" do
      refute "-ss" in argv("f:mp3")
    end
  end

  describe "build/3 — filters" do
    defp filtergraph(options) do
      built = argv(options)

      case Enum.find_index(built, &(&1 == "-af")) do
        nil -> nil
        index -> Enum.at(built, index + 1)
      end
    end

    test "no filters, no -af" do
      assert filtergraph("f:mp3/br:96") == nil
    end

    test "a fade-in starts at zero, a fade-out counts back from the trim" do
      assert filtergraph("t:0:10/fade:2") == "afade=t=in:st=0:d=2"
      assert filtergraph("t:0:10/fade:0:3") == "afade=t=out:st=7:d=3"
      assert filtergraph("t:5:10/fade:1:2") == "afade=t=in:st=0:d=1,afade=t=out:st=8:d=2"
    end

    test "a zero fade is no filter at all" do
      assert filtergraph("t:0:10/fade:0:0") == nil
    end

    # The fade-out start is (duration - out). Computed in floats, 0.3 - 0.2
    # is 0.09999999999999998, which would render as "0.1" only by luck.
    test "the fade-out start survives a decimal that binary floats cannot hold" do
      assert filtergraph("t:0:0.3/fade:0:0.2") == "afade=t=out:st=0.1:d=0.2"
    end

    test "gain becomes a dB volume filter" do
      assert filtergraph("gain:-3.5") == "volume=-3.5dB"
      assert filtergraph("gain:6") == "volume=6dB"
    end

    test "norm becomes single-pass loudnorm with all three targets" do
      assert filtergraph("norm:ebu") == "loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000"

      assert filtergraph("norm:ebu:-14:-1:9") == "loudnorm=I=-14:TP=-1:LRA=9,aresample=48000"
    end

    # loudnorm hands back 192 kHz; an explicit `sr` already resamples, so only
    # the implicit case needs the 48 kHz backstop.
    test "norm forces a resample only when sr does not already" do
      assert filtergraph("norm:ebu/sr:44100") =~ "aresample=44100"
      refute filtergraph("norm:ebu/sr:44100") =~ "48000"
      assert filtergraph("sr:44100") == "aresample=44100"
    end

    test "loudnorm runs before gain, and the fade runs last" do
      assert filtergraph("t:0:10/gain:-3/norm:ebu/sr:44100/fade:1:1") ==
               "loudnorm=I=-16:TP=-1.5:LRA=11,volume=-3dB,aresample=44100," <>
                 "afade=t=in:st=0:d=1,afade=t=out:st=9:d=1"
    end

    test "the enhance preset runs first, ahead of every loudness stage" do
      assert filtergraph("enhance:voice") == Command.enhance_chain(:voice)

      assert filtergraph("enhance:voice/norm:ebu") ==
               Command.enhance_chain(:voice) <> ",loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000"

      assert filtergraph("t:0:10/enhance:voice/norm:ebu/gain:-3/sr:44100/fade:1:1") ==
               Command.enhance_chain(:voice) <>
                 ",loudnorm=I=-16:TP=-1.5:LRA=11,volume=-3dB,aresample=44100," <>
                 "afade=t=in:st=0:d=1,afade=t=out:st=9:d=1"
    end

    test "no enhance, no preset filters" do
      refute filtergraph("f:mp3/norm:ebu") =~ "highpass"
    end

    test "a downmix is an output option, not a filter" do
      assert filtergraph("ch:1") == nil
      assert "-ac" in argv("ch:1")
      assert Enum.slice(argv("ch:1"), -7..-6) == ["-ac", "1"]
    end
  end

  # The guard behind the pinning rule, and the reason it is written as two
  # literals rather than as anything derived: a preset value maps to an exact
  # chain forever, because variants are served immutable under a key derived
  # from the *name*. Improving the chain means adding a value (`voice2`) and
  # leaving this one alone.
  #
  # So a failure here is never "update the expectation". It is one of two
  # things: an improvement that has to become a new preset, or a chain edit
  # that would have silently re-rendered every cached `enhance:voice` variant
  # under its old key. Both want a decision, which is what a literal forces and
  # a comparison against the module's own map would not.
  describe "enhance_chain/1 — the chain is pinned" do
    test "voice is exactly this chain, and changing it means minting voice2" do
      assert Command.enhance_chain(:voice) ==
               "highpass=f=80," <>
                 "afftdn=nr=12:nf=-30," <>
                 "deesser=i=0.4:m=0.5:f=0.5:s=o," <>
                 "acompressor=threshold=0.125:ratio=3:attack=20:release=250:makeup=2"
    end

    test "the vocabulary is exactly the presets that have a chain" do
      assert Options.enhance_presets() == [:voice]

      for preset <- Options.enhance_presets() do
        assert is_binary(Command.enhance_chain(preset))
      end
    end

    test "a name the options layer never accepts has no chain to render" do
      assert_raise KeyError, fn -> Command.enhance_chain(:studio) end
    end

    test "the preset's argv is the chain, once, in the filtergraph" do
      assert argv("enhance:voice/f:mp3/br:64") == [
               "-nostdin",
               "-hide_banner",
               "-loglevel",
               "error",
               "-protocol_whitelist",
               "https,tls,tcp",
               "-i",
               @source,
               "-vn",
               "-sn",
               "-dn",
               "-af",
               "highpass=f=80,afftdn=nr=12:nf=-30,deesser=i=0.4:m=0.5:f=0.5:s=o," <>
                 "acompressor=threshold=0.125:ratio=3:attack=20:release=250:makeup=2",
               "-c:a",
               "libmp3lame",
               "-b:a",
               "64k",
               "-f",
               "mp3",
               "pipe:1"
             ]
    end

    # Two spellings of one variant must not be two renders — and the chain must
    # not accumulate, which is the failure mode of assembling a filtergraph by
    # appending.
    test "differently spelled requests for one variant build one identical argv" do
      assert argv("enhance:voice/f:opus/br:96") == argv("br:96/enhance:voice/f:opus")

      assert argv("enhance:voice")
             |> Enum.filter(&(&1 =~ "highpass"))
             |> length() == 1
    end
  end

  describe "build/3 — per-format output" do
    test "each format picks its codec and muxer" do
      assert argv("f:mp3") |> Enum.take(-5) == ["-c:a", "libmp3lame", "-f", "mp3", "pipe:1"]
      assert argv("f:opus") |> Enum.take(-5) == ["-c:a", "libopus", "-f", "ogg", "pipe:1"]
      assert argv("f:ogg") |> Enum.take(-5) == ["-c:a", "libvorbis", "-f", "ogg", "pipe:1"]
      assert argv("f:aac") |> Enum.take(-5) == ["-c:a", "aac", "-f", "adts", "pipe:1"]
      assert argv("f:flac") |> Enum.take(-5) == ["-c:a", "flac", "-f", "flac", "pipe:1"]
      assert argv("f:wav") |> Enum.take(-5) == ["-c:a", "pcm_s16le", "-f", "wav", "pipe:1"]
    end

    # Not `frag_keyframe`: it cuts a fragment at each video keyframe, and an
    # audio-only stream has none, so the whole render lands in one fragment
    # flushed at EOF. Cutting on duration is what makes the stream a stream.
    test "m4a fragments on time, because audio has no keyframes to cut on" do
      assert argv("f:m4a") |> Enum.take(-9) ==
               [
                 "-c:a",
                 "aac",
                 "-movflags",
                 "empty_moov+default_base_moof",
                 "-frag_duration",
                 "1000000",
                 "-f",
                 "mp4",
                 "pipe:1"
               ]

      refute "frag_keyframe" in argv("f:m4a")
    end

    test "br is kbps, spelled so ffmpeg cannot read it as bits" do
      assert argv("br:96") |> Enum.take(-5) == ["-b:a", "96k", "-f", "mp3", "pipe:1"]
    end

    test "a signed zero renders as a plain zero everywhere" do
      # `-0` parses to -0.0, renders as "0", and so shares a cache key with
      # `0` — it must therefore share a command with it too.
      assert argv("gain:-0") == argv("gain:0")
      assert argv("t:0:10/fade:-0:-0") == argv("t:0:10/fade:0:0")
      assert argv("t:-0") == argv("t:0")

      # And the zero-guards still hold: a zero fade is no filter at all.
      refute "-af" in argv("t:0:10/fade:-0:-0")
    end

    test "wav follows the source's bit depth when it is known" do
      {:ok, opts} = Options.parse("f:wav")

      assert Command.build(opts, @source, type: :http, bit_depth: :bd24) |> Enum.take(-5) ==
               ["-c:a", "pcm_s24le", "-f", "wav", "pipe:1"]

      # An explicit `bd` still wins over the source.
      {:ok, pinned} = Options.parse("f:wav/bd:16")

      assert Command.build(pinned, @source, type: :http, bit_depth: :bd24) |> Enum.take(-5) ==
               ["-c:a", "pcm_s16le", "-f", "wav", "pipe:1"]

      # Unknown source depth falls back, documented rather than silent.
      assert Command.build(opts, @source, type: :http) |> Enum.take(-5) ==
               ["-c:a", "pcm_s16le", "-f", "wav", "pipe:1"]
    end

    test "q picks the quality knob the codec actually has" do
      assert argv("f:mp3/q:2") |> Enum.take(-5) == ["-q:a", "2", "-f", "mp3", "pipe:1"]
      assert argv("f:ogg/q:5") |> Enum.take(-5) == ["-q:a", "5", "-f", "ogg", "pipe:1"]
      assert argv("f:aac/q:1.5") |> Enum.take(-5) == ["-q:a", "1.5", "-f", "adts", "pipe:1"]

      # No VBR scale on these two; compression_level is what they expose.
      assert argv("f:opus/q:8") |> Enum.take(-5) ==
               ["-compression_level", "8", "-f", "ogg", "pipe:1"]

      assert argv("f:flac/q:8") |> Enum.take(-5) ==
               ["-compression_level", "8", "-f", "flac", "pipe:1"]
    end

    test "bd is the PCM encoder for wav and a sample format for flac" do
      assert argv("f:wav/bd:16") |> Enum.take(-5) == ["-c:a", "pcm_s16le", "-f", "wav", "pipe:1"]
      assert argv("f:wav/bd:24") |> Enum.take(-5) == ["-c:a", "pcm_s24le", "-f", "wav", "pipe:1"]
      assert argv("f:wav/bd:32f") |> Enum.take(-5) == ["-c:a", "pcm_f32le", "-f", "wav", "pipe:1"]

      assert argv("f:flac/bd:16") |> Enum.take(-7) ==
               ["-c:a", "flac", "-sample_fmt", "s16", "-f", "flac", "pipe:1"]

      assert argv("f:flac/bd:24") |> Enum.take(-7) ==
               ["-c:a", "flac", "-sample_fmt", "s32", "-f", "flac", "pipe:1"]
    end
  end

  describe "build/3 — peaks" do
    test "peaks are raw PCM for the reducer, not an encode" do
      assert argv("f:peaks/t:0:10/ch:1") == [
               "-nostdin",
               "-hide_banner",
               "-loglevel",
               "error",
               "-protocol_whitelist",
               "https,tls,tcp",
               "-ss",
               "0",
               "-t",
               "10",
               "-i",
               @source,
               "-vn",
               "-sn",
               "-dn",
               "-ac",
               "1",
               "-c:a",
               "pcm_s16le",
               "-f",
               "s16le",
               "pipe:1"
             ]
    end

    test "a fade still applies — it changes the samples a waveform is drawn from" do
      assert filtergraph("f:peaks/t:0:10/fade:1:1") ==
               "afade=t=in:st=0:d=1,afade=t=out:st=9:d=1"
    end

    test "peaks downmix to mono with no ch, unlike every other format" do
      assert argv("f:peaks") == argv("f:peaks/ch:1")
      assert Enum.chunk_every(argv("f:peaks"), 2, 1) |> Enum.member?(["-ac", "1"])
      assert Enum.chunk_every(argv("f:peaks/ch:2"), 2, 1) |> Enum.member?(["-ac", "2"])

      # The contrast: an audio format with no `ch` follows the source.
      refute Enum.member?(argv("f:mp3"), "-ac")
    end
  end

  describe "build/3 — injection safety" do
    @hostile [
      "https://evil.test/a.wav; rm -rf /",
      "https://evil.test/$(whoami).wav",
      "https://evil.test/`id`.wav",
      "https://evil.test/a b'c\"d.wav",
      "s3://bucket/key\\with\\backslashes.wav",
      "https://evil.test/a.wav -f mp3 pipe:1",
      "-af",
      "--",
      ""
    ]

    test "a hostile source URL is one argument and changes nothing else" do
      reference = argv("f:opus/br:96/t:1:5/fade:1:1", "s3://b/k.wav")

      for source <- @hostile do
        built = argv("f:opus/br:96/t:1:5/fade:1:1", source)

        assert length(built) == length(reference)
        assert Enum.count(built, &(&1 == source)) >= 1

        assert List.replace_at(built, Enum.find_index(built, &(&1 == "-i")) + 1, "s3://b/k.wav") ==
                 reference
      end
    end

    test "dl and cb never reach the argv at all" do
      plain = argv("f:mp3/br:96")

      assert argv("f:mp3/br:96/dl:my track.mp3/cb:v2") == plain
      refute Enum.any?(plain, &(&1 =~ "my track"))
      refute Enum.any?(plain, &(&1 =~ "v2"))
    end

    # The filtergraph is the one place where values are concatenated into a
    # single string, so it is the one place an injected `:` or `,` would
    # matter. Nothing but filter names, numbers and separators may appear.
    test "the filtergraph is filter names and numbers, nothing else" do
      for options <- [
            "t:0:30/fade:1.5:2.25/gain:-3.5/norm:ebu:-14:-1.5:9/sr:44100",
            "t:0:0.3/fade:0.1:0.2/gain:0.001",
            "f:peaks/t:0:10/fade:1:1",
            "norm:ebu/dl:a;b$(id).mp3/cb:x,y:z"
          ] do
        assert filtergraph(options) =~
                 ~r/^[a-z]+=(t=(in|out)|[A-Za-z]+)?[:=]?[-0-9.:=a-zA-Z]*(,[a-z]+=[-0-9.:=a-zA-Z]*)*$/

        refute filtergraph(options) =~ ~r/[;$`'"\\ \[\]]/
      end
    end
  end

  describe "build/3 — audio only" do
    @formats ~w(mp3 opus ogg aac m4a flac wav peaks)

    test "every format and the peaks path disable video, subtitles and data" do
      for format <- @formats do
        built = argv("f:#{format}")

        assert "-vn" in built, "f:#{format} lost -vn"
        assert "-sn" in built, "f:#{format} lost -sn"
        assert "-dn" in built, "f:#{format} lost -dn"
      end
    end

    test "the disable flags follow the input, so they apply to the output" do
      built = argv("f:mp3")
      input = Enum.find_index(built, &(&1 == "-i"))

      for flag <- ~w(-vn -sn -dn) do
        assert Enum.find_index(built, &(&1 == flag)) > input
      end
    end

    test "no video codec, filter or stream mapping appears for any format" do
      # The vocabulary has no way to spell these, and this is the assertion
      # that says so per format rather than trusting the table.
      for format <- @formats do
        built = argv("f:#{format}/t:0:10/fade:1:1/ch:1")

        refute Enum.any?(built, &(&1 in ~w(-c:v -vcodec -vf -filter:v -map -filter_complex)))
        refute Enum.any?(built, &String.contains?(&1, "0:v"))
      end
    end
  end

  describe "build/3 — protocol whitelist" do
    test "every argv carries one, before the input" do
      for format <- @formats do
        built = argv("f:#{format}")
        flag = Enum.find_index(built, &(&1 == "-protocol_whitelist"))

        assert flag, "f:#{format} has no protocol whitelist"
        assert flag < Enum.find_index(built, &(&1 == "-i"))
      end
    end

    test "a local source gets file and nothing else" do
      {:ok, opts} = Options.parse("f:mp3")
      built = Command.build(opts, "/srv/audio/piece.wav", type: :local)

      assert Enum.slice(built, 4..5) == ["-protocol_whitelist", "file"]
    end

    test "a remote source gets no file entry" do
      assert Enum.slice(argv("f:mp3"), 4..5) == @remote
      refute "file" in argv("f:mp3")
    end

    # The two sets are disjoint by construction, which is the property that
    # makes the gate meaningful: a local invocation cannot fetch, and a remote
    # one cannot read disk.
    test "the local and remote sets share nothing" do
      local = Command.protocols(:local) |> String.split(",") |> MapSet.new()
      remote = Command.protocols(:http) |> String.split(",") |> MapSet.new()

      assert MapSet.disjoint?(local, remote)
    end

    test "a source type with no protocol set raises rather than inheriting one" do
      # Called through `apply/3` on purpose: a literal here is a type error the
      # compiler reports before the test can make its point, which is about
      # runtime behaviour for a tag some future slice adds.
      assert_raise FunctionClauseError, fn -> apply(Command, :protocols, [:gopher]) end
    end

    test "the source type is required — the whitelist cannot be forgotten" do
      {:ok, opts} = Options.parse("f:mp3")

      assert_raise KeyError, fn -> Command.build(opts, @source, bit_depth: :bd16) end
    end
  end

  describe "allowed_flags/0" do
    test "it covers every flag the builder emits, for every option combination" do
      # The property test is the general statement; this is the readable one,
      # over the combinations most likely to introduce a flag.
      for options <- [
            "f:mp3/br:96/t:1:5/fade:1:1/gain:-3/norm:ebu/sr:44100/ch:1",
            "f:m4a/q:1.5",
            "f:flac/bd:24",
            "f:wav/bd:32f",
            "f:opus/q:8",
            "f:ogg/q:-1",
            "f:peaks/t:0:10/pts:1000"
          ] do
        assert AudioProxy.ArgvWalk.flags(argv(options)) -- Command.allowed_flags() == [],
               "#{options} emitted a flag that is not in the allowlist"
      end
    end

    # `f:ogg/q:-1` is the case that makes the walk necessary rather than
    # decorative: ogg's quality scale starts at −1, so the argv genuinely
    # contains a `-`-prefixed *value*.
    test "a negative option value is a value, not an unknown flag" do
      built = argv("f:ogg/q:-1")

      assert ["-q:a", "-1"] == Enum.slice(built, -5..-4)
      refute "-1" in AudioProxy.ArgvWalk.flags(built)
    end

    test "the vocabulary contains no video, subtitle or mapping flag" do
      denied = ~w(-c:v -vcodec -vf -filter:v -filter_complex -map -map_metadata -sn:0)

      for flag <- Command.allowed_flags() do
        refute flag in denied
        refute flag =~ ~r/:v$|^-v(f|codec)$/
      end
    end

    test "the disable flags are in it, and take no value" do
      for flag <- ~w(-vn -sn -dn) do
        assert flag in Command.allowed_flags()
        refute Command.takes_value?(flag)
      end

      assert Command.takes_value?("-protocol_whitelist")
    end
  end

  describe "content_type/1" do
    test "every format has one" do
      assert Command.content_type(:mp3) == "audio/mpeg"
      assert Command.content_type(:opus) == "audio/ogg"
      assert Command.content_type(:ogg) == "audio/ogg"
      assert Command.content_type(:aac) == "audio/aac"
      assert Command.content_type(:m4a) == "audio/mp4"
      assert Command.content_type(:flac) == "audio/flac"
      assert Command.content_type(:wav) == "audio/wav"
      assert Command.content_type(:peaks) == "application/json"
    end

    test "peaks follow pk_fmt when given the whole struct" do
      {:ok, json} = Options.parse("f:peaks")
      {:ok, dat} = Options.parse("f:peaks/pk_fmt:dat")

      assert Command.content_type(json) == "application/json"
      assert Command.content_type(dat) == "application/octet-stream"
    end

    test "a struct resolves through its format" do
      {:ok, opts} = Options.parse("f:m4a/br:96")

      assert Command.content_type(opts) == "audio/mp4"
    end
  end
end
