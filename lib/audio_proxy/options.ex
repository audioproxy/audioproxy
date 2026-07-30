defmodule AudioProxy.Options do
  @moduledoc """
  The processing-options grammar (API doc §3): parse, validate, normalize.

  Options are the API. A variant is fully described by its options segments,
  and the normalized options string is what the cache key hashes — so this
  module owns three obligations, in order:

    * `parse/1` — `/`-separated `key:value` segments into `t:t/0`, with
      per-key value domains enforced.
    * `validate/1` — cross-key rules that no single parser can see (`br`
      excludes `q`, `bd` is lossless-only, …). `parse/1` runs it for you.
    * `normalize/1` — back to a canonical string: defaults materialized,
      keys sorted, numbers rendered minimally.

  Normalization is the determinism boundary. Any two option strings
  describing the same variant must produce byte-identical normalized forms,
  because `AudioProxy.CacheKey` hashes that string directly. Two rules keep
  it stable: decimals are capped at millisecond precision (three places) at
  parse time, and every number is rendered by the same `render_number/1`.

  Failures are `t:AudioProxy.OptionError.t/0` values naming the offending
  segment; the HTTP slice maps them to 422.

      iex> {:ok, opts} = AudioProxy.Options.parse("br:96/f:opus")
      iex> AudioProxy.Options.normalize(opts)
      "br:96/f:opus"

  ## Not enforced here

  Peaks ignore encoding options rather than reject them (§3.3), so
  `f:peaks/br:96` parses and keeps `br` in its cache key — a distinct key for
  an identical rendering. Callers that care should drop encoding options
  before building peaks URLs.
  """

  alias AudioProxy.OptionError

  @formats ~w(mp3 opus ogg aac m4a flac wav peaks)a
  @lossy ~w(mp3 opus ogg aac m4a)a
  @lossless ~w(flac wav)a

  @bit_depths %{"16" => :bd16, "24" => :bd24, "32f" => :bd32f}
  @bit_depth_tokens Map.new(@bit_depths, fn {token, atom} -> {atom, token} end)

  @peak_formats %{"json" => :json, "dat" => :dat}
  @peak_format_tokens Map.new(@peak_formats, fn {token, atom} -> {atom, token} end)

  # Millisecond precision cap (design): three decimal places, so float
  # formatting can never destabilize a cache key.
  @max_decimals 3
  @decimal_re ~r/^-?\d+(\.\d{1,3})?$/
  @non_negative_integer_re ~r/^\d+$/

  @default_format :mp3
  @default_peak_count 800
  @default_peak_format :json
  @default_norm {-16.0, -1.5, 11.0}

  # Lossy encoders gain nothing above 48 kHz; §3.1 caps them there.
  @lossy_sample_rate_cap 48_000

  # loudnorm's documented input ranges.
  @norm_i_range {-70.0, -5.0}
  @norm_tp_range {-9.0, 0.0}
  @norm_lra_range {1.0, 50.0}

  @type format :: :mp3 | :opus | :ogg | :aac | :m4a | :flac | :wav | :peaks
  @type bit_depth :: :bd16 | :bd24 | :bd32f
  @type peak_format :: :json | :dat

  @typedoc "loudnorm targets: integrated LUFS, true peak dBTP, loudness range LU."
  @type norm :: {float(), float(), float()}

  @typedoc """
  A parsed variant description.

  `nil` means "not given": the renderer falls back to the source's own
  property (`sample_rate`, `channels`) or skips the stage entirely (`gain`,
  `norm`, `trim_start`). `trim_duration` is `nil` for an open-ended trim
  (`t:30` runs to the end of the source).
  """
  @type t :: %__MODULE__{
          format: format(),
          bitrate: pos_integer() | nil,
          quality: float() | nil,
          sample_rate: pos_integer() | nil,
          channels: 1 | 2 | nil,
          bit_depth: bit_depth() | nil,
          trim_start: float() | nil,
          trim_duration: float() | nil,
          fade_in: float() | nil,
          fade_out: float() | nil,
          gain: float() | nil,
          norm: norm() | nil,
          peak_count: pos_integer() | nil,
          peak_format: peak_format() | nil,
          download: String.t() | nil,
          cache_buster: String.t() | nil
        }

  defstruct format: @default_format,
            bitrate: nil,
            quality: nil,
            sample_rate: nil,
            channels: nil,
            bit_depth: nil,
            trim_start: nil,
            trim_duration: nil,
            fade_in: nil,
            fade_out: nil,
            gain: nil,
            norm: nil,
            peak_count: nil,
            peak_format: nil,
            download: nil,
            cache_buster: nil

  @doc """
  Parses an options string (or its already-split segments) into `t:t/0`.

  Accepts `"f:opus/br:96"` or `["f:opus", "br:96"]`; an empty string yields
  the defaults. Unknown keys, repeated keys, and out-of-domain values fail,
  and `validate/1` runs on the result so cross-key conflicts fail here too.

      iex> {:ok, opts} = AudioProxy.Options.parse("f:opus/t:12.5:30")
      iex> {opts.format, opts.trim_start, opts.trim_duration}
      {:opus, 12.5, 30.0}
  """
  @spec parse(String.t() | [String.t()]) :: {:ok, t()} | {:error, OptionError.t()}
  def parse(options) when is_binary(options) or is_list(options) do
    options
    |> segments()
    |> Enum.reduce_while({%__MODULE__{}, MapSet.new()}, fn segment, {opts, seen} ->
      case parse_segment(segment, opts, seen) do
        {:ok, opts, seen} -> {:cont, {opts, seen}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _} = error -> error
      {opts, _seen} -> validate(opts)
    end
  end

  @doc """
  Checks the cross-key rules that per-key parsing cannot see.

  Run by `parse/1`; public so a hand-built struct can be checked too. Rules,
  in the order they are reported: `br` excludes `q`; `bd` needs a lossless
  format; `pts`/`pk_fmt` need `f:peaks`; `sr` is capped at 48 kHz for lossy
  formats; a fade must fit inside a bounded trim.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, OptionError.t()}
  def validate(%__MODULE__{} = opts) do
    with :ok <- validate_bitrate_quality(opts),
         :ok <- validate_bit_depth(opts),
         :ok <- validate_peak_options(opts),
         :ok <- validate_sample_rate(opts),
         :ok <- validate_fade(opts) do
      {:ok, opts}
    end
  end

  @doc """
  Renders `opts` as its canonical options string — the cache-key input.

  Keys are sorted lexicographically, applicable defaults are materialized
  (`f`, and `pts`/`pk_fmt` under `f:peaks`, and the `norm` targets when
  `norm` is present), and numbers are rendered minimally (`30`, not `30.0`).

  The result always re-parses, and normalizing it again is byte-identical.

      iex> {:ok, opts} = AudioProxy.Options.parse("norm:ebu")
      iex> AudioProxy.Options.normalize(opts)
      "f:mp3/norm:ebu:-16:-1.5:11"
  """
  @spec normalize(t()) :: String.t()
  def normalize(%__MODULE__{} = opts) do
    keys()
    |> Enum.map(&{&1, render_key(&1, opts)})
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join("/", fn {_key, value} -> value end)
  end

  @doc """
  Parses and normalizes in one step.

      iex> AudioProxy.Options.normalize_string("br:96/f:opus")
      {:ok, "br:96/f:opus"}
  """
  @spec normalize_string(String.t() | [String.t()]) ::
          {:ok, String.t()} | {:error, OptionError.t()}
  def normalize_string(options) do
    with {:ok, opts} <- parse(options), do: {:ok, normalize(opts)}
  end

  @doc "The option keys recognized by `parse/1`, in canonical (sorted) order."
  @spec keys() :: [String.t()]
  def keys, do: ~w(bd br cb ch dl f fade gain norm pk_fmt pts q sr t)

  ## Parsing

  defp segments(options) when is_list(options), do: options
  defp segments(""), do: []
  defp segments(options), do: String.split(options, "/")

  defp parse_segment("", _opts, _seen), do: {:error, OptionError.new("", :empty_segment)}

  defp parse_segment(segment, opts, seen) do
    case String.split(segment, ":", parts: 2) do
      [_key] ->
        {:error, OptionError.new(segment, :missing_value)}

      [key, value] ->
        cond do
          key not in keys() -> {:error, OptionError.new(segment, :unknown_key)}
          MapSet.member?(seen, key) -> {:error, OptionError.new(segment, :duplicate_key)}
          true -> apply_value(key, value, segment, opts, seen)
        end
    end
  end

  defp apply_value(key, value, segment, opts, seen) do
    case parse_value(key, value) do
      {:ok, fields} -> {:ok, struct!(opts, fields), MapSet.put(seen, key)}
      {:error, reason} -> {:error, OptionError.new(segment, reason)}
    end
  end

  defp parse_value("f", value) do
    with {:ok, format} <- enum(value, @formats), do: {:ok, format: format}
  end

  defp parse_value("br", value) do
    with {:ok, bitrate} <- positive_integer(value), do: {:ok, bitrate: bitrate}
  end

  defp parse_value("q", value) do
    with {:ok, quality} <- decimal(value), do: {:ok, quality: quality}
  end

  defp parse_value("sr", value) do
    with {:ok, rate} <- positive_integer(value), do: {:ok, sample_rate: rate}
  end

  defp parse_value("ch", "1"), do: {:ok, channels: 1}
  defp parse_value("ch", "2"), do: {:ok, channels: 2}
  defp parse_value("ch", _value), do: {:error, :invalid_value}

  defp parse_value("bd", value) do
    case Map.fetch(@bit_depths, value) do
      {:ok, depth} -> {:ok, bit_depth: depth}
      :error -> {:error, :invalid_value}
    end
  end

  # `t:START[:DURATION]` — an omitted duration runs to the end of the source.
  defp parse_value("t", value) do
    case String.split(value, ":") do
      [start] ->
        with {:ok, start} <- non_negative_decimal(start), do: {:ok, trim_start: start}

      [start, duration] ->
        with {:ok, start} <- non_negative_decimal(start),
             {:ok, duration} <- non_negative_decimal(duration),
             :ok <- positive(duration) do
          {:ok, trim_start: start, trim_duration: duration}
        end

      _ ->
        {:error, :invalid_value}
    end
  end

  # `fade:IN[:OUT]` — an omitted out-fade is zero, not a mirror of the in.
  defp parse_value("fade", value) do
    case String.split(value, ":") do
      [fade_in] ->
        with {:ok, fade_in} <- non_negative_decimal(fade_in),
             do: {:ok, fade_in: fade_in, fade_out: 0.0}

      [fade_in, fade_out] ->
        with {:ok, fade_in} <- non_negative_decimal(fade_in),
             {:ok, fade_out} <- non_negative_decimal(fade_out) do
          {:ok, fade_in: fade_in, fade_out: fade_out}
        end

      _ ->
        {:error, :invalid_value}
    end
  end

  defp parse_value("gain", value) do
    with {:ok, gain} <- decimal(value), do: {:ok, gain: gain}
  end

  # `norm:ebu[:I[:TP[:LRA]]]` — omitted targets take the §3.2 defaults.
  defp parse_value("norm", value) do
    {_default_i, default_tp, default_lra} = @default_norm

    case String.split(value, ":") do
      ["ebu"] ->
        {:ok, norm: @default_norm}

      ["ebu", i] ->
        build_norm(i, default_tp, default_lra)

      ["ebu", i, tp] ->
        with {:ok, tp} <- norm_target(tp, @norm_tp_range), do: build_norm(i, tp, default_lra)

      ["ebu", i, tp, lra] ->
        with {:ok, tp} <- norm_target(tp, @norm_tp_range),
             {:ok, lra} <- norm_target(lra, @norm_lra_range) do
          build_norm(i, tp, lra)
        end

      _ ->
        {:error, :invalid_value}
    end
  end

  defp parse_value("pts", value) do
    with {:ok, count} <- positive_integer(value), do: {:ok, peak_count: count}
  end

  defp parse_value("pk_fmt", value) do
    case Map.fetch(@peak_formats, value) do
      {:ok, peak_format} -> {:ok, peak_format: peak_format}
      :error -> {:error, :invalid_value}
    end
  end

  # `dl` and `cb` are opaque: still percent-encoded here, and part of the
  # cache key verbatim.
  defp parse_value("dl", ""), do: {:error, :invalid_value}
  defp parse_value("dl", value), do: {:ok, download: value}
  defp parse_value("cb", ""), do: {:error, :invalid_value}
  defp parse_value("cb", value), do: {:ok, cache_buster: value}

  defp build_norm(i, tp, lra) do
    with {:ok, i} <- norm_target(i, @norm_i_range), do: {:ok, norm: {i, tp, lra}}
  end

  defp norm_target(value, {min, max}) do
    with {:ok, number} <- decimal(value) do
      if number >= min and number <= max, do: {:ok, number}, else: {:error, :out_of_range}
    end
  end

  defp enum(value, allowed) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_value}
      atom -> {:ok, atom}
    end
  end

  defp positive_integer(value) do
    if Regex.match?(@non_negative_integer_re, value) do
      case String.to_integer(value) do
        0 -> {:error, :out_of_range}
        integer -> {:ok, integer}
      end
    else
      {:error, :invalid_integer}
    end
  end

  # Decimals are accepted only in plain notation with at most three places;
  # exponent forms and longer fractions are rejected rather than rounded, so
  # a parsed value always renders back to the characters it came from.
  defp decimal(value) do
    cond do
      Regex.match?(@decimal_re, value) -> {:ok, to_float(value)}
      Regex.match?(~r/^-?\d+\.\d+$/, value) -> {:error, :excessive_precision}
      true -> {:error, :invalid_number}
    end
  end

  defp non_negative_decimal(value) do
    with {:ok, number} <- decimal(value) do
      if number < 0, do: {:error, :out_of_range}, else: {:ok, number}
    end
  end

  defp positive(number) when number > 0, do: :ok
  defp positive(_number), do: {:error, :out_of_range}

  defp to_float(value) do
    {number, ""} = Float.parse(value)
    number
  end

  ## Validation

  defp validate_bitrate_quality(%{bitrate: nil}), do: :ok
  defp validate_bitrate_quality(%{quality: nil}), do: :ok

  defp validate_bitrate_quality(opts) do
    {:error, OptionError.new(render_key("q", opts), :mutually_exclusive, render_key("br", opts))}
  end

  defp validate_bit_depth(%{bit_depth: nil}), do: :ok
  defp validate_bit_depth(%{format: format}) when format in @lossless, do: :ok

  defp validate_bit_depth(opts) do
    {:error,
     OptionError.new(render_key("bd", opts), :requires_lossless_format, render_key("f", opts))}
  end

  defp validate_peak_options(%{format: :peaks}), do: :ok

  defp validate_peak_options(opts) do
    cond do
      opts.peak_count -> peaks_only_error("pts", opts)
      opts.peak_format -> peaks_only_error("pk_fmt", opts)
      true -> :ok
    end
  end

  defp peaks_only_error(key, opts) do
    {:error,
     OptionError.new(render_key(key, opts), :requires_peaks_format, render_key("f", opts))}
  end

  defp validate_sample_rate(%{sample_rate: nil}), do: :ok

  defp validate_sample_rate(%{format: format} = opts) when format in @lossy do
    if opts.sample_rate > @lossy_sample_rate_cap do
      {:error,
       OptionError.new(
         render_key("sr", opts),
         :sample_rate_above_lossy_cap,
         render_key("f", opts)
       )}
    else
      :ok
    end
  end

  defp validate_sample_rate(_opts), do: :ok

  defp validate_fade(%{trim_duration: nil}), do: :ok
  defp validate_fade(%{fade_in: nil}), do: :ok

  defp validate_fade(opts) do
    if opts.fade_in + opts.fade_out > opts.trim_duration do
      {:error,
       OptionError.new(render_key("fade", opts), :fade_exceeds_duration, render_key("t", opts))}
    else
      :ok
    end
  end

  ## Normalization

  defp render_key("f", opts), do: "f:" <> Atom.to_string(opts.format)

  defp render_key("br", %{bitrate: nil}), do: nil
  defp render_key("br", opts), do: "br:" <> Integer.to_string(opts.bitrate)

  defp render_key("q", %{quality: nil}), do: nil
  defp render_key("q", opts), do: "q:" <> render_number(opts.quality)

  defp render_key("sr", %{sample_rate: nil}), do: nil
  defp render_key("sr", opts), do: "sr:" <> Integer.to_string(opts.sample_rate)

  defp render_key("ch", %{channels: nil}), do: nil
  defp render_key("ch", opts), do: "ch:" <> Integer.to_string(opts.channels)

  defp render_key("bd", %{bit_depth: nil}), do: nil
  defp render_key("bd", opts), do: "bd:" <> Map.fetch!(@bit_depth_tokens, opts.bit_depth)

  defp render_key("t", %{trim_start: nil}), do: nil
  defp render_key("t", %{trim_duration: nil} = opts), do: "t:" <> render_number(opts.trim_start)

  defp render_key("t", opts) do
    "t:" <> render_number(opts.trim_start) <> ":" <> render_number(opts.trim_duration)
  end

  defp render_key("fade", %{fade_in: nil}), do: nil

  defp render_key("fade", opts) do
    "fade:" <> render_number(opts.fade_in) <> ":" <> render_number(opts.fade_out)
  end

  defp render_key("gain", %{gain: nil}), do: nil
  defp render_key("gain", opts), do: "gain:" <> render_number(opts.gain)

  defp render_key("norm", %{norm: nil}), do: nil

  defp render_key("norm", %{norm: {i, tp, lra}}) do
    Enum.map_join([i, tp, lra], ":", &render_number/1) |> then(&("norm:ebu:" <> &1))
  end

  # Under f:peaks the defaults materialize. Elsewhere these keys are a
  # validation failure, and rendering the value they were given is how the
  # error names its own segment — hence the middle clause.
  defp render_key("pts", %{format: :peaks} = opts) do
    "pts:" <> Integer.to_string(opts.peak_count || @default_peak_count)
  end

  defp render_key("pts", %{peak_count: nil}), do: nil
  defp render_key("pts", opts), do: "pts:" <> Integer.to_string(opts.peak_count)

  defp render_key("pk_fmt", %{format: :peaks} = opts) do
    token = Map.fetch!(@peak_format_tokens, opts.peak_format || @default_peak_format)
    "pk_fmt:" <> token
  end

  defp render_key("pk_fmt", %{peak_format: nil}), do: nil

  defp render_key("pk_fmt", opts) do
    "pk_fmt:" <> Map.fetch!(@peak_format_tokens, opts.peak_format)
  end

  defp render_key("dl", %{download: nil}), do: nil
  defp render_key("dl", opts), do: "dl:" <> opts.download

  defp render_key("cb", %{cache_buster: nil}), do: nil
  defp render_key("cb", opts), do: "cb:" <> opts.cache_buster

  # Minimal canonical rendering: whole values lose their fraction entirely
  # (`30`, not `30.0`), fractions keep at most the three places parsing
  # allowed. Every number in a normalized string goes through here.
  defp render_number(number) when is_integer(number), do: Integer.to_string(number)

  defp render_number(number) when is_float(number) do
    if number == trunc(number) do
      number |> trunc() |> Integer.to_string()
    else
      number
      |> :erlang.float_to_binary(decimals: @max_decimals)
      |> String.trim_trailing("0")
    end
  end
end
