defmodule AudioProxy.OptionsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AudioProxy.CacheKey
  alias AudioProxy.Options

  @source "s3://masters/2026/piece-final.wav"

  import AudioProxy.OptionsGenerators,
    only: [option_segments: 0, request_option_segments: 0, decimal: 1]

  property "generated option strings parse" do
    check all(segments <- option_segments()) do
      assert {:ok, _opts} = Options.parse(segments)
    end
  end

  property "parse → normalize is idempotent" do
    check all(segments <- option_segments()) do
      assert {:ok, once} = Options.normalize_string(segments)
      assert {:ok, twice} = Options.normalize_string(once)

      assert once == twice
    end
  end

  # Grammar closure: normalization can never emit a spelling the parser
  # rejects, or a cached variant would become unaddressable.
  property "a normalized string always re-parses" do
    check all(segments <- option_segments()) do
      assert {:ok, normalized} = Options.normalize_string(segments)
      assert {:ok, opts} = Options.parse(normalized)
      assert Options.normalize(opts) == normalized
    end
  end

  property "segment order does not affect the normalized form or the cache key" do
    check all(segments <- option_segments(), permuted <- shuffle(segments)) do
      assert Options.normalize_string(segments) == Options.normalize_string(permuted)
      assert CacheKey.derive(segments, @source) == CacheKey.derive(permuted, @source)
    end
  end

  property "equal normalized forms share a cache key, distinct ones do not" do
    check all(left <- option_segments(), right <- option_segments()) do
      assert {:ok, left_normalized} = Options.normalize_string(left)
      assert {:ok, right_normalized} = Options.normalize_string(right)
      assert {:ok, left_key} = CacheKey.derive(left, @source)
      assert {:ok, right_key} = CacheKey.derive(right, @source)

      if left_normalized == right_normalized do
        assert left_key == right_key
      else
        assert left_key != right_key
      end
    end
  end

  property "the source participates in the key" do
    check all(
            segments <- option_segments(),
            source <- string(?a..?z, min_length: 1, max_length: 20)
          ) do
      assert CacheKey.derive(segments, "s3://bucket/" <> source) !=
               CacheKey.derive(segments, @source)
    end
  end

  # The boundary the old generator could not reach. Any split summing to the
  # duration must be accepted; one millisecond more must not.
  property "a fade summing exactly to the trim duration is always accepted" do
    check all(
            duration <- integer(2..300_000),
            fade_in <- integer(0..duration)
          ) do
      fade_out = duration - fade_in
      trim = "t:0:#{decimal(duration)}"

      assert {:ok, _} = Options.parse("#{trim}/fade:#{decimal(fade_in)}:#{decimal(fade_out)}")

      assert {:error, %AudioProxy.OptionError{reason: :fade_exceeds_duration}} =
               Options.parse("#{trim}/fade:#{decimal(fade_in)}:#{decimal(fade_out + 1)}")
    end
  end

  # The round-trip property, stated per class. A variant option round-trips to
  # an identical cache key; a request option round-trips to the signed path
  # alone, which from this module's side means it must leave no trace at all.
  # Without this, `exp` would be a per-recipient timestamp inside the cache key
  # — one render per listener for byte-identical audio.
  property "a request option changes neither the normalized form nor the key" do
    check all(
            segments <- option_segments(),
            one <- request_option_segments(),
            other <- request_option_segments(),
            shuffled <- shuffle(segments ++ one)
          ) do
      assert {:ok, bare} = Options.normalize_string(segments)

      assert Options.normalize_string(segments ++ one) == {:ok, bare}
      assert Options.normalize_string(segments ++ other) == {:ok, bare}
      assert Options.normalize_string(shuffled) == {:ok, bare}

      assert CacheKey.derive(segments ++ one, @source) ==
               CacheKey.derive(segments ++ other, @source)

      assert CacheKey.derive(segments ++ one, @source) == CacheKey.derive(segments, @source)
    end
  end

  # It is still an option, so the rules that hold for every key hold for it.
  property "a request option is duplicate-checked like any other" do
    check all(segments <- option_segments(), one <- request_option_segments()) do
      assert {:error, %AudioProxy.OptionError{reason: :duplicate_key}} =
               Options.parse(segments ++ one ++ one)
    end
  end

  # The grammar property AudioProxy.CacheKey's newline separator rests on.
  property "a normalized string never contains a control character" do
    check all(segments <- option_segments()) do
      assert {:ok, normalized} = Options.normalize_string(segments)
      refute normalized =~ ~r/[\x00-\x1f\x7f]/
    end
  end
end
