defmodule AudioProxy.OptionsTest do
  use ExUnit.Case, async: true

  alias AudioProxy.OptionError
  alias AudioProxy.Options

  doctest AudioProxy.Options

  describe "parse/1 — shape" do
    test "an empty options string yields the defaults" do
      assert {:ok, %Options{format: :mp3, bitrate: nil}} = Options.parse("")
    end

    test "accepts pre-split segments" do
      assert Options.parse(["f:opus", "br:96"]) == Options.parse("f:opus/br:96")
    end

    test "the API doc §1 example parses to its documented variant" do
      assert {:ok, opts} = Options.parse("f:opus/br:96/t:12.5:30/fade:0.5:1")

      assert opts.format == :opus
      assert opts.bitrate == 96
      assert opts.trim_start == 12.5
      assert opts.trim_duration == 30.0
      assert opts.fade_in == 0.5
      assert opts.fade_out == 1.0
    end

    test "a segment without a value is rejected" do
      assert {:error, %OptionError{segment: "f", reason: :missing_value}} = Options.parse("f")
    end

    test "an empty segment is rejected" do
      assert {:error, %OptionError{reason: :empty_segment}} = Options.parse("f:mp3//br:96")
    end

    test "an unknown key names the offending segment" do
      assert {:error, %OptionError{segment: "xyz:1", reason: :unknown_key}} =
               Options.parse("xyz:1")
    end

    test "a repeated key is rejected rather than last-write-wins" do
      assert {:error, %OptionError{segment: "f:opus", reason: :duplicate_key}} =
               Options.parse("f:mp3/f:opus")
    end
  end

  describe "parse/1 — per-key domains" do
    test "every documented format parses" do
      for format <- ~w(mp3 opus ogg aac m4a flac wav peaks) do
        assert {:ok, %Options{format: parsed}} = Options.parse("f:#{format}")
        assert parsed == String.to_existing_atom(format)
      end
    end

    test "an unsupported format is rejected" do
      assert {:error, %OptionError{segment: "f:wma", reason: :invalid_value}} =
               Options.parse("f:wma")
    end

    test "bitrate must be a positive integer" do
      assert {:ok, %Options{bitrate: 128}} = Options.parse("br:128")
      assert {:error, %OptionError{reason: :invalid_integer}} = Options.parse("br:abc")
      assert {:error, %OptionError{reason: :invalid_integer}} = Options.parse("br:96.5")
      assert {:error, %OptionError{reason: :out_of_range}} = Options.parse("br:0")
    end

    test "quality accepts integers and decimals" do
      assert {:ok, %Options{quality: 5.0}} = Options.parse("q:5")
      assert {:ok, %Options{quality: 0.5}} = Options.parse("q:0.5")
      assert {:error, %OptionError{reason: :invalid_number}} = Options.parse("q:high")
    end

    test "bit depth accepts the three documented tokens" do
      assert {:ok, %Options{bit_depth: :bd16}} = Options.parse("f:flac/bd:16")
      assert {:ok, %Options{bit_depth: :bd24}} = Options.parse("f:flac/bd:24")
      assert {:ok, %Options{bit_depth: :bd32f}} = Options.parse("f:wav/bd:32f")
      assert {:error, %OptionError{reason: :invalid_value}} = Options.parse("f:flac/bd:8")
    end

    test "trim takes an optional duration" do
      assert {:ok, %Options{trim_start: 30.0, trim_duration: nil}} = Options.parse("t:30")
      assert {:ok, %Options{trim_start: 30.0, trim_duration: 15.0}} = Options.parse("t:30:15")
      assert {:error, %OptionError{reason: :out_of_range}} = Options.parse("t:30:0")
      assert {:error, %OptionError{reason: :invalid_value}} = Options.parse("t:1:2:3")
    end

    test "an omitted out-fade is zero, not a mirror of the in-fade" do
      assert {:ok, %Options{fade_in: 0.5, fade_out: +0.0}} = Options.parse("fade:0.5")
      assert {:ok, %Options{fade_in: 0.5, fade_out: 1.0}} = Options.parse("t:0:10/fade:0.5:1")
    end

    test "gain is signed" do
      assert {:ok, %Options{gain: -3.5}} = Options.parse("gain:-3.5")
      assert {:ok, %Options{gain: 6.0}} = Options.parse("gain:6")
    end

    test "norm fills in the §3.2 defaults for omitted targets" do
      assert {:ok, %Options{norm: {-16.0, -1.5, 11.0}}} = Options.parse("norm:ebu")
      assert {:ok, %Options{norm: {-14.0, -1.5, 11.0}}} = Options.parse("norm:ebu:-14")
      assert {:ok, %Options{norm: {-14.0, -1.0, 11.0}}} = Options.parse("norm:ebu:-14:-1")
      assert {:ok, %Options{norm: {-14.0, -1.0, 9.0}}} = Options.parse("norm:ebu:-14:-1:9")
    end

    test "norm targets are range-checked against loudnorm's inputs" do
      assert {:error, %OptionError{reason: :out_of_range}} = Options.parse("norm:ebu:-99")
      assert {:error, %OptionError{reason: :out_of_range}} = Options.parse("norm:ebu:-14:3")
      assert {:error, %OptionError{reason: :out_of_range}} = Options.parse("norm:ebu:-14:-1:99")
      assert {:error, %OptionError{reason: :invalid_value}} = Options.parse("norm:itu")
    end

    test "decimals beyond millisecond precision are rejected, not rounded" do
      assert {:ok, %Options{trim_start: 1.234}} = Options.parse("t:1.234")

      assert {:error, %OptionError{segment: "t:1.2345", reason: :excessive_precision}} =
               Options.parse("t:1.2345")
    end

    test "exponent notation is not a number here" do
      assert {:error, %OptionError{reason: :invalid_number}} = Options.parse("gain:1e3")
    end

    test "delivery options are opaque but must be non-empty" do
      assert {:ok, %Options{download: "piece.mp3", cache_buster: "v2"}} =
               Options.parse("dl:piece.mp3/cb:v2")

      assert {:error, %OptionError{reason: :invalid_value}} = Options.parse("dl:")
      assert {:error, %OptionError{reason: :invalid_value}} = Options.parse("cb:")
    end
  end

  # One failing case per cross-key rule, each asserting the offending segment
  # is named — that string is what the 422 body shows the client.
  describe "validate/1 — cross-key rules" do
    test "br and q are mutually exclusive" do
      assert {:error,
              %OptionError{segment: "q:5", reason: :mutually_exclusive, related: "br:128"}} =
               Options.parse("br:128/q:5")
    end

    test "bd requires a lossless format" do
      assert {:error,
              %OptionError{segment: "bd:24", reason: :requires_lossless_format, related: "f:mp3"}} =
               Options.parse("bd:24")

      assert {:ok, _} = Options.parse("f:wav/bd:24")
    end

    test "pts requires f:peaks" do
      assert {:error,
              %OptionError{segment: "pts:400", reason: :requires_peaks_format, related: "f:mp3"}} =
               Options.parse("pts:400")
    end

    test "pk_fmt requires f:peaks" do
      assert {:error,
              %OptionError{
                segment: "pk_fmt:dat",
                reason: :requires_peaks_format,
                related: "f:opus"
              }} = Options.parse("f:opus/pk_fmt:dat")
    end

    test "sr is capped at 48 kHz for lossy formats only" do
      assert {:error,
              %OptionError{
                segment: "sr:96000",
                reason: :sample_rate_above_lossy_cap,
                related: "f:mp3"
              }} = Options.parse("sr:96000")

      assert {:ok, _} = Options.parse("f:flac/sr:96000")
      assert {:ok, _} = Options.parse("sr:48000")
    end

    test "channels are limited to mono and stereo" do
      assert {:error, %OptionError{segment: "ch:3", reason: :invalid_value}} =
               Options.parse("ch:3")

      assert {:ok, %Options{channels: 1}} = Options.parse("ch:1")
      assert {:ok, %Options{channels: 2}} = Options.parse("ch:2")
    end

    test "times are non-negative" do
      assert {:error, %OptionError{segment: "t:-1", reason: :out_of_range}} =
               Options.parse("t:-1")

      assert {:error, %OptionError{segment: "fade:-0.5", reason: :out_of_range}} =
               Options.parse("fade:-0.5")
    end

    test "a fade must fit inside a bounded trim" do
      assert {:error,
              %OptionError{
                segment: "fade:2:2",
                reason: :fade_exceeds_duration,
                related: "t:1:2"
              }} = Options.parse("t:1:2/fade:2:2")

      assert {:ok, _} = Options.parse("t:1:10/fade:2:2")
    end

    test "a fade-out needs a duration to count back from" do
      assert {:error,
              %OptionError{
                segment: "fade:2:2",
                reason: :requires_bounded_trim,
                related: "t:1"
              }} = Options.parse("t:1/fade:2:2")

      assert {:error, %OptionError{reason: :requires_bounded_trim}} = Options.parse("fade:0:2")

      # A fade-in starts at zero, so it needs no duration at all.
      assert {:ok, _} = Options.parse("fade:2")
      assert {:ok, _} = Options.parse("t:1/fade:2:0")
    end

    test "br and q reach encoders that have them" do
      assert {:error,
              %OptionError{
                segment: "br:320",
                reason: :requires_lossy_format,
                related: "f:flac"
              }} = Options.parse("f:flac/br:320")

      assert {:error, %OptionError{reason: :requires_lossy_format}} =
               Options.parse("f:wav/br:320")

      # flac has no VBR scale but does have compression_level; PCM has neither.
      assert {:ok, _} = Options.parse("f:flac/q:8")

      assert {:error,
              %OptionError{
                segment: "q:8",
                reason: :unsupported_for_format,
                related: "f:wav"
              }} = Options.parse("f:wav/q:8")
    end

    test "a float bit depth lives in wav alone" do
      assert {:ok, _} = Options.parse("f:wav/bd:32f")

      assert {:error,
              %OptionError{
                segment: "bd:32f",
                reason: :unsupported_for_format,
                related: "f:flac"
              }} = Options.parse("f:flac/bd:32f")
    end
  end

  describe "normalize/1" do
    test "materializes the format default" do
      assert Options.normalize_string("br:96") == {:ok, "br:96/f:mp3"}
    end

    test "materializes the peaks defaults only under f:peaks" do
      assert Options.normalize_string("f:peaks") == {:ok, "f:peaks/pk_fmt:json/pts:800"}
      assert Options.normalize_string("f:mp3") == {:ok, "f:mp3"}
    end

    test "materializes the norm targets when norm is present" do
      assert Options.normalize_string("norm:ebu") == {:ok, "f:mp3/norm:ebu:-16:-1.5:11"}
      assert Options.normalize_string("norm:ebu:-14") == {:ok, "f:mp3/norm:ebu:-14:-1.5:11"}
    end

    test "is order-insensitive" do
      assert Options.normalize_string("f:opus/br:96") == Options.normalize_string("br:96/f:opus")
      assert Options.normalize_string("f:opus/br:96") == {:ok, "br:96/f:opus"}
    end

    test "sorts keys lexicographically" do
      assert {:ok, normalized} = Options.normalize_string("t:30/f:flac/ch:1/bd:24/gain:-3")
      assert normalized == "bd:24/ch:1/f:flac/gain:-3/t:30"
    end

    test "renders numbers minimally" do
      assert Options.normalize_string("t:30.0:15.500") == {:ok, "f:mp3/t:30:15.5"}
      assert Options.normalize_string("gain:-3.250") == {:ok, "f:mp3/gain:-3.25"}
      assert Options.normalize_string("q:5.000") == {:ok, "f:mp3/q:5"}
    end

    test "an omitted out-fade normalizes to an explicit zero" do
      assert Options.normalize_string("fade:0.5") == {:ok, "f:mp3/fade:0.5:0"}
    end

    test "keeps the cache buster" do
      assert Options.normalize_string("cb:v2") == {:ok, "cb:v2/f:mp3"}
    end

    test "is idempotent" do
      for options <- [
            "f:opus/br:96/t:12.5:30/fade:0.5:1",
            "f:peaks/t:0:10/ch:1",
            "norm:ebu:-14:-1:9/gain:-3/dl:piece.mp3/cb:v2",
            "f:wav/bd:32f/sr:96000"
          ] do
        assert {:ok, once} = Options.normalize_string(options)
        assert {:ok, twice} = Options.normalize_string(once)
        assert once == twice
      end
    end
  end

  # Regression: these compared as IEEE floats before, and 0.1 + 0.2 is
  # 0.30000000000000004, so a fade that exactly filled its trim was rejected.
  describe "validate/1 — fade boundary is exact" do
    test "a fade that exactly fills its trim is accepted, whatever the split" do
      assert {:ok, _} = Options.parse("t:0:0.3/fade:0.1:0.2")
      assert {:ok, _} = Options.parse("t:0:0.3/fade:0.2:0.1")
      assert {:ok, _} = Options.parse("t:0:0.3/fade:0.15:0.15")
      assert {:ok, _} = Options.parse("t:0:0.1/fade:0.07:0.03")
      assert {:ok, _} = Options.parse("t:0:1/fade:0.001:0.999")
    end

    test "a fade one millisecond too long is still rejected" do
      assert {:error, %OptionError{reason: :fade_exceeds_duration}} =
               Options.parse("t:0:0.3/fade:0.1:0.201")
    end
  end

  describe "parse/1 — opaque values reject control characters" do
    test "dl and cb refuse control bytes" do
      for value <- ["a\nb", "a\rb", "a\0b", "a\tb", "a\x7fb"] do
        assert {:error, %OptionError{reason: :control_character}} =
                 Options.parse("dl:" <> value)

        assert {:error, %OptionError{reason: :control_character}} =
                 Options.parse("cb:" <> value)
      end
    end

    # This is what makes AudioProxy.CacheKey's newline separator sound.
    test "a normalized string can never contain a newline" do
      assert {:error, %OptionError{segment: "cb:a\nb", reason: :control_character}} =
               Options.parse("cb:a\nb")
    end

    test "ordinary percent-encoded filenames still pass" do
      assert {:ok, %Options{download: "my%20piece%2Ffinal.mp3"}} =
               Options.parse("dl:my%20piece%2Ffinal.mp3")
    end
  end

  describe "parse/1 — upper bounds" do
    test "values are bounded above as well as below" do
      assert {:error, %OptionError{segment: "br:10001", reason: :out_of_range}} =
               Options.parse("br:10001")

      assert {:error, %OptionError{reason: :out_of_range}} = Options.parse("f:wav/sr:384001")
      assert {:error, %OptionError{reason: :out_of_range}} = Options.parse("f:peaks/pts:100001")
      assert {:error, %OptionError{reason: :out_of_range}} = Options.parse("gain:100.001")

      assert {:ok, _} = Options.parse("br:10000")
      assert {:ok, _} = Options.parse("f:wav/sr:384000")
      assert {:ok, _} = Options.parse("f:peaks/pts:100000")
      assert {:ok, _} = Options.parse("gain:-100")
    end
  end

  describe "validate/1 — peaks ignore encoding and loudness options" do
    test "every encoding and loudness option is refused under f:peaks" do
      for {options, segment} <- [
            {"f:peaks/br:96", "br:96"},
            {"f:peaks/q:5", "q:5"},
            {"f:peaks/sr:48000", "sr:48000"},
            {"f:peaks/bd:16", "bd:16"},
            {"f:peaks/gain:-3", "gain:-3"},
            {"f:peaks/norm:ebu", "norm:ebu:-16:-1.5:11"}
          ] do
        assert {:error, %OptionError{segment: ^segment, reason: :unsupported_for_peaks}} =
                 Options.parse(options)
      end
    end

    test "the options peaks do respect are still accepted" do
      assert {:ok, _} = Options.parse("f:peaks/t:10:5/ch:1/pts:2000/pk_fmt:dat/dl:p.json/cb:v2")
    end
  end

  # normalize/1 is public, so it must be total over the struct — not only over
  # structs that parse/1 produced.
  describe "normalize/1 — hand-built structs" do
    test "renders a half-set pair instead of crashing or dropping it" do
      assert Options.normalize(%Options{fade_in: 0.5}) == "f:mp3/fade:0.5:0"
      assert Options.normalize(%Options{fade_out: 1.0}) == "f:mp3/fade:0:1"
      assert Options.normalize(%Options{trim_duration: 30.0}) == "f:mp3/t:0:30"
      assert Options.normalize(%Options{trim_start: 5.0}) == "f:mp3/t:5"
    end

    test "sub-millisecond values render as re-parseable zero, not a bare dot" do
      normalized = Options.normalize(%Options{trim_start: 0.0004})

      assert normalized == "f:mp3/t:0"
      assert {:ok, _} = Options.parse(normalized)
    end

    test "every normalized string re-parses" do
      for opts <- [
            %Options{fade_in: 0.5},
            %Options{fade_out: 1.0, trim_duration: 30.0},
            %Options{trim_duration: 30.0},
            %Options{trim_start: 0.0004},
            %Options{format: :peaks}
          ] do
        assert {:ok, _} = Options.parse(Options.normalize(opts))
      end
    end
  end
end
