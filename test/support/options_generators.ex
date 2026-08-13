defmodule AudioProxy.OptionsGenerators do
  @moduledoc """
  StreamData generators for valid processing-option segment lists.

  Built format-first so every cross-key rule in `AudioProxy.Options` holds
  by construction — `br` xor `q` and each only where its encoder has the
  knob, `bd` under a lossless format (and a float depth under wav alone),
  peaks keys under `f:peaks`, `sr` within the lossy cap, a fade that fits
  inside its trim and a fade-out only where a trim bounds one. A property
  that has to filter its own inputs is a property that stopped testing what
  it says it tests, so nothing here generates a string the parser rejects.

  Values are deliberately spelled non-canonically (`30.000` for `30`) so
  normalization always has something to do.

  Shared by the options and ffmpeg-argv property suites: both rest on the
  same round-trip, so they must be probing the same grammar.
  """

  use ExUnitProperties

  @formats ~w(mp3 opus ogg aac m4a flac wav peaks)
  @lossy ~w(mp3 opus ogg aac m4a)
  # Each codec's `q` domain, mirroring @quality_ranges in AudioProxy.Options.
  # Expressed in thousandths so the generator can walk the whole range,
  # fractional values included — aac's band is barely one unit wide.
  @quality_ranges %{
    "mp3" => 0..9_000,
    "ogg" => -1_000..10_000,
    "aac" => 100..2_000,
    "m4a" => 100..2_000,
    "opus" => 0..10_000,
    "flac" => 0..12_000
  }

  @doc "A shuffled list of segments describing one valid variant."
  def option_segments do
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

  @doc """
  A request option's segments — the class that is signed but not cache-keyed.

  Deliberately *not* folded into `option_segments/0`. That generator describes a
  variant, and every property resting on it — normalization, the cache key, the
  argv — is a statement about variants. What a request option needs asserted is
  the opposite statement, so it is generated separately and added by the one
  property that makes it.
  """
  def request_option_segments do
    map(integer(1..253_402_300_799), &["exp:#{&1}"])
  end

  # Peaks refuse every encoding and loudness option, so generate none of them.
  defp encoding("peaks"), do: constant([])

  # `br` and `q` are mutually exclusive, so at most one is ever emitted — and
  # each only for the formats whose encoder has the knob: no `br` on a
  # lossless format, no `q` on PCM.
  defp encoding(format) do
    gen all(
          bitrate_or_quality <- one_of([constant([])] ++ bitrate(format) ++ quality(format)),
          sample_rate <- maybe(sample_rate(format))
        ) do
      bitrate_or_quality ++ sample_rate
    end
  end

  defp bitrate(format) when format in @lossy, do: [map(integer(32..320), &["br:#{&1}"])]
  defp bitrate(_format), do: []

  defp quality(format) do
    case Map.fetch(@quality_ranges, format) do
      {:ok, range} -> [map(integer(range), &["q:#{decimal(&1)}"])]
      :error -> []
    end
  end

  defp sample_rate(format) when format in @lossy do
    map(member_of([8000, 16_000, 22_050, 32_000, 44_100, 48_000]), &["sr:#{&1}"])
  end

  defp sample_rate(_format) do
    map(member_of([44_100, 48_000, 88_200, 96_000, 192_000]), &["sr:#{&1}"])
  end

  # A float depth lives in wav alone; flac encodes integers only.
  defp bit_depth("wav"), do: maybe(map(member_of(~w(16 24 32f)), &["bd:#{&1}"]))
  defp bit_depth("flac"), do: maybe(map(member_of(~w(16 24)), &["bd:#{&1}"]))
  defp bit_depth(_format), do: constant([])

  # Returns the segments plus the trim duration in milliseconds (or nil for
  # an open-ended trim), which bounds the fade generated next.
  defp trim do
    one_of([
      constant({[], nil}),
      constant({["t:-0"], nil}),
      map(millis(0..600_000), fn start -> {["t:#{decimal(start)}"], nil} end),
      gen all(start <- millis(0..600_000), duration <- millis(1_000..300_000)) do
        {["t:#{decimal(start)}:#{decimal(duration)}"], duration}
      end
    ])
  end

  # Without a bounded trim there is no duration to count a fade-out back from,
  # so only the in-fade is reachable — in both its spellings.
  defp fade(nil) do
    maybe(
      one_of([
        gen all(fade_in <- millis(0..5_000), explicit_out <- boolean()) do
          if explicit_out do
            ["fade:#{decimal(fade_in)}:0"]
          else
            ["fade:#{decimal(fade_in)}"]
          end
        end,
        constant(["fade:-0"]),
        constant(["fade:-0:-0"])
      ])
    )
  end

  # Splits the whole trim budget between the two halves rather than capping
  # each at half of it, so asymmetric splits that sum EXACTLY to the duration
  # are reachable. The old halve-each bound could only ever hit the boundary
  # symmetrically, which is the one case IEEE addition gets right — it hid a
  # real bug (0.1 + 0.2 > 0.3).
  defp fade(duration_ms) do
    maybe(
      one_of([
        gen all(
              fade_in <- millis(0..duration_ms),
              fade_out <- millis(0..(duration_ms - fade_in))
            ) do
          ["fade:#{decimal(fade_in)}:#{decimal(fade_out)}"]
        end,
        constant(["fade:-0:-0"])
      ])
    )
  end

  defp gain("peaks"), do: constant([])

  # `-0` included on purpose: it renders as "0" and so shares a cache key with
  # `gain:0`, which makes it the cheapest way for a property to catch a builder
  # that treats the two differently.
  defp gain(_format) do
    one_of([
      map(millis(-30_000..30_000), &["gain:#{decimal(&1)}"]),
      constant(["gain:-0"]),
      constant(["gain:0"])
    ])
  end

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

  @doc """
  Renders `millis` as seconds with three decimal places.

  Always three, even for a whole number of seconds: a legal but non-canonical
  spelling, so the normalized form is never simply the input echoed back.
  """
  def decimal(millis) do
    sign = if millis < 0, do: "-", else: ""
    magnitude = abs(millis)
    fraction = magnitude |> rem(1000) |> Integer.to_string() |> String.pad_leading(3, "0")

    "#{sign}#{div(magnitude, 1000)}.#{fraction}"
  end
end
