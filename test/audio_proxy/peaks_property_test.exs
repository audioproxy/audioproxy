defmodule AudioProxy.PeaksPropertyTest do
  @moduledoc """
  The one property the reduction has to hold: it is a function of the PCM, not
  of how the PCM arrived.

  A `Port` hands over whatever the OS had ready, so the same render can be cut
  into wildly different chunks on two runs — and a peaks variant that differed
  between them would be a cache key that does not name its bytes. Random
  chunkings, including cuts inside a sample, must all reduce alike.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AudioProxy.Peaks

  # Whole samples, so the generated stream is always a complete frame count and
  # the only ragged boundaries are the ones the chunking introduces.
  defp pcm_of(samples), do: for(s <- samples, into: <<>>, do: <<s::little-signed-16>>)

  defp reduce(chunks, frames, opts) do
    Enum.reduce(chunks, Peaks.new(frames, opts), &Peaks.feed(&2, &1))
    |> Peaks.finish()
  end

  # A random partition of `data` into consecutive chunks, sized without regard
  # for sample boundaries — which is the point.
  defp chunkings(data) do
    gen all(sizes <- list_of(integer(0..7), min_length: 1)) do
      Enum.reduce(sizes, {[], data}, fn size, {chunks, rest} ->
        size = min(size, byte_size(rest))
        <<chunk::binary-size(^size), remainder::binary>> = rest

        {[chunk | chunks], remainder}
      end)
      |> then(fn {chunks, rest} -> Enum.reverse([rest | chunks]) end)
    end
  end

  property "any chunking of the same PCM reduces to the same peaks" do
    check all(
            samples <- list_of(integer(-32_768..32_767), min_length: 1, max_length: 200),
            channels <- member_of([1, 2]),
            count <- integer(1..64),
            chunks <- chunkings(pcm_of(samples)),
            max_runs: 200
          ) do
      frames = div(length(samples), channels)
      opts = [count: count, channels: channels]

      assert reduce(chunks, frames, opts) == reduce([pcm_of(samples)], frames, opts)
    end
  end

  # The narrow picture is the wide one, narrowed. It is never a second,
  # independent reduction. Thus choosing a width is a resolution decision only.
  property "8-bit peaks are the 16-bit peaks divided by 256, truncated" do
    check all(
            samples <- list_of(integer(-32_768..32_767), min_length: 1, max_length: 200),
            channels <- member_of([1, 2]),
            count <- integer(1..64)
          ) do
      frames = div(length(samples), channels)
      opts = [count: count, channels: channels]

      wide = reduce([pcm_of(samples)], frames, opts)
      narrow = reduce([pcm_of(samples)], frames, [bits: 8] ++ opts)

      assert narrow.bits == 8
      assert narrow.data == Enum.map(wide.data, &div(&1, 256))
      assert Enum.all?(narrow.data, &(&1 in -128..127))
    end
  end

  property "json and dat carry the same values at both widths" do
    check all(
            samples <- list_of(integer(-32_768..32_767), min_length: 1, max_length: 200),
            channels <- member_of([1, 2]),
            count <- integer(1..64),
            bits <- member_of([8, 16])
          ) do
      frames = div(length(samples), channels)
      result = reduce([pcm_of(samples)], frames, count: count, channels: channels, bits: bits)

      <<_header::binary-size(24), body::binary>> = Peaks.to_dat(result)
      from_dat = for <<value::little-signed-size(bits) <- body>>, do: value

      assert from_dat == JSON.decode!(Peaks.to_json(result))["data"]
    end
  end

  property "the shape of the output is fixed by pts and ch alone" do
    check all(
            samples <- list_of(integer(-32_768..32_767), max_length: 200),
            channels <- member_of([1, 2]),
            count <- integer(1..64),
            # Deliberately unrelated to the sample count, standing in for a
            # probe that disagreed with the decode in either direction.
            frames <- integer(0..500)
          ) do
      result =
        reduce([pcm_of(samples)], frames, count: count, channels: channels)

      assert result.length == count
      assert length(result.data) == count * 2 * channels
      assert Enum.all?(result.data, &(&1 >= -32_768 and &1 <= 32_767))
    end
  end
end
