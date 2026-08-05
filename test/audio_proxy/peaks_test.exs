defmodule AudioProxy.PeaksTest do
  @moduledoc """
  The reduction against PCM built by hand, so every expected pair is a number
  this file states rather than a number a decoder happened to produce.

  Real audio arrives in the `@tag :ffmpeg` integration tests; what is checked
  here is the arithmetic those tests cannot pin — exact bucket boundaries, the
  partial final bucket, what happens when the decode outruns or falls short of
  its probe, and the two serializations agreeing.
  """

  use ExUnit.Case, async: true

  alias AudioProxy.{Options, Peaks}

  doctest Peaks

  defp pcm(samples), do: for(s <- samples, into: <<>>, do: <<s::little-signed-16>>)

  defp reduce(samples, frames, opts) do
    frames
    |> Peaks.new(opts)
    |> Peaks.feed(pcm(samples))
    |> Peaks.finish()
  end

  defp data(samples, frames, opts), do: reduce(samples, frames, opts).data

  describe "new/2 and the bucket grid" do
    test "samples_per_pixel is the ceiling, so the last bucket may be short" do
      assert reduce([], 800, count: 800).samples_per_pixel == 1
      assert reduce([], 1600, count: 800).samples_per_pixel == 2
      # 1601 frames over 800 pixels: 2 each, and the last holds one.
      assert reduce([], 1601, count: 800).samples_per_pixel == 3
    end

    test "a source shorter than pts still gets one frame per pixel" do
      assert reduce([], 10, count: 800).samples_per_pixel == 1
      assert reduce([], 0, count: 800).samples_per_pixel == 1
    end
  end

  describe "feed/2 — mono" do
    test "a ramp reduces to its per-bucket extremes" do
      # 8 frames, 4 pixels: pairs are (0,1), (2,3), (4,5), (6,7).
      assert data([0, 1, 2, 3, 4, 5, 6, 7], 8, count: 4) == [0, 1, 2, 3, 4, 5, 6, 7]
    end

    test "alternating extremes give full-scale pairs in every bucket" do
      samples = List.duplicate([-32_768, 32_767], 8) |> List.flatten()

      assert data(samples, 16, count: 4) ==
               [-32_768, 32_767, -32_768, 32_767, -32_768, 32_767, -32_768, 32_767]
    end

    test "silence is pairs of zero" do
      assert data(List.duplicate(0, 16), 16, count: 4) == [0, 0, 0, 0, 0, 0, 0, 0]
    end

    test "a partial final bucket holds only the frames that reached it" do
      # 5 frames over 2 pixels: 3 each, so the second holds two.
      assert data([1, 2, 3, 40, 50], 5, count: 2) == [1, 3, 40, 50]
    end

    test "a bucket keeps the minimum and the maximum, not the first and last" do
      assert data([5, -9, 7, 0], 4, count: 1) == [-9, 7]
    end
  end

  describe "feed/2 — stereo" do
    test "each channel gets its own pair, interleaved per pixel" do
      # Frames are (L, R): (1,-1), (2,-2) | (3,-3), (4,-4)
      samples = [1, -1, 2, -2, 3, -3, 4, -4]

      assert data(samples, 4, count: 2, channels: 2) == [1, 2, -2, -1, 3, 4, -4, -3]
    end

    test "data holds length * 2 * channels integers" do
      result = reduce([1, -1, 2, -2], 2, count: 8, channels: 2)

      assert result.length == 8
      assert length(result.data) == 8 * 2 * 2
    end
  end

  describe "finish/1 — probe and decode disagreeing" do
    test "fewer samples than expected leave trailing pixels flat" do
      # Sized for 8 frames over 4 pixels (2 each), given 2: one real pair, and
      # three pixels the decode never reached.
      assert data([10, -10], 8, count: 4) == [-10, 10, 0, 0, 0, 0, 0, 0]
    end

    test "more samples than expected fold into the final pixel" do
      # Sized for 4 frames over 2 pixels (2 each), given 6. The extras cannot
      # become a third pixel — `length` is what the URL asked for — so the
      # final pixel widens to hold them.
      result = reduce([1, 2, 3, 4, 5, -99], 4, count: 2)

      assert result.length == 2
      assert result.data == [1, 2, -99, 5]
    end

    test "length is always pts, whatever the decoder produced" do
      for given <- [0, 1, 7, 800, 5_000] do
        samples = Enum.map(1..given//1, & &1)

        assert reduce(samples, 800, count: 800).length == 800
        assert length(reduce(samples, 800, count: 800).data) == 1_600
      end
    end
  end

  describe "feed/2 — chunk seams" do
    # The reduction must not depend on how the port cut the stream, including
    # cuts that land inside a sample or between a frame's two channels.
    test "an odd-byte chunk boundary splits a sample and still reduces alike" do
      samples = Enum.map(1..64, &(&1 * 100))
      whole = pcm(samples)

      for split <- [1, 3, 7, 63, 127] do
        <<head::binary-size(^split), tail::binary>> = whole

        streamed =
          128
          |> Peaks.new(count: 16)
          |> Peaks.feed(head)
          |> Peaks.feed(tail)
          |> Peaks.finish()

        assert streamed == reduce(samples, 128, count: 16)
      end
    end

    test "a stereo stream cut between a frame's channels still reduces alike" do
      samples = Enum.flat_map(1..32, &[&1, -&1])
      whole = pcm(samples)
      <<head::binary-size(2), tail::binary>> = whole

      streamed =
        32
        |> Peaks.new(count: 8, channels: 2)
        |> Peaks.feed(head)
        |> Peaks.feed(tail)
        |> Peaks.finish()

      assert streamed == reduce(samples, 32, count: 8, channels: 2)
    end

    test "a trailing partial frame is discarded, not read as a sample" do
      complete = reduce([1, 2, 3, 4], 4, count: 2)

      truncated =
        4
        |> Peaks.new(count: 2)
        |> Peaks.feed(pcm([1, 2, 3, 4]) <> <<0xFF>>)
        |> Peaks.finish()

      assert truncated == complete
    end
  end

  describe "serialization" do
    setup do
      result = reduce([1, -2, 3, -4, 5, -6, 7, -8], 8, count: 4, sample_rate: 8_000)

      %{result: result}
    end

    test "JSON carries the audiowaveform schema", %{result: result} do
      decoded = result |> Peaks.to_json() |> JSON.decode!()

      assert decoded["version"] == 2
      assert decoded["channels"] == 1
      assert decoded["sample_rate"] == 8_000
      assert decoded["samples_per_pixel"] == 2
      assert decoded["bits"] == 16
      assert decoded["length"] == 4
      assert decoded["data"] == [-2, 1, -4, 3, -6, 5, -8, 7]

      assert length(decoded["data"]) == decoded["length"] * 2 * decoded["channels"]
      assert Enum.all?(decoded["data"], &(&1 >= -32_768 and &1 <= 32_767))
    end

    test "dat is a little-endian v2 header and int16 pairs", %{result: result} do
      assert <<
               version::little-signed-32,
               flags::little-unsigned-32,
               sample_rate::little-signed-32,
               samples_per_pixel::little-signed-32,
               length::little-unsigned-32,
               channels::little-signed-32,
               body::binary
             >> = Peaks.to_dat(result)

      assert {version, flags, sample_rate} == {2, 0, 8_000}
      assert {samples_per_pixel, length, channels} == {2, 4, 1}
      assert byte_size(body) == 4 * 2 * 1 * 2
    end

    test "decoding the dat body yields the JSON data, pair for pair", %{result: result} do
      <<_header::binary-size(24), body::binary>> = Peaks.to_dat(result)
      pairs = for <<value::little-signed-16 <- body>>, do: value

      assert pairs == JSON.decode!(Peaks.to_json(result))["data"]
    end

    test "serialize/2 dispatches on pk_fmt", %{result: result} do
      assert Peaks.serialize(result, :json) == Peaks.to_json(result)
      assert Peaks.serialize(result, :dat) == Peaks.to_dat(result)
    end
  end

  describe "new/3 — configured from options" do
    test "reads pts, the mono default, and an explicit ch:2" do
      {:ok, plain} = Options.parse("f:peaks")
      {:ok, stereo} = Options.parse("f:peaks/pts:4/ch:2")

      assert Peaks.new(1_000, plain, 44_100) |> Peaks.finish() |> Map.take([:length, :channels]) ==
               %{length: 800, channels: 1}

      assert Peaks.new(1_000, stereo, 44_100) |> Peaks.finish() |> Map.take([:length, :channels]) ==
               %{length: 4, channels: 2}
    end

    test "carries the probed sample rate into the output" do
      {:ok, opts} = Options.parse("f:peaks")

      assert Peaks.new(10, opts, 48_000) |> Peaks.finish() |> Map.fetch!(:sample_rate) == 48_000
    end
  end
end
