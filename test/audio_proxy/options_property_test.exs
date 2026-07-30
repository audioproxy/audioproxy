defmodule AudioProxy.OptionsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AudioProxy.CacheKey
  alias AudioProxy.Options

  @source "s3://masters/2026/piece-final.wav"

  @formats ~w(mp3 opus ogg aac m4a flac wav peaks)
  @lossy ~w(mp3 opus ogg aac m4a)
  @lossless ~w(flac wav)

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

  ## Generators

  # A valid options segment list, built format-first so that the cross-key
  # rules hold by construction: `br` xor `q`, `bd` only under a lossless
  # format, peaks keys only under `f:peaks`, `sr` within the lossy cap, and a
  # fade that fits inside a bounded trim. Values are deliberately spelled
  # non-canonically (trailing zeros, `30.000` for `30`) so normalization has
  # something to do.
  defp option_segments do
    gen all(
          format <- member_of(@formats),
          rate <- encoding(format),
          channels <- maybe(one_of([constant(["ch:1"]), constant(["ch:2"])])),
          depth <- bit_depth(format),
          {trim, duration_ms} <- trim(),
          fade <- fade(duration_ms),
          gain <- maybe(gain(format)),
          norm <- maybe(norm(format)),
          peaks <- peaks(format),
          delivery <- delivery(),
          segments <-
            shuffle(
              ["f:#{format}"] ++
                rate ++ channels ++ depth ++ trim ++ fade ++ gain ++ norm ++ peaks ++ delivery
            )
        ) do
      segments
    end
  end

  # Peaks refuse every encoding and loudness option, so generate none of them.
  defp encoding("peaks"), do: constant([])

  # `br` and `q` are mutually exclusive, so at most one is ever emitted.
  defp encoding(format) do
    gen all(
          bitrate_or_quality <-
            one_of([
              constant([]),
              map(integer(32..320), &["br:#{&1}"]),
              map(integer(0..10), &["q:#{&1}.000"])
            ]),
          sample_rate <- maybe(sample_rate(format))
        ) do
      bitrate_or_quality ++ sample_rate
    end
  end

  defp sample_rate(format) when format in @lossy do
    map(member_of([8000, 16_000, 22_050, 32_000, 44_100, 48_000]), &["sr:#{&1}"])
  end

  defp sample_rate(_format) do
    map(member_of([44_100, 48_000, 88_200, 96_000, 192_000]), &["sr:#{&1}"])
  end

  defp bit_depth(format) when format in @lossless do
    maybe(map(member_of(~w(16 24 32f)), &["bd:#{&1}"]))
  end

  defp bit_depth(_format), do: constant([])

  # Returns the segments plus the trim duration in milliseconds (or nil for
  # an open-ended trim), which bounds the fade generated next.
  defp trim do
    one_of([
      constant({[], nil}),
      map(millis(0..600_000), fn start -> {["t:#{decimal(start)}"], nil} end),
      gen all(start <- millis(0..600_000), duration <- millis(1_000..300_000)) do
        {["t:#{decimal(start)}:#{decimal(duration)}"], duration}
      end
    ])
  end

  defp fade(nil) do
    maybe(
      gen all(fade_in <- millis(0..5_000), fade_out <- millis(0..5_000)) do
        ["fade:#{decimal(fade_in)}:#{decimal(fade_out)}"]
      end
    )
  end

  # Splits the whole trim budget between the two halves rather than capping
  # each at half of it, so asymmetric splits that sum EXACTLY to the duration
  # are reachable. The old halve-each bound could only ever hit the boundary
  # symmetrically, which is the one case IEEE addition gets right — it hid a
  # real bug (0.1 + 0.2 > 0.3).
  defp fade(duration_ms) do
    maybe(
      gen all(
            fade_in <- millis(0..duration_ms),
            fade_out <- millis(0..(duration_ms - fade_in))
          ) do
        ["fade:#{decimal(fade_in)}:#{decimal(fade_out)}"]
      end
    )
  end

  defp gain("peaks"), do: constant([])
  defp gain(_format), do: map(millis(-30_000..30_000), &["gain:#{decimal(&1)}"])

  defp norm("peaks"), do: constant([])

  # Partial forms exercise the documented per-target defaults.
  defp norm(_format) do
    gen all(
          i <- integer(-70..-5),
          tp <- integer(-9..0),
          lra <- integer(1..50),
          arity <- integer(0..3)
        ) do
      case arity do
        0 -> ["norm:ebu"]
        1 -> ["norm:ebu:#{i}"]
        2 -> ["norm:ebu:#{i}:#{tp}"]
        3 -> ["norm:ebu:#{i}:#{tp}:#{lra}"]
      end
    end
  end

  defp peaks("peaks") do
    gen all(
          count <- maybe(map(integer(1..8_000), &["pts:#{&1}"])),
          peak_format <- maybe(map(member_of(~w(json dat)), &["pk_fmt:#{&1}"]))
        ) do
      count ++ peak_format
    end
  end

  defp peaks(_format), do: constant([])

  defp delivery do
    gen all(
          download <- maybe(map(token(), &["dl:#{&1}.mp3"])),
          cache_buster <- maybe(map(token(), &["cb:#{&1}"]))
        ) do
      download ++ cache_buster
    end
  end

  defp token, do: string(Enum.concat([?a..?z, ?0..?9]), min_length: 1, max_length: 8)

  defp maybe(generator), do: one_of([constant([]), generator])

  defp millis(range), do: integer(range)

  # Always three decimal places — a legal but non-canonical spelling, so the
  # normalized form is never simply the input echoed back.
  defp decimal(millis) do
    sign = if millis < 0, do: "-", else: ""
    magnitude = abs(millis)
    fraction = magnitude |> rem(1000) |> Integer.to_string() |> String.pad_leading(3, "0")

    "#{sign}#{div(magnitude, 1000)}.#{fraction}"
  end
end
