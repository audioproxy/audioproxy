defmodule AudioProxy.Ffprobe do
  @moduledoc """
  One probe: `ffprobe` run against a source, its JSON collected, and the §4
  contract filtered out of it.

  Three public functions, split where the tests want to cut. `probe/2` runs the
  subprocess and hands back ffprobe's own decoded JSON; `contract/2` is a pure
  mapping from that JSON to the object `docs/audio-proxy-api-v1.md` §4 defines.
  Everything version- and format-specific lives in the second one, which is
  what makes it testable against canned output per container rather than
  against a binary.

  `has_video?/1` is the third, and it serves the audio-only policy rather than
  §4: both callers run it on the probe they already paid for — the render
  action before it takes a render slot, the info action before it describes
  anything — through `AudioProxy.VideoPolicy`, which holds the *verdict* on a
  `true`. This function answers only the question, identically under either
  verdict. It reads the same JSON `contract/2` does, pure and
  canned-output-testable for the same reason.

  ## Collect, not stream

  `AudioProxy.Ffmpeg.Render` is reused verbatim — same argv-only spawn, same
  kill discipline, same stderr classification — with this process as consumer
  and the chunks accumulated instead of forwarded. A probe reads container
  headers and stops, so its output is a few kilobytes; `@max_output` bounds the
  case where it is not (a source carrying a pathological tag block), because a
  collector with no ceiling is a memory hazard on a request path.

  Reusing `Render` also means reusing its failure classes: ffprobe exits 1 for
  almost everything, and the same stderr patterns that tell a missing input
  from an undecodable one for the encoder tell them apart here.

  ## No render slot

  A probe deliberately does **not** take an `AP_MAX_CONCURRENCY` slot. The
  semaphore exists to bound *decoding* — an encoder pinning a core for the
  length of a file — and a header read is neither long nor CPU-bound. Queueing
  probes behind renders would make `/info`, the endpoint a client calls *before*
  it knows what to request, the slowest thing in the proxy. `AP_PROBE_TIMEOUT`
  is what bounds this path instead.

  ## What the contract does with what ffprobe says

  ffprobe's output is verbose, version-dependent and inconsistent across
  containers; §4's object is none of those. The mapping is therefore explicit
  rather than a passthrough, and its rules are:

    * **Omission over null.** A field ffprobe cannot answer is absent from the
      object, never `null` and never a zero standing in for "unknown". A client
      testing `"bit_depth" in info` gets a true answer for every source.
    * **`format` is the API's own vocabulary**, not the container's. ffprobe
      names the `mov,mp4,m4a,3gp,3g2,mj2` family with one string and both Ogg
      payloads with `ogg`; §3.1 spells those `m4a`, `opus` and `ogg`. Reporting
      the `f:` token a client would pass back is more useful than reporting
      ffprobe's demuxer name, so the codec refines the container where the
      container alone is ambiguous.
    * **`bit_depth` comes from the stream, and only when it means something.**
      `bits_per_raw_sample` first, `bits_per_sample` second; a lossy stream
      answers `0` to both and so has no depth, which is exactly the §4
      behaviour. Deliberately *not* `sample_fmt`, which the design sketch
      suggested: mp3 decodes to `fltp` and would report a 32-bit depth for a
      source that has none.
    * **`size` is the store's, not ffprobe's.** `AudioProxy.Source.stat/1`
      already knows it and is authoritative for the object; `format.size` is
      the fallback for a backend that does not.
    * **Tags are passthrough, bounded.** String-valued format tags only,
      lowercased keys, capped in both count and length (`@max_tags`,
      `@max_tag_length`) — they are arbitrary bytes from a file the operator
      may not control, and they end up in a response body.
  """

  require Logger

  alias AudioProxy.{Config, Ffmpeg}
  alias AudioProxy.Ffmpeg.RenderSupervisor

  # `-show_format` for the container and its tags, `-show_streams` for the
  # stream parameters. No `-i`: ffprobe takes its input positionally, and it is
  # the last element so nothing after it can be read as a flag.
  #
  # Every stream, deliberately: this once carried `-select_streams a:0`, because
  # §4's contract describes one audio stream and a cover-art video stream would
  # otherwise be in the output. The audio-only policy needs the opposite — a
  # gate cannot refuse a stream ffprobe was told to hide — and both callers now
  # gate, so the selection is gone rather than conditional. Nothing about §4
  # changed with it: `contract/2` finds the first audio stream itself, which is
  # what `a:0` named.
  @flags ~w(-hide_banner -loglevel error -show_format -show_streams -print_format json)

  # Well past any real probe (a few KB) and well short of a memory hazard.
  @max_output 1_048_576

  # Added to the configured probe timeout for this process' mailbox deadline,
  # so `Render`'s own timer — which classifies — fires first. Same reasoning as
  # `AudioProxy.Plugs.RenderAction`'s margin.
  @deadline_margin 1_000

  @max_tags 32
  @max_tag_length 512

  @typedoc """
  The §4 object, with every unknown field omitted.

  String values (`format`) and numbers land as themselves; `tags` is a map of
  lowercased tag name to string.
  """
  @type info :: %{optional(atom()) => term()}

  @typedoc "Why a probe produced no contract."
  @type error_reason :: :not_found | :undecodable_source | :probe_timeout | :probe_failed

  @doc """
  Runs `ffprobe` against `input` and returns its decoded JSON.

  `input` is whatever `AudioProxy.Source.ffmpeg_input/1` produced — a path or a
  presigned URL — and is passed through as a single argv element.

  Options:

    * `:protocols` — **required.** The `-protocol_whitelist` set, from
      `AudioProxy.Ffmpeg.Command.protocols/1`. Required rather than defaulted
      for the same reason `AudioProxy.Ffmpeg.Command.build/3` requires its
      `type:`: this is a subprocess that *reads the source*, so a caller with
      no protocol set to offer has no business starting one. There is
      deliberately no "unrestricted" spelling — an omitted key raises, which
      fails a refactor's tests rather than silently reopening `file:` and
      `concat:` to whatever the source redirects to.
    * `:executable` — the binary to run. Defaults to `ffprobe` from `PATH`.
    * `:timeout` — milliseconds. Defaults to `AP_PROBE_TIMEOUT`.
  """
  @spec probe(String.t(), keyword()) :: {:ok, map()} | {:error, error_reason()}
  def probe(input, opts) when is_binary(input) do
    with {:ok, executable} <- executable(Keyword.get(opts, :executable)),
         {:ok, output} <-
           run(executable, args(input, Keyword.fetch!(opts, :protocols)), timeout(opts)) do
      decode(output)
    end
  end

  @doc """
  Whether a probe found a genuine video stream.

  The question the audio-only policy turns on — `AudioProxy.VideoPolicy` holds
  what is done about a `true` — and it is not simply "is there a stream whose
  `codec_type` is video". Virtually every tagged mp3, flac and m4a
  carries its cover art as exactly such a stream, and refusing those would
  refuse most of a real catalogue. Two exemptions, in the order they are
  checked:

    * **`attached_pic` disposition** — ffmpeg's own word for "this is cover
      art, not a video track". Authoritative where present.
    * **A single-frame image codec** — `mjpeg`/`png`/… with `nb_frames` of 1,
      for containers whose disposition data is missing or ambiguous.

  Anything else with a video `codec_type` is video. The fallback direction is
  deliberate: an unrecognized codec, an absent frame count, a disposition map
  that says nothing all reject. Failing closed here costs a client a 415 on an
  odd file; failing open makes the proxy a video transcoder.

  Two limits worth knowing. The image-codec list is not every still-image
  decoder ffmpeg carries, only names that cannot also be a video stream — see
  the list itself for why widening it is the risky direction. And the
  `attached_pic` exemption trusts a flag that lives in the *container*, i.e. in
  bytes the requester may control: a crafted file can wear it. What that buys is
  bounded by the layer underneath rather than by this function — every argv
  carries `-vn -sn -dn`, so the video stream is never mapped and the render is
  an audio-only encode either way.

      iex> AudioProxy.Ffprobe.has_video?(%{"streams" => [
      ...>   %{"codec_type" => "audio", "codec_name" => "mp3"},
      ...>   %{"codec_type" => "video", "codec_name" => "mjpeg",
      ...>     "disposition" => %{"attached_pic" => 1}}
      ...> ]})
      false

      iex> AudioProxy.Ffprobe.has_video?(%{"streams" => [
      ...>   %{"codec_type" => "video", "codec_name" => "h264"}
      ...> ]})
      true
  """
  @spec has_video?(map()) :: boolean()
  def has_video?(probe) when is_map(probe) do
    case Map.get(probe, "streams") do
      streams when is_list(streams) ->
        Enum.any?(streams, &video?/1)

      # ffprobe described no streams at all. Not a video verdict to invent: a
      # source like that carries no audio stream either, so it is refused a few
      # lines later — as `:undecodable_source`, which is the honest reason.
      _absent ->
        false
    end
  end

  @doc """
  The argument vector `probe/2` runs, for a caller that spawns the subprocess
  itself.

  `/info` wants `probe/2`: it is answering a request and can block on the
  collect. `AudioProxy.Peaks.Render` cannot — it is a GenServer that has to
  stay answerable to `cancel/1` while the probe runs, so it spawns the same
  argv through `AudioProxy.Ffmpeg.Render` and folds the chunks in
  `handle_info/2`. Both routes must ask ffprobe the *same question*, or the two
  callers would drift on flags; this function is that shared answer.

  `protocols` is the `-protocol_whitelist` set, from
  `AudioProxy.Ffmpeg.Command.protocols/1`, and it is an argument rather than an
  option for exactly the reason above: a caller that builds its own argv would
  otherwise be the one route that reads a source unrestricted, which is the hole
  the whitelist exists to close. It binds the input because it precedes it.

  `input` is passed through as a single argv element, and is last, so nothing
  after it can be read as a flag.

      iex> AudioProxy.Ffprobe.args("s3://b/k.wav", "https,tls,tcp") |> List.last()
      "s3://b/k.wav"

      iex> AudioProxy.Ffprobe.args("/srv/a.wav", "file") |> Enum.take(-3)
      ["-protocol_whitelist", "file", "/srv/a.wav"]
  """
  @spec args(String.t(), String.t()) :: [String.t()]
  def args(input, protocols) when is_binary(input) and is_binary(protocols) do
    @flags ++ ["-protocol_whitelist", protocols] ++ [input]
  end

  @doc """
  Resolves the ffprobe binary, or `{:error, :probe_failed}`.

  Public for the same reason `args/1` is: a caller that spawns the subprocess
  itself still has to find it, and finding it twice in two ways is how the two
  paths end up disagreeing about which binary ran.
  """
  @spec executable(String.t() | nil) :: {:ok, String.t()} | {:error, error_reason()}
  def executable(nil) do
    case System.find_executable("ffprobe") do
      nil ->
        # Not "/info cannot answer" any more: `f:peaks` needs a probe too, and
        # a log line naming one caller is misleading from the other.
        Logger.error("no `ffprobe` on PATH; /info and f:peaks cannot answer")
        {:error, :probe_failed}

      path ->
        {:ok, path}
    end
  end

  def executable(path) when is_binary(path), do: {:ok, path}

  @doc """
  Maps ffprobe's decoded JSON to the §4 contract.

  A pure function — this is what the per-container fixtures pin. Options:

    * `:size` — the object size `AudioProxy.Source.stat/1` reported, which wins
      over ffprobe's own.

  Returns `{:error, :undecodable_source}` when the probe found no audio stream:
  ffprobe parsed *something*, but nothing this proxy can serve.

      iex> probe = %{
      ...>   "format" => %{"format_name" => "wav", "duration" => "3.5", "size" => "672044"},
      ...>   "streams" => [%{
      ...>     "codec_type" => "audio", "codec_name" => "pcm_s16le",
      ...>     "sample_rate" => "48000", "channels" => 2, "bits_per_sample" => 16
      ...>   }]
      ...> }
      iex> AudioProxy.Ffprobe.contract(probe)
      {:ok, %{format: "wav", duration: 3.5, sample_rate: 48000, channels: 2,
              bit_depth: 16, size: 672044}}
  """
  @spec contract(map(), keyword()) :: {:ok, info()} | {:error, :undecodable_source}
  def contract(probe, opts \\ []) when is_map(probe) do
    format = probe |> Map.get("format") |> as_map()

    case probe |> Map.get("streams") |> audio_stream() do
      nil ->
        {:error, :undecodable_source}

      stream ->
        {:ok,
         %{}
         |> put_present(:format, container(format, stream))
         # Each fallback is tried on the *extracted* value, never on the raw
         # one: ffprobe writes "N/A" rather than omitting a field it cannot
         # answer, and `format["duration"] || stream["duration"]` would take
         # the "N/A" and never reach the stream that knows.
         |> put_present(:duration, decimal(format["duration"]) || decimal(stream["duration"]))
         |> put_present(:sample_rate, positive_integer(stream["sample_rate"]))
         |> put_present(:channels, positive_integer(stream["channels"]))
         |> put_present(:bit_depth, bit_depth(stream))
         |> put_present(
           :bitrate,
           positive_integer(format["bit_rate"]) || positive_integer(stream["bit_rate"])
         )
         |> put_present(:size, Keyword.get(opts, :size) || positive_integer(format["size"]))
         |> put_present(:tags, tags(format["tags"]))}
    end
  end

  @doc """
  The source properties `AudioProxy.Ffmpeg.Command.build/3` takes, read off a
  probe.

  A third mapping alongside `contract/2` and `has_video?/1`, and pure for the
  same reason: it is the render path's answer to "what is this source", where
  `contract/2` is `/info`'s. They read the same audio stream and must not be
  able to disagree about it, which is why this lives here rather than in the
  render action.

  Only keys the probe actually answered are present — an absent key is what
  `build/3` reads as "fall back", so a `nil` value would have to be handled
  twice. A rate ffprobe could not report and a lossy source's absent bit depth
  are both ordinary, not errors.

  `bits_per_raw_sample`/`bits_per_sample` are integers and `bd` is a token, so
  the mapping is explicit and deliberately partial: 16 and 24 are the depths a
  source can wear that `bd` also spells. A 32-bit source is *not* mapped, because
  the depth alone cannot tell `pcm_s32le` from `pcm_f32le` and `bd:32f` means
  the float one; it falls back to 16-bit, exactly as an unprobed source does.

      iex> AudioProxy.Ffprobe.source_properties(%{"streams" => [
      ...>   %{"codec_type" => "audio", "sample_rate" => "44100",
      ...>     "bits_per_raw_sample" => 24}
      ...> ]})
      [sample_rate: 44100, bit_depth: :bd24]

      iex> AudioProxy.Ffprobe.source_properties(%{"streams" => [
      ...>   %{"codec_type" => "audio", "codec_name" => "mp3",
      ...>     "sample_rate" => "44100", "bits_per_sample" => 0}
      ...> ]})
      [sample_rate: 44100]
  """
  @spec source_properties(map()) :: keyword()
  def source_properties(probe) when is_map(probe) do
    case probe |> Map.get("streams") |> audio_stream() do
      nil ->
        []

      stream ->
        [sample_rate: positive_integer(stream["sample_rate"]), bit_depth: depth_token(stream)]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    end
  end

  @doc """
  The probe deadline in milliseconds — `AP_PROBE_TIMEOUT` as the subprocess
  sees it.
  """
  @spec timeout(keyword()) :: pos_integer()
  def timeout(opts \\ []) do
    Keyword.get(opts, :timeout) || Config.get(:probe_timeout) * 1_000
  end

  ## Running

  # `args` already ends with the input — see `args/2`.
  defp run(executable, args, timeout) do
    opts = [
      args: args,
      executable: executable,
      consumer: self(),
      timeout: timeout
    ]

    case RenderSupervisor.start_render(opts) do
      {:ok, probe} ->
        collect(probe, Process.monitor(probe), timeout + @deadline_margin, [], 0)

      {:error, reason} ->
        Logger.error("could not start probe: #{inspect(reason)}")
        {:error, :probe_failed}
    end
  end

  # Acking each chunk keeps `Render`'s bounded buffer released, which matters
  # only for the pathological case `@max_output` also guards — but a collector
  # that never acks would silently stop receiving at the high-water mark,
  # including the `{:done, _, _}` that ends this loop.
  defp collect(probe, monitor, deadline, acc, size) do
    receive do
      {:chunk, ^probe, data} ->
        Ffmpeg.Render.ack(probe, byte_size(data))
        size = size + byte_size(data)

        if size > @max_output do
          Logger.warning("probe output exceeded #{@max_output} bytes; abandoning")
          stop(probe, monitor)
          {:error, :probe_failed}
        else
          collect(probe, monitor, deadline, [acc | data], size)
        end

      {:done, ^probe, _info} ->
        demonitor(monitor)
        {:ok, IO.iodata_to_binary(acc)}

      {:error, ^probe, failure} ->
        demonitor(monitor)
        {:error, reason_for(failure)}

      {:DOWN, ^monitor, :process, ^probe, reason} ->
        Logger.error("probe died before producing output: #{inspect(reason)}")
        {:error, :probe_failed}
    after
      deadline ->
        stop(probe, monitor)
        {:error, :probe_timeout}
    end
  end

  # `cancel/1` returns once the subprocess is gone, and everything it sent
  # arrived before that reply — so the drain is a drain and not a race. It
  # matters because this runs in Bandit's connection process, which is reused
  # for the next request on a keep-alive connection.
  defp stop(probe, monitor) do
    demonitor(monitor)
    Ffmpeg.Render.cancel(probe)
    drain(probe)
  end

  defp drain(probe) do
    receive do
      {:chunk, ^probe, _data} -> drain(probe)
      {:done, ^probe, _info} -> drain(probe)
      {:error, ^probe, _failure} -> drain(probe)
    after
      0 -> :ok
    end
  end

  # `Render`'s classes, mapped to this module's. `:not_found` survives as
  # itself — the HTTP layer already answers it as the generic 404 — and a
  # timeout reported by the subprocess' own timer is the same outcome as one
  # reported by the deadline above.
  defp reason_for(%{class: :not_found}), do: :not_found
  defp reason_for(%{class: :undecodable}), do: :undecodable_source
  defp reason_for(%{class: :timeout}), do: :probe_timeout

  defp reason_for(%{class: class, stderr: stderr}) do
    Logger.warning("probe failed (#{class}): #{String.trim(stderr)}")
    :probe_failed
  end

  # ffprobe writing something that is not JSON on a clean exit is this proxy's
  # problem, not the client's: 500, with the reason in the log.
  defp decode(output) do
    case JSON.decode(output) do
      {:ok, probe} when is_map(probe) ->
        {:ok, probe}

      _other ->
        Logger.error(
          "probe output was not a JSON object: #{inspect(binary_part(output, 0, min(byte_size(output), 200)))}"
        )

        {:error, :probe_failed}
    end
  end

  # Said out loud rather than folded into the 500: an image built without
  # ffprobe answers every `/info` request identically and with nothing in the
  # log to explain it, which is a long afternoon for whoever is holding it.
  defp demonitor(monitor), do: Process.demonitor(monitor, [:flush])

  ## Contract mapping

  # The container tokens §3.1 spells. ffprobe names a container with a
  # comma-separated list of every format its demuxer answers to, and both the
  # membership and the order of that list are its own business — the MP4 family
  # is `mov,mp4,m4a,3gp,3g2,mj2` today. Preferring whichever name in the list
  # the API itself spells survives a reordering and a version bump; matching the
  # whole string, which is what this did first, did not.
  #
  # A container the API has no token for falls through to the first name, which
  # is the right answer for `matroska,webm` and for anything unlisted: `format`
  # describes the *source*, and a source may well be in a container this proxy
  # cannot emit.
  @api_containers ~w(mp3 ogg aac m4a flac wav)

  # Where one container carries two of the API's formats, the codec decides.
  # Ogg is the only such case: `f:opus` and `f:ogg` are different variants and
  # ffprobe calls both containers `ogg`.
  @by_codec %{{"ogg", "opus"} => "opus"}

  defp container(format, stream) do
    with name when is_binary(name) and name != "" <- format["format_name"] do
      names = String.split(name, ",")
      base = Enum.find(names, hd(names), &(&1 in @api_containers))

      Map.get(@by_codec, {base, stream["codec_name"]}, base)
    else
      _absent -> nil
    end
  end

  # ffprobe reports numbers as strings in some sections and as numbers in
  # others, and the spellings vary by version — so every extractor here accepts
  # both, and "N/A" (or anything else unparseable) is an absent field.
  defp decimal(value) when is_number(value), do: value / 1

  defp decimal(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp decimal(_absent), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> positive_integer(number)
      _other -> nil
    end
  end

  defp positive_integer(_absent), do: nil

  # A lossy stream answers 0 to both, which is how "this source has no bit
  # depth" arrives — and `positive_integer/1` turns it into an omitted key.
  defp bit_depth(stream) do
    positive_integer(stream["bits_per_raw_sample"]) || positive_integer(stream["bits_per_sample"])
  end

  # The depths a source can wear that `bd` also spells. See
  # `source_properties/1` for why 32 is deliberately absent.
  @depth_tokens %{16 => :bd16, 24 => :bd24}

  defp depth_token(stream), do: Map.get(@depth_tokens, bit_depth(stream))

  # Codecs that are a picture rather than a moving image, for the case where no
  # disposition says so. Deliberately **not** a complete enumeration of every
  # still-image decoder ffmpeg carries: it is a list of names that can *only*
  # ever be a still, so a codec missing from it costs a legitimate file a 415
  # (recoverable, and only when its container also omits the disposition) while
  # a wrong addition would cost the policy a hole. That asymmetry is why the
  # names ffmpeg shares between stills and video — `av1` (AVIF), `hevc` (HEIF),
  # `vp8`/`vp9` (WebP's own codecs are `webp`) — are absent and must stay
  # absent. Add to this list only names no video stream can wear.
  @image_codecs ~w(mjpeg mjpegb png apng bmp gif tiff webp jpeg2000 jpegls
                   ppm pgm pbm pam pgmyuv pnm targa pcx sgi sunrast dpx exr
                   xwd qdraw fits)

  defp video?(stream) when is_map(stream) do
    Map.get(stream, "codec_type") == "video" and
      not attached_pic?(stream) and
      not still_image?(stream)
  end

  defp video?(_absent), do: false

  defp attached_pic?(stream) do
    case Map.get(stream, "disposition") do
      disposition when is_map(disposition) -> Map.get(disposition, "attached_pic") == 1
      _absent -> false
    end
  end

  # `nb_frames` is a string in some ffprobe versions and an integer in others,
  # and absent in a third set — where absent means "not established", which is
  # not the same as one and is therefore not exempted.
  defp still_image?(stream) do
    Map.get(stream, "codec_name") in @image_codecs and
      positive_integer(Map.get(stream, "nb_frames")) == 1
  end

  defp audio_stream(streams) when is_list(streams) do
    Enum.find(streams, fn stream ->
      is_map(stream) and Map.get(stream, "codec_type") == "audio"
    end)
  end

  defp audio_stream(_absent), do: nil

  # `String.valid?/1` on both halves, and it is not belt-and-braces. Tag bytes
  # come from a file the operator may not control, and `String.downcase/1` and
  # `String.slice/3` both pass invalid UTF-8 through without complaint — so
  # without this guard the bad bytes would reach `JSON.encode!`, which raises.
  # `JSON.decode/1` refuses invalid UTF-8 in both its spellings (raw bytes and
  # escaped lone surrogates), so nothing that comes through `probe/2` can be
  # caught here; this function is public and doctested with hand-built maps,
  # which is exactly where an invariant enforced in another module stops
  # holding.
  defp tags(tags) when is_map(tags) do
    tags
    |> Enum.filter(fn {key, value} ->
      is_binary(key) and is_binary(value) and String.valid?(key) and String.valid?(value)
    end)
    # Sorted before the cap so which tags survive a capped block is a property
    # of the source, not of ffprobe's iteration order.
    |> Enum.sort()
    |> Enum.take(@max_tags)
    |> Map.new(fn {key, value} ->
      {String.downcase(key), String.slice(value, 0, @max_tag_length)}
    end)
    |> case do
      empty when map_size(empty) == 0 -> nil
      tags -> tags
    end
  end

  defp tags(_absent), do: nil

  defp as_map(value) when is_map(value), do: value
  defp as_map(_absent), do: %{}

  defp put_present(info, _key, nil), do: info
  defp put_present(info, key, value), do: Map.put(info, key, value)
end
