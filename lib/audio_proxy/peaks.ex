defmodule AudioProxy.Peaks do
  @moduledoc """
  Raw `s16le` PCM in, waveform peaks out (API doc §3.3).

  ffmpeg does the decoding, the trim and the downmix — see
  `AudioProxy.Ffmpeg.Command`'s peaks note — and hands over interleaved 16-bit
  little-endian samples. This module does the arithmetic: reduce those samples
  to `pts` min/max pairs and serialize them in one of audiowaveform's two
  formats, which is the schema decision recorded in CLAUDE.md. There is
  nothing to invent here; peaks.js and the rest of that ecosystem already read
  these bytes.

  ## Streaming, not buffering

  `feed/2` consumes chunks as they arrive and keeps only the reduced result:
  four integers per pixel for stereo, two for mono, plus at most one partial
  frame of carry-over. A ten-minute source is tens of megabytes of PCM and a
  few kilobytes of peaks, and only the second number is ever resident.

  That is why the reducer is built from a *sample count* rather than from the
  stream (`new/2`): bucket boundaries have to be known before the first sample
  arrives, and the count comes from `AudioProxy.Ffmpeg.Probe` running ahead of
  the decode. `samples_per_pixel` is `ceil(frames / count)`, so the last
  bucket may be short.

  ## When the probe and the decode disagree

  They can, by a frame or two — a duration in the container header is not a
  promise about how many samples a decoder will produce. Both directions are
  absorbed rather than reported:

    * **more** samples than expected fold into the final bucket, which is why
      that bucket alone never closes on width;
    * **fewer** leave trailing buckets empty, and those serialize as `0, 0`.

  So `length` is always exactly the `pts` that was asked for, whatever the
  decoder did, which is what makes the output shape a function of the URL.

  ## Chunk boundaries are not sample boundaries

  A port hands over whatever the OS had, so a chunk can end mid-sample or
  mid-frame. The leftover bytes are carried into the next `feed/2`, and the
  reduction is therefore independent of how the stream was cut — the property
  test that random-chunks the same PCM is the statement of it.

      iex> pcm = <<100::little-signed-16, -200::little-signed-16, 50::little-signed-16>>
      iex> AudioProxy.Peaks.new(3, count: 3) |> AudioProxy.Peaks.feed(pcm)
      ...> |> AudioProxy.Peaks.finish() |> Map.fetch!(:data)
      [100, 100, -200, -200, 50, 50]
  """

  alias AudioProxy.Options

  # Every sample is 16-bit, so `bits` is a constant rather than a knob. The
  # dat format carries an 8-bit mode; offering it would mean a second cache
  # key for a coarser picture nobody asked for.
  @bits 16

  # audiowaveform's data format version. v2 is v1 plus the channel count, and
  # emitting it unconditionally keeps mono and stereo one code path.
  @dat_version 2

  # v2 flag bits: 0 is 16-bit samples, 1 would be 8-bit. See @bits.
  @dat_flags 0

  # Sentinels for an untouched bucket, deliberately at the far end of each
  # bound so the first sample replaces both. A bucket is only ever closed
  # after at least one sample, so these cannot reach the output; the padding
  # in `finish/1` emits an honest zero pair instead.
  @empty_mono {32_767, -32_768}
  @empty_stereo {32_767, -32_768, 32_767, -32_768}

  @typedoc """
  A reduction in progress. Opaque — build with `new/2`, drive with `feed/2`.
  """
  @opaque t :: %__MODULE__{}

  @typedoc """
  The finished reduction, ready to serialize.

  `data` is interleaved min/max per channel per pixel, so it holds
  `length * 2 * channels` integers, exactly as audiowaveform's JSON does.
  """
  @type result :: %{
          version: 2,
          channels: 1 | 2,
          sample_rate: pos_integer(),
          samples_per_pixel: pos_integer(),
          bits: 16,
          length: pos_integer(),
          data: [integer()]
        }

  defstruct [
    :count,
    :channels,
    :sample_rate,
    :samples_per_pixel,
    :acc,
    :remaining,
    closed: [],
    n_closed: 0,
    leftover: <<>>
  ]

  @doc """
  A reducer for `frames` frames of PCM.

  A *frame* is one sample per channel, so `frames` is the sample count of one
  channel and not the number of integers on the wire.

  Options:

    * `:count` — how many min/max pairs to produce (`pts`); required.
    * `:channels` — 1 or 2, matching the `-ac` the decode was given.
      Defaults to 1.
    * `:sample_rate` — carried into the serialized output, where consumers use
      it to turn a pixel index into a time. Defaults to 0, meaning unknown.
  """
  @spec new(non_neg_integer(), keyword()) :: t()
  def new(frames, opts) when is_integer(frames) and frames >= 0 do
    count = Keyword.fetch!(opts, :count)
    channels = Keyword.get(opts, :channels, 1)
    # At least one: a source shorter than `pts` frames still gets one frame per
    # pixel, and the pixels past its end are the padding described above.
    samples_per_pixel = max(ceil_div(frames, count), 1)

    %__MODULE__{
      count: count,
      channels: channels,
      sample_rate: Keyword.get(opts, :sample_rate, 0),
      samples_per_pixel: samples_per_pixel,
      acc: empty(channels),
      remaining: samples_per_pixel
    }
  end

  @doc """
  A reducer configured from `options` — the `pts` and `ch` half of the URL —
  plus what only the probe knows.
  """
  @spec new(non_neg_integer(), Options.t(), pos_integer()) :: t()
  def new(frames, %Options{} = options, sample_rate) do
    new(frames,
      count: Options.peak_count(options),
      channels: Options.peak_channels(options),
      sample_rate: sample_rate
    )
  end

  @doc """
  Folds a chunk of interleaved `s16le` PCM into the reduction.

  Any trailing bytes that do not complete a frame are carried to the next
  call, so chunk boundaries do not have to fall anywhere in particular.
  """
  @spec feed(t(), binary()) :: t()
  def feed(%__MODULE__{} = state, <<>>), do: state

  def feed(%__MODULE__{channels: 1} = state, data) do
    {acc, remaining, closed, n_closed, leftover} =
      scan_mono(
        state.leftover <> data,
        state.acc,
        state.remaining,
        state.closed,
        state.n_closed,
        state.count - 1,
        state.samples_per_pixel
      )

    %{
      state
      | acc: acc,
        remaining: remaining,
        closed: closed,
        n_closed: n_closed,
        leftover: leftover
    }
  end

  def feed(%__MODULE__{channels: 2} = state, data) do
    {acc, remaining, closed, n_closed, leftover} =
      scan_stereo(
        state.leftover <> data,
        state.acc,
        state.remaining,
        state.closed,
        state.n_closed,
        state.count - 1,
        state.samples_per_pixel
      )

    %{
      state
      | acc: acc,
        remaining: remaining,
        closed: closed,
        n_closed: n_closed,
        leftover: leftover
    }
  end

  @doc """
  Closes the reduction and returns the audiowaveform-shaped result.

  The bucket in progress is closed if anything reached it, and the tail is
  padded to `count` pairs. A partial final frame — the decoder stopped
  mid-sample — is discarded rather than being read as a sample it is not.
  """
  @spec finish(t()) :: result()
  def finish(%__MODULE__{} = state) do
    closed =
      if state.acc == empty(state.channels) do
        state.closed
      else
        [state.acc | state.closed]
      end

    data =
      closed
      |> Enum.reverse()
      |> Enum.flat_map(&Tuple.to_list/1)
      |> pad(state.count * 2 * state.channels)

    %{
      version: @dat_version,
      channels: state.channels,
      sample_rate: state.sample_rate,
      samples_per_pixel: state.samples_per_pixel,
      bits: @bits,
      length: state.count,
      data: data
    }
  end

  @doc """
  audiowaveform's JSON serialization: the keys of `t:result/0`, verbatim.

      iex> pcm = <<-3000::little-signed-16, 9000::little-signed-16>>
      iex> AudioProxy.Peaks.new(2, count: 1, sample_rate: 8000)
      ...> |> AudioProxy.Peaks.feed(pcm) |> AudioProxy.Peaks.finish()
      ...> |> AudioProxy.Peaks.to_json() |> JSON.decode!()
      %{"version" => 2, "channels" => 1, "sample_rate" => 8000,
        "samples_per_pixel" => 2, "bits" => 16, "length" => 1,
        "data" => [-3000, 9000]}
  """
  @spec to_json(result()) :: binary()
  def to_json(result), do: JSON.encode!(result)

  @doc """
  audiowaveform's binary serialization: a little-endian v2 header followed by
  the same integers as `int16`.

  The header is version, flags, sample rate, samples per pixel, length and
  channel count, in that order — six 32-bit fields, and then the data. A
  consumer decoding this and the JSON above gets identical pairs, which is the
  round-trip the spec asks for.
  """
  @spec to_dat(result()) :: binary()
  def to_dat(result) do
    header = <<
      @dat_version::little-signed-32,
      @dat_flags::little-unsigned-32,
      result.sample_rate::little-signed-32,
      result.samples_per_pixel::little-signed-32,
      result.length::little-unsigned-32,
      result.channels::little-signed-32
    >>

    body = for value <- result.data, do: <<value::little-signed-16>>

    IO.iodata_to_binary([header | body])
  end

  @doc """
  Serializes for `format` — the `pk_fmt` half of the URL.
  """
  @spec serialize(result(), Options.peak_format()) :: binary()
  def serialize(result, :json), do: to_json(result)
  def serialize(result, :dat), do: to_dat(result)

  ## Reduction

  # Two hand-written loops rather than one generic one, because this is the
  # only hot path in the project: a five-minute mono source is thirteen
  # million iterations, and a per-frame list or map would dominate the render.
  # `ch` is 1 or 2 and nothing else, so there is no third case to miss.
  #
  # `limit` is the index of the final bucket. Reaching it switches the loop
  # into its accumulate-forever clause, which is how extra samples from a
  # decode that outran its probe fold in instead of overflowing `count`.

  defp scan_mono(
         <<sample::little-signed-16, rest::binary>>,
         {lo, hi},
         remaining,
         closed,
         n,
         limit,
         spp
       )
       when remaining > 1 or n >= limit do
    scan_mono(rest, {min(lo, sample), max(hi, sample)}, remaining - 1, closed, n, limit, spp)
  end

  defp scan_mono(
         <<sample::little-signed-16, rest::binary>>,
         {lo, hi},
         _remaining,
         closed,
         n,
         limit,
         spp
       ) do
    bucket = {min(lo, sample), max(hi, sample)}

    scan_mono(rest, @empty_mono, spp, [bucket | closed], n + 1, limit, spp)
  end

  defp scan_mono(leftover, acc, remaining, closed, n, _limit, _spp) do
    {acc, remaining, closed, n, leftover}
  end

  defp scan_stereo(
         <<left::little-signed-16, right::little-signed-16, rest::binary>>,
         {llo, lhi, rlo, rhi},
         remaining,
         closed,
         n,
         limit,
         spp
       )
       when remaining > 1 or n >= limit do
    acc = {min(llo, left), max(lhi, left), min(rlo, right), max(rhi, right)}

    scan_stereo(rest, acc, remaining - 1, closed, n, limit, spp)
  end

  defp scan_stereo(
         <<left::little-signed-16, right::little-signed-16, rest::binary>>,
         {llo, lhi, rlo, rhi},
         _remaining,
         closed,
         n,
         limit,
         spp
       ) do
    bucket = {min(llo, left), max(lhi, left), min(rlo, right), max(rhi, right)}

    scan_stereo(rest, @empty_stereo, spp, [bucket | closed], n + 1, limit, spp)
  end

  defp scan_stereo(leftover, acc, remaining, closed, n, _limit, _spp) do
    {acc, remaining, closed, n, leftover}
  end

  defp empty(1), do: @empty_mono
  defp empty(2), do: @empty_stereo

  # Trailing pixels the decode never reached. A flat zero line is the honest
  # picture of "no samples here" and is what audiowaveform itself writes.
  defp pad(data, width) do
    case width - length(data) do
      missing when missing > 0 -> data ++ List.duplicate(0, missing)
      _complete -> data
    end
  end

  defp ceil_div(_numerator, 0), do: 0
  defp ceil_div(numerator, denominator), do: div(numerator + denominator - 1, denominator)
end
