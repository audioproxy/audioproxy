defmodule AudioProxy.Ffmpeg.Command do
  @moduledoc """
  Normalized options → ffmpeg argument vector (API doc §3).

  This is the last leg of the round-trip the project is built around: parse →
  normalize → cache key → **identical ffmpeg args**. `build/3` is a pure
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

  The chain is `enhance → loudnorm → volume → aresample → afade`, and the
  order is load-bearing:

    * the `enhance` preset first, because it is source conditioning: it cleans
      up what was recorded, and every stage after it is a statement about the
      signal that comes out. Putting it after `loudnorm` would mean measuring
      loudness on audio the compressor was about to change, so the render would
      miss its own target.
    * `loudnorm` next, because normalizing after a static `gain` would undo
      it — `gain` with `norm` means "normalize, then offset".
    * `aresample` after `loudnorm`, because single-pass `loudnorm` resamples
      its output to 192 kHz. When `norm` is given without `sr` we therefore
      append an `aresample` ourselves; without it every normalized render would
      be a 192 kHz file (or a silent auto-resample by the encoder). The target
      is the **source's own rate** — §3.1 defines an absent `sr` as "follow the
      source", and a normalized render is not an exception — clamped to the
      lossy ceiling for a lossy format, since a 96 kHz master is a legitimate
      source for an mp3. Only where no probe supplied a rate does it fall back
      to 48 kHz, which is the ceiling itself and universally supported. See
      `resample/2`.
    * `afade` last, so the fade shape survives the stages above it.

  ## What the builder does not know

  `build/3` takes a `t:source/0` because three decisions genuinely cannot be
  made from the options alone. The protocol whitelist is one, and it is
  required. The other two are the source's own properties, and both exist
  because §3.1 defines an absent option as "follow the source": with no `bd` a
  lossless variant follows the source's bit depth, and with no `sr` a
  normalized render resamples back to the source's rate. Both are optional
  keys, and omitting either keeps the documented fallback — 16-bit and 48 kHz
  — rather than guessing.

  The render action supplies both from the probe its audio-only gate already
  runs, so on the mounted pipeline they are always present; a caller that
  builds argv without a probe (the suite, mostly) gets the fallbacks.

  ## Peaks

  `f:peaks` builds raw interleaved `s16le` PCM on stdout — the input to
  `AudioProxy.Peaks`, not its output. Encoding options are refused for peaks by
  `AudioProxy.Options`; every option that changes the samples applies — `t`,
  `ch`, `fade`, `enhance`, `gain` and `norm` — since a picture that disagreed
  with the audio playing under it would be the defect.

  Frame count is what makes that safe, and it is a property of the chain rather
  than of taste: every filter is rate-preserving, and the one that is not
  (`loudnorm`, which hands back 192 kHz) is followed by an `aresample` back to
  the source's own rate. So the decode emits the frames
  `AudioProxy.Peaks.Render` budgeted from its probe, and the `sample_rate` the
  header reports describes the samples actually reduced. `ch` is the one option
  peaks read differently: absent, it means mono rather than "follow the source",
  because the reducer has to know the interleaving up front and a waveform UI
  draws one shape.
  """

  alias AudioProxy.{Config, Options}

  @typedoc """
  What the builder needs to know about the source itself.

  `:type` is the resolved source's tag (`AudioProxy.Source.Type.tag/0`) and is
  **required**: it is what the input protocol whitelist is derived from, and a
  default would be a guess about which side of the network/filesystem boundary
  this render sits on.

  `:bit_depth` and `:sample_rate` are optional and are the source's own, as the
  probe reported them. Each exists because an option §3.1 documents as
  following the source cannot do so without them: a lossless variant with no
  `bd` follows the depth, and a normalized render with no `sr` resamples back to
  the rate. Omitting either keeps the documented fallback (16-bit, 48 kHz).

  This does not weaken the round-trip invariant, but it is worth stating the
  invariant precisely. The cache key hashes the normalized options *and* the
  source, so equal keys imply the same source and therefore the same type, the
  same source metadata, and — **within one deployment** — the same argv.

  The qualifier is not new to this key: `input_url` is what
  `AudioProxy.Source.ffmpeg_input/1` produced, and for a remote source that is a
  presigned URL whose host, scheme and signature all come from deployment
  configuration. Argv has therefore never been portable across deployments, and
  `protocols/1`'s `:s3` clause (which reads `AP_S3_ENDPOINT`) adds nothing in
  kind. What the cache needs is that argv be a deterministic function of the key
  *on the box serving it*, and it is. Neither the presigned URL nor the protocol
  set changes a single output byte, so two deployments still render identical
  variants for identical keys.
  """
  @type source :: [
          type: source_type(),
          bit_depth: Options.bit_depth(),
          sample_rate: pos_integer()
        ]

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

  # Where a normalized render lands when no probe said what the source's rate
  # was. The lossy ceiling, which is also universally supported. See
  # `resample/2` and the moduledoc's filter-order note.
  @loudnorm_output_rate 48_000

  # The pinned preset chains. Each value maps to exactly these characters
  # forever: a variant is served immutable under a key derived from
  # `enhance:voice`, so improving the chain means adding `voice2` here, never
  # editing this string. `AudioProxy.Ffmpeg.CommandEnhanceTest` compares it to
  # a literal so the rule cannot be broken quietly.
  #
  # What each stage is for, on speech:
  #
  #   * `highpass=f=80` — rumble, handling noise and plosive energy live below
  #     a speaking voice's fundamental. 80 Hz is under a low male voice and
  #     above almost every room.
  #   * `afftdn=nr=12:nf=-30` — spectral denoise, 12 dB of reduction against a
  #     −30 dBFS noise floor. Deliberately gentle: past roughly 20 dB the
  #     artefacts are more distracting on speech than the hiss was.
  #   * `deesser=i=0.4:m=0.5:f=0.5:s=o` — sibilance, which the compressor below
  #     would otherwise pump on. `i` is intensity and `f` is a normalized
  #     frequency, not Hz.
  #   * `acompressor=threshold=0.125:ratio=3:attack=20:release=250:makeup=2` —
  #     3:1 above −18 dBFS (0.125 linear, which is how this filter spells it),
  #     with a 2× makeup. Speech-radio settings: enough to even out a wandering
  #     mic distance, not enough to sound processed.
  #   * `alimiter=limit=0.977:level=disabled` — a −0.2 dBFS ceiling, and the
  #     stage the chain shipped without until it was measured. The compressor's
  #     20 ms attack lets a transient shorter than that through *uncompressed*,
  #     and the makeup then adds its full 6 dB on top: a source peaking at
  #     −3.1 dBFS came back at 0.0, i.e. clipped, where the source had not.
  #     With the limiter it comes back at −0.2 and the duration is unchanged.
  #
  #     `level=disabled` is load-bearing rather than tidy. `alimiter`'s `level`
  #     option defaults to *enabled*, which auto-normalizes the output back up
  #     to full scale — so the obvious `alimiter=limit=0.977` still measured
  #     0.0 dBFS and looked like the limiter had done nothing.
  #
  # `norm` is a separate stage and stays that way; the preset shapes dynamics,
  # it does not hit a loudness target.
  @enhance_chains %{
    voice:
      "highpass=f=80,afftdn=nr=12:nf=-30,deesser=i=0.4:m=0.5:f=0.5:s=o," <>
        "acompressor=threshold=0.125:ratio=3:attack=20:release=250:makeup=2," <>
        "alimiter=limit=0.977:level=disabled"
  }

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

  And a normalized render follows the source's sample rate the same way:

      iex> {:ok, opts} = AudioProxy.Options.parse("f:flac/norm:ebu")
      iex> AudioProxy.Ffmpeg.Command.build(opts, "/srv/audio/k.aif",
      ...>   type: :local, sample_rate: 96_000)
      ...> |> Enum.slice(-7, 2)
      ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11,aresample=96000"]
  """
  @spec build(Options.t(), String.t(), source()) :: [String.t()]
  def build(%Options{} = options, input_url, source) when is_binary(input_url) do
    @baseline ++
      ["-protocol_whitelist", protocols(Keyword.fetch!(source, :type))] ++
      input_args(options) ++
      ["-i", input_url] ++
      @audio_only ++
      filter_args(options, source) ++
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

  One clause is not a pure function of its argument, despite the spec: `:s3`
  reads `AP_S3_ENDPOINT`, because the presigned URL ffmpeg is handed carries the
  endpoint's own scheme. See `t:source/0` for why that does not weaken the
  round-trip invariant — the same endpoint is already in the input URL.
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
  The pinned filter chain for an `enhance` preset.

  Published because the pinning rule needs somewhere to be asserted: the suite
  compares this against a literal, so changing a chain fails a test naming the
  rule instead of silently re-rendering every cached variant that asked for the
  old one. A preset value maps to exactly these characters forever; an improved
  chain is a *new* value.

  An unknown preset raises — `AudioProxy.Options` is the gate, and a name it
  accepts with no chain here should crash this module's tests rather than
  render unenhanced audio under an enhanced key.

      iex> AudioProxy.Ffmpeg.Command.enhance_chain(:voice)
      "highpass=f=80,afftdn=nr=12:nf=-30,deesser=i=0.4:m=0.5:f=0.5:s=o,acompressor=threshold=0.125:ratio=3:attack=20:release=250:makeup=2,alimiter=limit=0.977:level=disabled"
  """
  @spec enhance_chain(Options.enhance()) :: String.t()
  def enhance_chain(preset) when is_atom(preset), do: Map.fetch!(@enhance_chains, preset)

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

  defp filter_args(%Options{} = options, source) do
    case Enum.filter(filters(options, source), & &1) do
      [] -> []
      filters -> ["-af", Enum.join(filters, ",")]
    end
  end

  defp filters(%Options{} = options, source) do
    [
      enhance(options.enhance),
      loudnorm(options.norm),
      volume(options.gain),
      resample(options, source),
      fade_in(options.fade_in),
      fade_out(options)
    ]
  end

  defp enhance(nil), do: nil
  defp enhance(preset), do: enhance_chain(preset)

  defp loudnorm(nil), do: nil

  defp loudnorm({i, tp, lra}) do
    "loudnorm=I=#{number(i)}:TP=#{number(tp)}:LRA=#{number(lra)}"
  end

  defp volume(nil), do: nil
  defp volume(gain), do: "volume=#{number(gain)}dB"

  # An explicit `sr` always resamples, to exactly what it asked for. Without
  # one, `norm` still forces a resample — single-pass loudnorm hands back
  # 192 kHz — and the target is then the *source's* rate, because that is what
  # an absent `sr` means (§3.1). A lossy format is clamped to the ceiling §3.1
  # would have refused an explicit `sr` above; nothing is refused here, since a
  # 96 kHz master is a perfectly good source for an mp3.
  #
  # With no probed rate the fallback is 48 kHz, the same value this emitted
  # unconditionally before the probe reached it. It is documented rather than
  # silent, and on the mounted pipeline it is unreachable: the audio-only gate
  # probes every MISS.
  defp resample(%Options{sample_rate: nil, norm: nil}, _source), do: nil

  defp resample(%Options{sample_rate: nil} = options, source) do
    "aresample=#{normalized_rate(options.format, Keyword.get(source, :sample_rate))}"
  end

  defp resample(%Options{sample_rate: rate}, _source), do: "aresample=#{rate}"

  defp normalized_rate(_format, nil), do: @loudnorm_output_rate

  defp normalized_rate(format, rate) do
    if Options.lossy?(format), do: min(rate, Options.lossy_sample_rate_cap()), else: rate
  end

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

  # Peaks are the one format that does not follow the source here: with no `ch`
  # they downmix to mono, and the argv has to say so explicitly because the
  # reducer needs the interleaving to be the one the cache key names. See
  # `AudioProxy.Options.peak_channels/1`.
  defp channel_args(%Options{format: :peaks} = options) do
    ["-ac", Integer.to_string(Options.peak_channels(options))]
  end

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
