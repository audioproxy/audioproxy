defmodule AudioProxy.OptionsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AudioProxy.CacheKey
  alias AudioProxy.Options

  @source "s3://masters/2026/piece-final.wav"

  import AudioProxy.OptionsGenerators, only: [option_segments: 0, decimal: 1]

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

  # The grammar property AudioProxy.CacheKey's newline separator rests on.
  property "a normalized string never contains a control character" do
    check all(segments <- option_segments()) do
      assert {:ok, normalized} = Options.normalize_string(segments)
      refute normalized =~ ~r/[\x00-\x1f\x7f]/
    end
  end
end
