defmodule AudioProxy.LogHandler do
  @moduledoc """
  Turns telemetry into the log an operator reads: one line per request, plus
  the render lifecycle behind it.

  Attached once from `AudioProxy.Application.start/2`. Nothing else in the
  tree calls `Logger` for request outcomes — a plug that wants its verdict
  logged says so in `conn.assigns`, and the render action says so by emitting
  `AudioProxy.Telemetry` events.

  ## The request line

  Driven by Bandit's own `[:bandit, :request, :stop]`, which is one event per
  request with a real monotonic duration and the byte count as sent on the
  wire. `Plug.Logger` would cost two lines per request and could not see
  either. What the line says comes from `conn.assigns`, stashed upstream:

      render 200 opts=br:96/f:opus src=local://piece.wav 18 bytes in 3.2ms
      render 422 invalid_options 61 bytes in 0.4ms
      health 200 45 bytes in 0.1ms

  The endpoint class leads (`AudioProxy.Router` assigns it), the error class
  follows the status when a request failed (`AudioProxy.ErrorJSON` assigns
  it), and the normalized options string and canonical source appear once the
  chain has got far enough to know them — a 401 knows neither, and says so by
  omission rather than with placeholders. The request id is not in the line:
  `Plug.RequestId` puts it in Logger metadata, which the formatter renders on
  every line including the render lifecycle's, so correlation works across
  all of them rather than only this one.

  ## Levels

  2xx–4xx at info: a client error is a normal outcome for a public endpoint
  and an operator paging on 401s would learn to ignore the log. 5xx and
  timeouts at warning — those are the proxy's fault. `/health` at debug,
  filtered here by endpoint class: a liveness probe every second would
  otherwise be the entire log, and splitting the router to avoid it would buy
  the same silence for more moving parts.

  `AP_LOG_LEVEL` sets the floor (`AudioProxy.Config`), so `warning` silences
  the happy path wholesale.

  ## What is deliberately not attached

  `[:bandit, :request, :exception]` — the mid-stream abort case. The render
  action has already emitted `[:audio_proxy, :render, :exception]` with the
  failure class, format and source by the time it exits, and Bandit logs the
  exit itself; a third line for one event would be noise. The cost is that a
  plug crash unrelated to a render produces Bandit's error report and no
  request line, which is a bug report either way.

  ## Redaction

  `detail` on a render exception is the one field carrying text this
  application did not construct — an ffmpeg stderr tail. Today's inputs are
  local paths, but the S3 backend hands ffmpeg presigned URLs, and a
  diagnostic that echoed one would put a live `X-Amz-Signature` into log
  storage. `redact/1` runs over every tail before it is logged, so the
  guarantee holds by construction rather than by an assumption about what
  ffmpeg prints. Everything else in a line is built from
  `AudioProxy.Telemetry`'s metadata, which carries the canonical source and
  never the ffmpeg input.
  """

  require Logger

  alias AudioProxy.{Options, Telemetry}

  @handler_id __MODULE__

  @bandit_stop [:bandit, :request, :stop]

  # A URL's query string, and bare credential parameters outside one. The
  # marker replaces the parameter *name* too: a line reading
  # "X-Amz-Signature=[redacted]" still tells a reader which credential was in
  # play, and the guarantee is that no credential material appears at all.
  @url_query ~r{(://\S*?)\?\S*}
  @credential_param ~r/\b(?:X-Amz-[\w-]+|Signature|AWSAccessKeyId|Expires)=[^\s&]*/i

  @redacted "[redacted]"

  @doc """
  Attaches the handler. Idempotent — a second call is a no-op.
  """
  @spec attach() :: :ok
  def attach do
    events = [@bandit_stop | Telemetry.render_events()]

    case :telemetry.attach_many(@handler_id, events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detaches the handler. For tests that need the log quiet."
  @spec detach() :: :ok
  def detach do
    _ = :telemetry.detach(@handler_id)
    :ok
  end

  @doc """
  Strips credential material from a diagnostic tail.

  Query strings are removed from anything URL-shaped, and credential
  parameters are removed wherever they appear.

      iex> AudioProxy.LogHandler.redact("open https://b.s3.amazonaws.com/k.wav?X-Amz-Signature=deadbeef failed")
      "open https://b.s3.amazonaws.com/k.wav?[redacted] failed"
  """
  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text) do
    text
    |> String.replace(@url_query, "\\1?#{@redacted}")
    |> String.replace(@credential_param, @redacted)
  end

  @doc false
  @spec handle_event(:telemetry.event_name(), map(), map(), term()) :: :ok
  def handle_event(@bandit_stop, measurements, %{conn: conn}, _config) do
    log(request_level(conn), fn -> request_line(conn, measurements) end)
  end

  # Bandit omits `conn` when it could not build one — a malformed request line,
  # a TLS handshake that never became HTTP. There is no request to describe.
  def handle_event(@bandit_stop, _measurements, _metadata, _config), do: :ok

  def handle_event([:audio_proxy, :render, :start], _measurements, metadata, _config) do
    log(:debug, fn -> "render start #{metadata.format} #{metadata.source}" end)
  end

  def handle_event([:audio_proxy, :render, :stop], measurements, metadata, _config) do
    log(:debug, fn ->
      "render #{metadata.outcome} #{metadata.format} #{metadata.source} " <>
        "#{measurements.bytes} bytes in #{ms(measurements.duration)}"
    end)
  end

  def handle_event([:audio_proxy, :render, :exception], measurements, metadata, _config) do
    log(:warning, fn ->
      "render failed (#{metadata.class}, exit #{inspect(metadata.exit_status)}) " <>
        "#{metadata.format} #{metadata.source} after #{measurements.bytes} bytes " <>
        "in #{ms(measurements.duration)}#{detail(metadata.detail)}"
    end)
  end

  ## The line

  defp request_line(conn, measurements) do
    [
      class(conn),
      Integer.to_string(conn.status),
      error_class(conn),
      options(conn),
      source(conn),
      "#{Map.get(measurements, :resp_body_bytes, 0)} bytes",
      "in #{ms(measurements.duration)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp class(conn), do: conn.assigns |> Map.get(:endpoint_class, :unknown) |> Atom.to_string()

  defp error_class(conn) do
    with class when not is_nil(class) <- conn.assigns[:error_class], do: Atom.to_string(class)
  end

  defp options(conn) do
    with opts when not is_nil(opts) <- conn.assigns[:options],
         do: "opts=" <> Options.normalize(opts)
  end

  defp source(conn) do
    with source when not is_nil(source) <- conn.assigns[:source] do
      "src=" <> AudioProxy.Source.canonical(source)
    end
  end

  # A render that dies after its 200 never reaches `[:bandit, :request, :stop]`
  # at all, so the status here is always one the chain chose.
  defp request_level(conn) do
    cond do
      conn.assigns[:endpoint_class] == :health -> :debug
      conn.status >= 500 -> :warning
      true -> :info
    end
  end

  defp detail(nil), do: ""
  defp detail(""), do: ""
  defp detail(text), do: ": " <> (text |> String.trim() |> redact())

  # Native units are meaningless to a reader and their scale is
  # platform-dependent; one decimal place of milliseconds is what a duration
  # is compared against.
  defp ms(native) do
    micro = System.convert_time_unit(native, :native, :microsecond)

    :erlang.float_to_binary(micro / 1_000, decimals: 1) <> "ms"
  end

  # A handler runs in the process that emitted the event, so a `Logger` call
  # here is the same call the emitting code would have made — level filtering
  # included, which is what keeps a debug line from being built at info.
  defp log(level, message_fun), do: Logger.log(level, message_fun)
end
