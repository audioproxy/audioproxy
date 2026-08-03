defmodule AudioProxy.Ffmpeg.Probe do
  @moduledoc """
  What ffprobe is asked about a source, and how its answer is read.

  Header-only: the argv below asks for one audio stream's sample rate and
  channel count and the container's duration, and ffprobe reads far enough to
  answer that and stops. No decoding, no transfer of the whole object — over
  an HTTP input it is a Range request or two.

  This module is argv and parsing, nothing else. Running it is
  `AudioProxy.Ffmpeg.Render`'s job, the same as running a render: the argv
  goes to a subprocess whose stdout is collected, and that buys the kill
  discipline, the `AP_RENDER_TIMEOUT` budget and the stderr classification
  without a second implementation of any of them. A probe of a source that
  404s therefore fails with `%{class: :not_found}`, exactly as a render of it
  would.

  Peaks are the first caller — `AudioProxy.Peaks` needs a sample count before
  it can place bucket boundaries — and the `/info` endpoint is the second.
  What §4 additionally wants (codec, bitrate, tags) is more `-show_entries`
  and a wider `t:info/0`; the shape here is deliberately the peaks subset
  rather than a guess at that.
  """

  @executable "ffprobe"

  # `-of json` rather than one of the flat formats: the flat ones distinguish
  # a stream field from a format field by prefix and would need the same
  # parsing with more ways to be wrong. Elixir ships a JSON decoder.
  @entries "stream=sample_rate,channels:format=duration"

  @typedoc """
  What a probe answers.

  `duration` is the container's, in seconds, and is `nil` when the container
  does not carry one — a raw stream, a live input. A caller that needs it (as
  peaks do) has to say so itself; this module reports what it found.
  """
  @type info :: %{
          duration: float() | nil,
          sample_rate: pos_integer(),
          channels: pos_integer()
        }

  @doc """
  The argument vector to probe `input_url` with.

  Passed through verbatim as a single argv element, exactly as
  `AudioProxy.Ffmpeg.Command.build/3` does — there is no shell here either.

      iex> AudioProxy.Ffmpeg.Probe.args("https://example.test/a.wav") |> Enum.take(4)
      ["-v", "error", "-select_streams", "a:0"]
  """
  @spec args(String.t()) :: [String.t()]
  def args(input_url) when is_binary(input_url) do
    ["-v", "error", "-select_streams", "a:0", "-show_entries", @entries, "-of", "json", input_url]
  end

  @doc """
  The probe binary, or `{:error, :ffprobe_not_found}`.

  Resolved per call for the reason `AudioProxy.Ffmpeg.Render` resolves `kill`
  that way: the build image and the runtime image are not the same filesystem.
  """
  @spec executable(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def executable(nil) do
    case System.find_executable(@executable) do
      nil -> {:error, :ffprobe_not_found}
      path -> {:ok, path}
    end
  end

  def executable(path) when is_binary(path) do
    if File.regular?(path), do: {:ok, path}, else: {:error, {:executable_not_found, path}}
  end

  @doc """
  Reads ffprobe's JSON into `t:info/0`.

  Numeric fields arrive as strings or numbers depending on the field and the
  ffprobe version, so both are accepted. A source with no audio stream — a
  cover image, a video-only file — has an empty `streams` list and is
  `{:error, :no_audio_stream}` rather than a crash.

      iex> AudioProxy.Ffmpeg.Probe.parse(~s({"streams":[{"sample_rate":"44100","channels":2}],"format":{"duration":"12.5"}}))
      {:ok, %{duration: 12.5, sample_rate: 44100, channels: 2}}
  """
  @spec parse(binary()) :: {:ok, info()} | {:error, term()}
  def parse(output) when is_binary(output) do
    with {:ok, %{"streams" => streams} = decoded} <- decode(output),
         [stream | _rest] <- streams,
         {:ok, sample_rate} <- integer(stream["sample_rate"]),
         {:ok, channels} <- integer(stream["channels"]) do
      {:ok,
       %{
         duration: duration(decoded),
         sample_rate: sample_rate,
         channels: channels
       }}
    else
      [] -> {:error, :no_audio_stream}
      {:ok, _decoded} -> {:error, :no_audio_stream}
      {:error, _reason} = error -> error
    end
  end

  defp decode(output) do
    case JSON.decode(output) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, :unreadable_probe}
      {:error, _reason} -> {:error, :unreadable_probe}
    end
  end

  # `N/A` is what ffprobe writes for a duration it could not determine, and it
  # is not an error — see `t:info/0`.
  defp duration(%{"format" => %{"duration" => value}}), do: number(value)
  defp duration(_decoded), do: nil

  defp number(value) when is_number(value), do: value * 1.0

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp number(_value), do: nil

  defp integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _otherwise -> {:error, :unreadable_probe}
    end
  end

  defp integer(_value), do: {:error, :unreadable_probe}
end
