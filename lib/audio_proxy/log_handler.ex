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

      render 200 opts=br:96/f:opus src=local://piece.wav cache=MISS 18 bytes in 3.2ms
      render 200 opts=f:mp3 src=local://long.wav cache=COALESCED 9600567 bytes in 3.1ms
      render 422 invalid_options 61 bytes in 0.4ms
      health 200 45 bytes in 0.1ms

  The endpoint class leads (`AudioProxy.Router` assigns it), the error class
  follows the status when a request failed (`AudioProxy.ErrorJSON` assigns
  it), and the normalized options string, canonical source and coalescing
  status appear once the chain has got far enough to know them — a 401 knows
  none of them, and says so by omission rather than with placeholders. The
  second line above is why `cache=` is worth a column: it is a request that
  attached to a render already in flight, and without the field its duration
  reads as an impossibly fast encode. The request id is not in the line:
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

  ## A handler that raises is a handler that stops existing

  `:telemetry` detaches a handler that raises, permanently and silently — so
  one malformed event does not lose one line, it loses *every* line for the
  life of the VM, and nothing says so. That makes total-ness the property
  this module cares about most, and it is defended twice.

  Nothing here reads a field it has not proved is there: statuses that are
  not integers render as `-`, durations that are not integers as `?ms`,
  absent metadata falls back rather than raising. `Integer.to_string/1` on a
  status was the concrete bug — Bandit emits `[:bandit, :request, :stop]`
  with a conn but no status when a request dies of a protocol or transport
  error (`Bandit.Pipeline`'s error path), and `conn.status >= 500` did not
  even fail loudly on it: in Elixir's term order an atom sorts above every
  number, so `nil >= 500` is `true` and a status-less request was already
  being levelled as a server error.

  Behind that, `handle_event/4` rescues anything it did not anticipate and
  logs a terse line about itself instead of dying. Swallowing an exception is
  normally the wrong instinct; here the alternative is losing the log
  wholesale, and the rescue still says what happened.

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
  #
  # The first pattern is what actually covers a presigned URL, since an ffmpeg
  # input always has a scheme. The second is for credential parameters that
  # reach a diagnostic detached from their URL, and lists the three signing
  # schemes a proxy is plausibly pointed at — S3, GCS, and Azure's `sig`.
  # Anything it does not know is a name to add here, not a design to revisit.
  #
  # Both are backtracking patterns over untrusted text, which is safe only
  # because the text is bounded: `AudioProxy.Ffmpeg.Render` caps its stderr
  # tail at 4 KB. That cap is load-bearing, not incidental.
  @url_query ~r{(://\S*?)\?\S*}
  @credential_param ~r/\b(?:X-Amz-[\w-]+|X-Goog-[\w-]+|AWSAccessKeyId|Signature|Expires|sig)=[^\s&]*/i

  @redacted "[redacted]"

  @doc """
  Attaches the handler. Idempotent — a second call is a no-op.
  """
  @spec attach() :: :ok
  def attach do
    events = [@bandit_stop, Telemetry.store_write_failure_event() | Telemetry.render_events()]

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
  def handle_event(event, measurements, metadata, config) do
    emit(event, measurements, metadata, config)
    :ok
  rescue
    exception ->
      # See the moduledoc: dying here would take every future line with it.
      Logger.error("log handler failed on #{inspect(event)}: #{Exception.message(exception)}")
      :ok
  catch
    kind, reason ->
      Logger.error("log handler failed on #{inspect(event)}: #{kind} #{inspect(reason)}")
      :ok
  end

  defp emit(@bandit_stop, measurements, %{conn: conn} = metadata, _config) do
    log(request_level(conn), fn -> request_line(conn, measurements, metadata) end)
  end

  # Bandit omits `conn` when it could not build one — a malformed request line,
  # a TLS handshake that never became HTTP. There is no request to describe.
  defp emit(@bandit_stop, _measurements, _metadata, _config), do: :ok

  defp emit([:audio_proxy, :render, :start], _measurements, metadata, _config) do
    log(:debug, fn -> "render start #{field(metadata, :format)} #{field(metadata, :source)}" end)
  end

  defp emit([:audio_proxy, :render, :stop], measurements, metadata, _config) do
    log(:debug, fn ->
      "render #{field(metadata, :outcome)} #{field(metadata, :format)} " <>
        "#{field(metadata, :source)} #{bytes(measurements, :bytes)} bytes " <>
        "in #{ms(measurements[:duration])}"
    end)
  end

  defp emit([:audio_proxy, :render, :exception], measurements, metadata, _config) do
    log(:warning, fn ->
      "render failed (#{field(metadata, :class)}, exit #{inspect(metadata[:exit_status])}) " <>
        "#{field(metadata, :format)} #{field(metadata, :source)} " <>
        "after #{bytes(measurements, :bytes)} bytes " <>
        "in #{ms(measurements[:duration])}#{detail(metadata[:detail])}"
    end)
  end

  # Warning, not error: clients were served and the render succeeded — but
  # the cache silently stopped filling, which an operator watching only
  # request lines would never see. `reason` is inspected text this module did
  # not build (an exception message can embed anything), so it is redacted
  # like a diagnostic tail.
  defp emit([:audio_proxy, :variant_store, :write_failure], _measurements, metadata, _config) do
    log(:warning, fn ->
      "variant store write failed for #{field(metadata, :key)}: " <>
        redact(inspect(metadata[:reason]))
    end)
  end

  ## The line

  defp request_line(conn, measurements, metadata) do
    [
      class(conn),
      status(conn),
      error_class(conn),
      options(conn),
      source(conn),
      cache_status(conn),
      transport_error(metadata),
      "#{bytes(measurements, :resp_body_bytes)} bytes",
      "in #{ms(measurements[:duration])}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp class(conn), do: conn.assigns |> Map.get(:endpoint_class, :unknown) |> to_string()

  # `-` rather than a number: the response never got far enough to have one.
  defp status(%{status: status}) when is_integer(status), do: Integer.to_string(status)
  defp status(_conn), do: "-"

  defp error_class(conn) do
    with class when not is_nil(class) <- conn.assigns[:error_class], do: to_string(class)
  end

  defp options(conn) do
    with %Options{} = opts <- conn.assigns[:options], do: "opts=" <> Options.normalize(opts)
  end

  defp source(conn) do
    with source when not is_nil(source) <- conn.assigns[:source] do
      "src=" <> AudioProxy.Source.canonical(source)
    end
  end

  # Without this a coalesced request is actively misleading rather than merely
  # terse: it delivers the whole variant out of a running render's backlog, so
  # the line reports megabytes in a few milliseconds and reads as an
  # impossibly fast encode. Absent before the action subscribes, and so absent
  # from every line that never got that far.
  defp cache_status(conn) do
    with status when not is_nil(status) <- conn.assigns[:render_status] do
      "cache=" <> (status |> to_string() |> String.upcase())
    end
  end

  # Bandit puts its own message here when the span ended in a protocol or
  # transport failure — the only account of what happened to a request that
  # never got a status.
  defp transport_error(metadata) do
    with error when is_binary(error) <- metadata[:error], do: "error=" <> redact(error)
  end

  # A render that dies after its 200 never reaches `[:bandit, :request, :stop]`
  # at all, so a status that *is* there is always one the chain chose. One that
  # is not means the request died below the plug, which is never routine.
  defp request_level(conn) do
    cond do
      not is_integer(conn.status) -> :warning
      conn.assigns[:endpoint_class] == :health -> :debug
      conn.status >= 500 -> :warning
      true -> :info
    end
  end

  defp detail(text) when is_binary(text) and text != "" do
    ": " <> (text |> String.trim() |> redact())
  end

  defp detail(_absent), do: ""

  defp bytes(measurements, key) do
    case measurements[key] do
      count when is_integer(count) and count >= 0 -> count
      _absent -> 0
    end
  end

  defp field(metadata, key), do: metadata |> Map.get(key, "-") |> to_string()

  # Native units are meaningless to a reader and their scale is
  # platform-dependent; one decimal place of milliseconds is what a duration
  # is compared against.
  defp ms(native) when is_integer(native) do
    micro = System.convert_time_unit(native, :native, :microsecond)

    :erlang.float_to_binary(micro / 1_000, decimals: 1) <> "ms"
  end

  defp ms(_absent), do: "?ms"

  # A handler runs in the process that emitted the event, so a `Logger` call
  # here is the same call the emitting code would have made — level filtering
  # included, which is what keeps a debug line from being built at info.
  defp log(level, message_fun), do: Logger.log(level, message_fun)
end
