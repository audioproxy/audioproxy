defmodule AudioProxy.Ffmpeg.Command do
  @moduledoc """
  Normalized options → ffmpeg argument vector (API doc §3).

  This is the last leg of the round-trip the project is built around: parse →
  normalize → cache key → **identical ffmpeg args**. `build/2` is a pure
  function of a validated `t:AudioProxy.Options.t/0` and the input URL, so two
  option strings that normalize alike produce byte-identical argv, which is
  what makes a cache key a promise about bytes rather than about a URL.

      iex> {:ok, opts} = AudioProxy.Options.parse("f:opus/br:96/t:12.5:30/fade:0.5:1")
      iex> AudioProxy.Ffmpeg.Command.build(opts, "https://example.test/a.wav", type: :http)
      ["-nostdin", "-hide_banner", "-loglevel", "error",
       "-protocol_whitelist", "https,tls,tcp",
       "-ss", "12.5", "-t", "30", "-i", "https://example.test/a.wav",
       "-vn", "-sn", "-dn", "-af", "afade=t=in:st=0:d=0.5,afade=t=out:st=29:d=1",
       "-c:a", "libopus", "-b:a", "96k", "-f", "ogg", "pipe:1"]

  ## Shape of the argv

  Arguments are emitted in a fixed order and never conditionally reordered —
  list equality is the tested contract, so a stable shape is the whole point:

    1. baseline flags (`-nostdin -hide_banner -loglevel error`),
    2. the input protocol whitelist, before `-i` so it binds the input,
    3. input-side seek (`-ss`/`-t`) **before** `-i`,
    4. the input URL as one argv element,
    5. `-vn -sn -dn` (we ship audio, and nothing else — see *Audio only*),
    6. the filtergraph, then `-ac`, then the codec/muxer arguments,
    7. `-f <muxer> pipe:1`.

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

  No URL content can become an ffmpeg *flag*, either, and that is asserted
  rather than argued: `allowed_flags/0` publishes every flag this module can
  emit, and the property test walks a generated argv position by position,
  checking each flag against that list and each value against the flag it
  follows. A value that happens to start with `-` — `f:ogg/q:-1` renders
  `["-q:a", "-1"]` — is therefore not mistaken for a flag, and a flag that
  arrived from anywhere but this module has nowhere to hide.

  ## Audio only

  Every argv disables non-audio streams (`-vn -sn -dn`) and restricts ffmpeg's
  input protocols (`-protocol_whitelist`), unconditionally, for every format
  and for the peaks PCM path. Both are defence in depth behind the render
  action's probe gate, which is what actually rejects a video source with 415:
  these two are what hold if the gate is ever bypassed, reordered, or asked
  about a source it cannot see inside.

  The protocol set is derived from the **resolved source's type**, never from
  the input string and never from an env knob — a knob would reopen the hole
  this closes. The sets are disjoint by construction: a local source gets
  `file` and so cannot reach the network, a remote one gets `https,tls,tcp`
  and so cannot reach the filesystem. `concat:`, `subfile:` and friends are
  reachable from neither, which is what stops a crafted or redirecting source
  from pivoting ffmpeg across a boundary. See `protocols/1`.

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

  ## What the builder does not know

  `build/3` takes a `t:source/0` because two decisions genuinely cannot be made
  from the options alone. The protocol whitelist is one, and it is required.
  The other is optional: with no `bd`, a lossless variant should follow the
  source's own bit depth, the way `sr` follows its sample rate (§3.1). Until
  the `/info` probe exists to supply it, the fallback is 16-bit — documented,
  not silent.

  ## Peaks

  `f:peaks` builds raw interleaved `s16le` PCM on stdout — the input to the
  peak reducer, not its output. Encoding and loudness options are already
  refused for peaks by `AudioProxy.Options`; `t`, `ch` and `fade` apply,
  since all three change the samples a waveform would be drawn from. The
  peaks slice extends this module with the reduction itself.
  """

  alias AudioProxy.{Config, Options}

  @typedoc """
  What the builder needs to know about the source itself.

  `:type` is the resolved source's tag (`AudioProxy.Source.Type.tag/0`) and is
  **required**: it is what the input protocol whitelist is derived from, and a
  default would be a guess about which side of the network/filesystem boundary
  this render sits on. `:bit_depth` is optional, and exists because a lossless
  variant cannot pick a sane default without knowing the source's depth;
  omitting it keeps the documented 16-bit fallback.

  This does not weaken the round-trip invariant. The cache key hashes the
  normalized options *and* the source, so equal keys already imply the same
  source — and therefore the same type, the same source metadata, and the same
  argv.
  """
  @type source :: [type: source_type(), bit_depth: Options.bit_depth()]

  @typedoc "A resolved source's type tag, as its module reports it."
  @type source_type :: :local | :s3 | :http

  @baseline ~w(-nostdin -hide_banner -loglevel error)

  # Non-audio streams, disabled on the output side for every render. See the
  # moduledoc's *Audio only*.
  @audio_only ~w(-vn -sn -dn)

  # What a remote input needs and nothing more: TLS over TCP. No `file`, so a
  # redirect to `file:///etc/passwd` fails to open rather than being read.
  @remote_protocols "https,tls,tcp"

  # The same set plus cleartext, for a development S3 endpoint that speaks it
  # (`AP_S3_ENDPOINT=http://minio:9000`). Still no `file`.
  @plaintext_protocols "https,tls,tcp,http"

  # What a local input needs and nothing more. No network protocol, so a
  # source resolved to a path cannot make ffmpeg fetch anything.
  @local_protocols "file"

  # The complete flag vocabulary, each mapped to how many argv elements follow
  # it. Hand-maintained on purpose: adding a flag to `build/3` without adding
  # it here fails the allowlist property test, which is exactly the review this
  # table exists to force. Every entry is an audio, container or I/O flag —
  # there is no `-c:v`, `-vf`, `-filter:v` or `-map`, and `allowed_flags/0` is
  # asserted against that denylist rather than merely inspected.
  @flags %{
    "-nostdin" => 0,
    "-hide_banner" => 0,
    "-loglevel" => 1,
    "-protocol_whitelist" => 1,
    "-ss" => 1,
    "-t" => 1,
    "-i" => 1,
    "-vn" => 0,
    "-sn" => 0,
    "-dn" => 0,
    "-af" => 1,
    "-ac" => 1,
    "-c:a" => 1,
    "-b:a" => 1,
    "-q:a" => 1,
    "-compression_level" => 1,
    "-sample_fmt" => 1,
    "-movflags" => 1,
    "-frag_duration" => 1,
    "-f" => 1
  }

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

  # Fragment length for `f:m4a`, in microseconds. See `container_args/1`.
  @fragment_duration_us "1000000"

  @doc """
  Builds the ffmpeg argument vector for `options` reading from `input_url`.

  `options` must already be valid — `AudioProxy.Options.parse/1` and
  `validate/1` are the gate, and every rule they enforce is a precondition
  here (a bounded trim behind every fade-out, a lossless format behind every
  `bd`, and so on). `input_url` is passed through verbatim as a single argv
  element; it is never parsed, escaped, or interpolated.

  `source` must carry the resolved source's `:type` — see `t:source/0` and
  `protocols/1`.

  The result is the argument list *after* the program name, ready for
  `Port.open/2` with `:args`.

      iex> {:ok, opts} = AudioProxy.Options.parse("f:wav/bd:24")
      iex> AudioProxy.Ffmpeg.Command.build(opts, "/srv/audio/k.aif", type: :local)
      ...> |> Enum.take(-8)
      ["-vn", "-sn", "-dn", "-c:a", "pcm_s24le", "-f", "wav", "pipe:1"]

  With no `bd`, a lossless variant follows the source when its depth is known:

      iex> {:ok, opts} = AudioProxy.Options.parse("f:wav")
      iex> AudioProxy.Ffmpeg.Command.build(opts, "/srv/audio/k.aif",
      ...>   type: :local, bit_depth: :bd24)
      ...> |> Enum.take(-5)
      ["-c:a", "pcm_s24le", "-f", "wav", "pipe:1"]
  """
  @spec build(Options.t(), String.t(), source()) :: [String.t()]
  def build(%Options{} = options, input_url, source) when is_binary(input_url) do
    @baseline ++
      ["-protocol_whitelist", protocols(Keyword.fetch!(source, :type))] ++
      input_args(options) ++
      ["-i", input_url] ++
      @audio_only ++
      filter_args(options) ++
      channel_args(options) ++
      output_args(options, source) ++
      ["-f", muxer(options), "pipe:1"]
  end

  @doc """
  The ffmpeg input protocol whitelist for a resolved source's type.

  One entry per source type, and deliberately not configurable: the whole
  point is that the set follows from what the source *is*, so no request and
  no environment variable can widen it.

      iex> AudioProxy.Ffmpeg.Command.protocols(:local)
      "file"

      iex> AudioProxy.Ffmpeg.Command.protocols(:http)
      "https,tls,tcp"

  A source type added later has no clause here, so it raises rather than
  inheriting somebody else's protocol set — the same discipline
  `AudioProxy.ErrorJSON` applies to its own rows, and for the same reason: the
  mistake should crash that slice's tests, not quietly open a protocol.
  """
  @spec protocols(source_type()) :: String.t()
  def protocols(:local), do: @local_protocols
  def protocols(:http), do: @remote_protocols

  # An S3 source is handed to ffmpeg as a presigned URL, whose scheme is the
  # endpoint's. Against AWS that is always HTTPS; a dev deployment pointing at
  # `http://minio:9000` needs cleartext too, and this is the one place that
  # widening is allowed to come from — a *deployment fact*, not a knob, and
  # still no `file`.
  def protocols(:s3) do
    case Config.get(:s3).endpoint do
      %URI{scheme: "http"} -> @plaintext_protocols
      _tls_or_aws -> @remote_protocols
    end
  end

  @doc """
  Every flag `build/3` can ever emit, sorted.

  Published so the argv-allowlist property test compares against this module's
  own vocabulary rather than a copy that can drift. Two things are asserted
  against it: that every flag in a built argv is a member (reality ⊆
  allowlist), and that the list itself contains no video, subtitle or stream-
  mapping flag (allowlist ∩ denylist = ∅).
  """
  @spec allowed_flags() :: [String.t()]
  def allowed_flags, do: @flags |> Map.keys() |> Enum.sort()

  @doc """
  Whether `flag` is followed by a value argument.

  The other half of what the property test needs: without it, walking an argv
  cannot tell the flag `-t` from the *value* `-1` that `f:ogg/q:-1` renders,
  and a check that only looked at leading hyphens would have to choose between
  a false alarm and a hole.

      iex> AudioProxy.Ffmpeg.Command.takes_value?("-b:a")
      true

      iex> AudioProxy.Ffmpeg.Command.takes_value?("-vn")
      false
  """
  @spec takes_value?(String.t()) :: boolean()
  def takes_value?(flag) when is_binary(flag), do: Map.fetch!(@flags, flag) == 1

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
  defp output_args(%Options{format: :peaks}, _source), do: ["-c:a", @default_pcm_codec]

  defp output_args(%Options{} = options, source) do
    ["-c:a", codec(options, source)] ++
      bitrate_args(options) ++
      quality_args(options) ++
      sample_format_args(options) ++
      container_args(options)
  end

  # `bd` wins; otherwise wav follows the source, exactly as `sr` does (§3.1),
  # and falls back to 16-bit only when the source's depth is unknown. Without
  # this, `f:wav` on a 24-bit master silently returned 16-bit while `f:flac`
  # on the same master returned 24 — two lossless formats, two answers.
  defp codec(%Options{format: :wav, bit_depth: nil}, source) do
    case Keyword.get(source, :bit_depth) do
      nil -> @default_pcm_codec
      depth -> Map.get(@pcm_codecs, depth, @default_pcm_codec)
    end
  end

  defp codec(%Options{format: :wav} = options, _source) do
    Map.fetch!(@pcm_codecs, options.bit_depth)
  end

  defp codec(%Options{format: format}, _source), do: Map.fetch!(@codecs, format)

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
  # be offered at all — but only if it really fragments. `frag_keyframe`
  # starts a fragment at each video keyframe, and an audio-only stream has
  # none, so `empty_moov` alone produces one fragment flushed at EOF: on a
  # 20 s source the first byte arrives after 19.7 s. `-frag_duration` cuts on
  # time instead, which is what audio needs; `default_base_moof` is the
  # companion flag players expect on a fragmented stream.
  #
  # One second is the trade: 1 s to first byte, and 327275 bytes against the
  # unfragmented 328218 for a 20 s 128k render, i.e. the fragment headers cost
  # nothing measurable. Fragmenting per frame would cut latency to 0.2 s and
  # add 33%.
  defp container_args(%Options{format: :m4a}) do
    ["-movflags", "empty_moov+default_base_moof", "-frag_duration", @fragment_duration_us]
  end

  defp container_args(%Options{}), do: []

  defp number(number), do: Options.render_number(number)
end
