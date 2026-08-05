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

  `has_video?/1` is the third, and it is the audio-only policy's gate rather
  than part of §4: the render action probes on a MISS and refuses a source with
  video before a render slot is taken. It reads the same JSON `contract/2` does
  — pure, canned-output-testable, for the same reason — but needs `probe/2` to
  have been asked for `streams: :all`, since §4's default selection hides the
  very streams it is looking for.

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
  @flags ~w(-hide_banner -loglevel error -show_format -show_streams -print_format json)

  # `-select_streams a:0` because §4's contract describes one audio stream and a
  # cover-art video stream would otherwise be in the output. The audio-only
  # policy gate needs the opposite — every stream, so it can see the video it
  # exists to refuse — which is what `streams: :all` asks for.
  @audio_selection ~w(-select_streams a:0)

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

    * `:executable` — the binary to run. Defaults to `ffprobe` from `PATH`.
    * `:timeout` — milliseconds. Defaults to `AP_PROBE_TIMEOUT`.
    * `:streams` — `:audio` (default, §4's one audio stream) or `:all`, which
      the audio-only gate needs so `has_video?/1` can see what it refuses.
    * `:protocols` — the `-protocol_whitelist` set, from
      `AudioProxy.Ffmpeg.Command.protocols/1`. Omitted means unrestricted,
      which is what a caller with no resolved source type to offer gets;
      every caller on the request path passes one.
  """
  @spec probe(String.t(), keyword()) :: {:ok, map()} | {:error, error_reason()}
  def probe(input, opts \\ []) when is_binary(input) do
    with {:ok, executable} <- executable(Keyword.get(opts, :executable)),
         {:ok, output} <- run(executable, input, args(opts), timeout(opts)) do
      decode(output)
    end
  end

  @doc """
  Whether a probe found a genuine video stream.

  The question the audio-only policy turns on, and it is not simply "is there a
  stream whose `codec_type` is video". Virtually every tagged mp3, flac and m4a
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
  The probe deadline in milliseconds — `AP_PROBE_TIMEOUT` as the subprocess
  sees it.
  """
  @spec timeout(keyword()) :: pos_integer()
  def timeout(opts \\ []) do
    Keyword.get(opts, :timeout) || Config.get(:probe_timeout) * 1_000
  end

  ## Running

  # The input stays last, after every flag and after the whitelist, so nothing
  # in it can be read as an option.
  defp args(opts) do
    @flags ++ selection(Keyword.get(opts, :streams, :audio)) ++ whitelist(opts)
  end

  defp selection(:audio), do: @audio_selection
  defp selection(:all), do: []

  defp whitelist(opts) do
    case Keyword.get(opts, :protocols) do
      nil -> []
      protocols when is_binary(protocols) -> ["-protocol_whitelist", protocols]
    end
  end

  defp run(executable, input, args, timeout) do
    opts = [
      args: args ++ [input],
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
  defp executable(nil) do
    case System.find_executable("ffprobe") do
      nil ->
        Logger.error("no `ffprobe` on PATH; /info cannot answer")
        {:error, :probe_failed}

      path ->
        {:ok, path}
    end
  end

  defp executable(path) when is_binary(path), do: {:ok, path}

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

  # Codecs that are a picture rather than a moving image. The list is the
  # exemption's whole width: a codec absent from it, single-frame or not, is
  # video. See `has_video?/1` for why the direction is this way round.
  @image_codecs ~w(mjpeg mjpegb png bmp gif tiff webp jpeg2000 jpegls)

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
