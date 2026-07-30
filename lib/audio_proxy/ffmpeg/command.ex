defmodule AudioProxy.Ffmpeg.Command do
  @moduledoc """
  Normalized options → ffmpeg argument vector (API doc §3).

  This is the last leg of the round-trip the project is built around: parse →
  normalize → cache key → **identical ffmpeg args**. `build/2` is a pure
  function of a validated `t:AudioProxy.Options.t/0` and the input URL, so two
  option strings that normalize alike produce byte-identical argv, which is
  what makes a cache key a promise about bytes rather than about a URL.

      iex> {:ok, opts} = AudioProxy.Options.parse("f:opus/br:96/t:12.5:30/fade:0.5:1")
      iex> AudioProxy.Ffmpeg.Command.build(opts, "https://example.test/a.wav")
      ["-nostdin", "-hide_banner", "-loglevel", "error",
       "-ss", "12.5", "-t", "30", "-i", "https://example.test/a.wav",
       "-vn", "-af", "afade=t=in:st=0:d=0.5,afade=t=out:st=29:d=1",
       "-c:a", "libopus", "-b:a", "96k", "-f", "ogg", "pipe:1"]

  ## Shape of the argv

  Arguments are emitted in a fixed order and never conditionally reordered —
  list equality is the tested contract, so a stable shape is the whole point:

    1. baseline flags (`-nostdin -hide_banner -loglevel error`),
    2. input-side seek (`-ss`/`-t`) **before** `-i`,
    3. the input URL as one argv element,
    4. `-vn` (sources carry cover art; we ship audio),
    5. the filtergraph, then `-ac`, then the codec/muxer arguments,
    6. `-f <muxer> pipe:1`.

  Seeking before `-i` is not a micro-optimization: ffmpeg's HTTP client turns
  it into a Range request, so `t:3600:30` on a two-hour master reads the
  thirty seconds it needs and nothing else. That is the reason sources are
  handed to ffmpeg as presigned URLs instead of piped through the BEAM.
  Because the seek happens on the input, the trimmed region starts at t=0 for
  everything downstream, which is exactly the frame `fade` is specified in.

  ## Injection safety

  There is no shell. The argv is a flat list of complete arguments, so a
  source URL containing `;`, `$(…)`, quotes or spaces is one element and stays
  data. Nothing user-supplied reaches the filtergraph either: `dl` and `cb`
  never appear in argv at all, and every filter value is a number that
  `AudioProxy.Options` has already parsed and bounded, re-rendered here
  through `AudioProxy.Options.render_number/1`.

  ## Filter order

  The chain is `loudnorm → volume → aresample → afade`, and the order is
  load-bearing:

    * `loudnorm` first, because normalizing after a static `gain` would undo
      it — `gain` with `norm` means "normalize, then offset".
    * `aresample` after `loudnorm`, because single-pass `loudnorm` resamples
      its output to 192 kHz. When `norm` is given without `sr` we therefore
      append `aresample=48000` ourselves; without it every normalized render
      would be a 192 kHz file (or a silent auto-resample by the encoder).
      48 kHz is the API's own lossy ceiling (§3.1) and universally supported,
      but it does mean `norm` on a 96 kHz lossless master downsamples. Fixing
      that needs the source's real rate, which this module deliberately does
      not know.
    * `afade` last, so the fade shape survives the stages above it.

  ## Peaks

  `f:peaks` builds raw interleaved `s16le` PCM on stdout — the input to the
  peak reducer, not its output. Encoding and loudness options are already
  refused for peaks by `AudioProxy.Options`; `t`, `ch` and `fade` apply,
  since all three change the samples a waveform would be drawn from. The
  peaks slice extends this module with the reduction itself.
  """

  alias AudioProxy.Options

  @baseline ~w(-nostdin -hide_banner -loglevel error)

  # Muxer per format. Always explicit: stdout has no filename to infer from.
  @muxers %{
    mp3: "mp3",
    opus: "ogg",
    ogg: "ogg",
    aac: "adts",
    m4a: "mp4",
    flac: "flac",
    wav: "wav"
  }

  # Encoder per format. `wav` is absent: its encoder is the bit depth (`bd`).
  @codecs %{
    mp3: "libmp3lame",
    opus: "libopus",
    ogg: "libvorbis",
    aac: "aac",
    m4a: "aac",
    flac: "flac"
  }

  # `q` is a VBR quality scale for the codecs that have one, and the
  # effort/size knob for the two that do not (§3.1 calls it "codec-specific"
  # on purpose). `AudioProxy.Options` rejects `q` for the formats missing
  # from this table.
  @quality_flags %{
    mp3: "-q:a",
    ogg: "-q:a",
    aac: "-q:a",
    m4a: "-q:a",
    opus: "-compression_level",
    flac: "-compression_level"
  }

  @pcm_codecs %{bd16: "pcm_s16le", bd24: "pcm_s24le", bd32f: "pcm_f32le"}

  # flac is integer-only (encoder sample formats: s16, s32); `bd:32f` with
  # `f:flac` is refused at the options layer rather than mapped here.
  @flac_sample_formats %{bd16: "s16", bd24: "s32"}

  @default_pcm_codec "pcm_s16le"

  @content_types %{
    mp3: "audio/mpeg",
    opus: "audio/ogg",
    ogg: "audio/ogg",
    aac: "audio/aac",
    m4a: "audio/mp4",
    flac: "audio/flac",
    wav: "audio/wav"
  }

  @peaks_content_types %{json: "application/json", dat: "application/octet-stream"}

  # loudnorm's output rate; see the moduledoc's filter-order note.
  @loudnorm_output_rate 48_000

  @doc """
  Builds the ffmpeg argument vector for `options` reading from `input_url`.

  `options` must already be valid — `AudioProxy.Options.parse/1` and
  `validate/1` are the gate, and every rule they enforce is a precondition
  here (a bounded trim behind every fade-out, a lossless format behind every
  `bd`, and so on). `input_url` is passed through verbatim as a single argv
  element; it is never parsed, escaped, or interpolated.

  The result is the argument list *after* the program name, ready for
  `Port.open/2` with `:args`.

      iex> {:ok, opts} = AudioProxy.Options.parse("f:wav/bd:24")
      iex> AudioProxy.Ffmpeg.Command.build(opts, "s3://b/k.aif") |> Enum.take(-6)
      ["-vn", "-c:a", "pcm_s24le", "-f", "wav", "pipe:1"]
  """
  @spec build(Options.t(), String.t()) :: [String.t()]
  def build(%Options{} = options, input_url) when is_binary(input_url) do
    @baseline ++
      input_args(options) ++
      ["-i", input_url, "-vn"] ++
      filter_args(options) ++
      channel_args(options) ++
      output_args(options) ++
      ["-f", muxer(options), "pipe:1"]
  end

  @doc """
  The Content-Type for a variant.

  Takes a format atom, or an `t:AudioProxy.Options.t/0` — peaks need the
  latter, since `pk_fmt` decides between JSON and the compact binary form.

      iex> AudioProxy.Ffmpeg.Command.content_type(:m4a)
      "audio/mp4"

      iex> {:ok, opts} = AudioProxy.Options.parse("f:peaks/pk_fmt:dat")
      iex> AudioProxy.Ffmpeg.Command.content_type(opts)
      "application/octet-stream"
  """
  @spec content_type(Options.t() | Options.format()) :: String.t()
  def content_type(%Options{format: :peaks} = options) do
    Map.fetch!(@peaks_content_types, options.peak_format || :json)
  end

  def content_type(%Options{format: format}), do: content_type(format)
  def content_type(:peaks), do: Map.fetch!(@peaks_content_types, :json)
  def content_type(format) when is_atom(format), do: Map.fetch!(@content_types, format)

  ## Input side

  # `-ss`/`-t` before `-i`: input seeking, so the HTTP input ranges rather
  # than reads-and-discards. An open-ended `t:30` emits no `-t`.
  defp input_args(%Options{trim_start: nil, trim_duration: nil}), do: []

  defp input_args(%Options{} = options) do
    seek = ["-ss", number(options.trim_start || 0.0)]

    case options.trim_duration do
      nil -> seek
      duration -> seek ++ ["-t", number(duration)]
    end
  end

  ## Filters

  defp filter_args(%Options{} = options) do
    case Enum.filter(filters(options), & &1) do
      [] -> []
      filters -> ["-af", Enum.join(filters, ",")]
    end
  end

  defp filters(%Options{} = options) do
    [
      loudnorm(options.norm),
      volume(options.gain),
      resample(options),
      fade_in(options.fade_in),
      fade_out(options)
    ]
  end

  defp loudnorm(nil), do: nil

  defp loudnorm({i, tp, lra}) do
    "loudnorm=I=#{number(i)}:TP=#{number(tp)}:LRA=#{number(lra)}"
  end

  defp volume(nil), do: nil
  defp volume(gain), do: "volume=#{number(gain)}dB"

  # An explicit `sr` always resamples. Without one, `norm` still forces a
  # resample, because single-pass loudnorm hands back 192 kHz.
  defp resample(%Options{sample_rate: nil, norm: nil}), do: nil
  defp resample(%Options{sample_rate: nil}), do: "aresample=#{@loudnorm_output_rate}"
  defp resample(%Options{sample_rate: rate}), do: "aresample=#{rate}"

  defp fade_in(nil), do: nil
  defp fade_in(+0.0), do: nil
  defp fade_in(seconds), do: "afade=t=in:st=0:d=#{number(seconds)}"

  # The fade-out has to start at `duration - out`, so it needs a bounded trim;
  # `AudioProxy.Options` requires one. Subtracting in whole milliseconds keeps
  # the start exact — 30 - 1.0 is fine in binary floats, 0.3 - 0.2 is not.
  defp fade_out(%Options{fade_out: nil}), do: nil
  defp fade_out(%Options{fade_out: +0.0}), do: nil

  defp fade_out(%Options{fade_out: seconds, trim_duration: duration}) do
    start = (millis(duration) - millis(seconds)) / 1000

    "afade=t=out:st=#{number(start)}:d=#{number(seconds)}"
  end

  defp millis(seconds), do: round(seconds * 1000)

  defp channel_args(%Options{channels: nil}), do: []
  defp channel_args(%Options{channels: channels}), do: ["-ac", Integer.to_string(channels)]

  ## Output side

  defp muxer(%Options{format: :peaks}), do: "s16le"
  defp muxer(%Options{format: format}), do: Map.fetch!(@muxers, format)

  # Peaks are decoded samples, not an encode: no bitrate, no quality, no
  # container flags — just interleaved PCM for the reducer to chew on.
  defp output_args(%Options{format: :peaks}), do: ["-c:a", @default_pcm_codec]

  defp output_args(%Options{} = options) do
    ["-c:a", codec(options)] ++
      bitrate_args(options) ++
      quality_args(options) ++
      sample_format_args(options) ++
      container_args(options)
  end

  defp codec(%Options{format: :wav} = options) do
    Map.get(@pcm_codecs, options.bit_depth, @default_pcm_codec)
  end

  defp codec(%Options{format: format}), do: Map.fetch!(@codecs, format)

  # `br` is kbps in the URL grammar; `k` makes that explicit to ffmpeg rather
  # than relying on it reading a bare 96 as bits per second.
  defp bitrate_args(%Options{bitrate: nil}), do: []
  defp bitrate_args(%Options{bitrate: bitrate}), do: ["-b:a", "#{bitrate}k"]

  defp quality_args(%Options{quality: nil}), do: []

  defp quality_args(%Options{format: format, quality: quality}) do
    [Map.fetch!(@quality_flags, format), number(quality)]
  end

  # `bd` is the encoder itself for wav (handled in codec/1) and a sample
  # format for flac.
  defp sample_format_args(%Options{format: :flac, bit_depth: depth}) when not is_nil(depth) do
    ["-sample_fmt", Map.fetch!(@flac_sample_formats, depth)]
  end

  defp sample_format_args(%Options{}), do: []

  # Plain MP4 needs a seekable output to write its moov atom; stdout is not
  # one. Fragmented MP4 streams instead, which is the only reason `m4a` can
  # be offered at all.
  defp container_args(%Options{format: :m4a}), do: ["-movflags", "frag_keyframe+empty_moov"]
  defp container_args(%Options{}), do: []

  defp number(number), do: Options.render_number(number)
end
