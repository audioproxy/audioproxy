defmodule AudioProxy.Plugs.RenderAction do
  @moduledoc """
  The render endpoint's action: everything between "every check passed" and
  bytes on the socket.

  What runs first is the source metadata the chain could not check earlier.
  `AudioProxy.Source.stat/1` answers a missing (or non-regular, or
  gone-unreadable) source with the same generic 404 as an unauthorized one,
  and a source whose size exceeds `AP_MAX_SRC_BYTES` with 413. A source of
  unknown size passes — `AP_MAX_SRC_BYTES` is then the render pipeline's byte
  cap, per the `AudioProxy.Source.Type` contract.

  Then the render: `AudioProxy.Source.ffmpeg_input/1` says what ffmpeg should
  read, `AudioProxy.Ffmpeg.Command.build/2` says how, and
  `AudioProxy.Ffmpeg.RenderSupervisor.start_render/1` runs it with *this*
  process as consumer. The filesystem is never reached around that seam:
  `ffmpeg_input/1` is what re-checks that the target is still a regular file,
  and a FIFO handed to ffmpeg blocks forever on a read that never completes,
  holding a render slot until the timeout.

  ## The streaming loop

  A plain `receive` loop, not a GenServer: the conn belongs to this process and
  stays here. Each `{:chunk, _, data}` is written with `Plug.Conn.chunk/2` and
  acknowledged, which is what releases the pipeline's bounded buffer; `{:done,
  _, _}` ends the response; `{:error, _, failure}` is mapped by *class* through
  `AudioProxy.ErrorJSON` (classifying is the pipeline's job, choosing a status
  is this module's).

  The spawn is deliberately one call site. `add-render-coalescing` replaces
  exactly that call with a subscription to a shared render, and because the
  message contract is the same, nothing in the loop below changes.

  ## Before and after the first byte

  These are two different worlds, and the split is the whole shape of this
  module. Before the first byte nothing has been sent, so any failure is still
  an ordinary JSON error response — 404, 415, 500, 504. After the first byte
  the status line is spent: a failure can then only be signalled by tearing the
  connection down without the terminating chunk (§5: nothing better exists over
  plain HTTP), which is what `abort/3` does by exiting.

  Client disconnect is detected the way any writer detects it — the next write
  fails. `chunk/2` answering `{:error, _}` means the socket is gone, so the
  render is cancelled on the spot. That is not the only guarantee: the pipeline
  monitors its consumer and kills the subprocess when it dies, so a crash on
  this path costs an ffmpeg process no more than a clean exit does. Detection
  is bounded by chunk cadence rather than by wall clock, which is what an
  encoder producing output continuously makes acceptable.

  ## The receive deadline is a backstop, not the timeout

  `AP_RENDER_TIMEOUT` is enforced by `AudioProxy.Ffmpeg.Render`, which owns the
  subprocess and reports `%{class: :timeout}`. The deadline below is the same
  budget applied to *this* process' mailbox, so that a render which dies
  without saying anything at all cannot leave a request hanging. It is set a
  little wider on purpose: the pipeline's timer starts at spawn and this one
  restarts on every message, so the pipeline's own timeout is what a client
  normally sees, with its classification intact.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias AudioProxy.{CacheKey, Config, ErrorJSON, Source}
  alias AudioProxy.Ffmpeg.{Command, Render, RenderSupervisor}

  # §5: the URL encodes the variant, so a rendered variant is immutable.
  @cache_control "public, max-age=31536000, immutable"

  # Added to the configured render timeout for the mailbox deadline. See the
  # moduledoc: the pipeline's timer should always fire first, and this margin
  # is what keeps a scheduling hiccup from inverting the two.
  @deadline_margin 1_000

  @typedoc """
  Plug options.

    * `:executable` — the binary to render with, passed through to
      `AudioProxy.Ffmpeg.Render`. Unset means `ffmpeg` from `PATH`, which is
      what the mounted pipeline uses; tests mount a chain of their own with a
      stand-in, so the HTTP lifecycle can be driven without the real encoder.
  """
  @type opts :: keyword()

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    source = conn.assigns.source

    with {:ok, stat} <- Source.stat(source),
         :ok <- within_limit(stat.size),
         {:ok, input} <- Source.ffmpeg_input(source),
         {:ok, render} <- start_render(conn.assigns.options, input, opts) do
      await_first_chunk(conn, render, Process.monitor(render))
    else
      {:error, reason} -> ErrorJSON.halt_with(conn, reason)
    end
  end

  # `nil` size means the backing store does not know it; refusing outright
  # would make the proxy less capable than the ffmpeg it drives, so the limit
  # is enforced downstream by the render byte cap instead.
  defp within_limit(nil), do: :ok

  defp within_limit(size) do
    if size > Config.get(:max_src_bytes), do: {:error, :source_too_large}, else: :ok
  end

  defp start_render(options, input, opts) do
    start_opts =
      [args: Command.build(options, input), consumer: self()] ++
        Keyword.take(opts, [:executable])

    case RenderSupervisor.start_render(start_opts) do
      {:ok, render} ->
        {:ok, render}

      # Not a client error at all: no ffmpeg on `PATH`, or a supervisor that
      # would not start the child. 500 in the same JSON shape as every other
      # failure, with the reason in the log where an operator will look.
      {:error, reason} ->
        Logger.error("could not start render: #{inspect(reason)}")
        {:error, :render_failed}
    end
  end

  ## Before the first byte

  defp await_first_chunk(conn, render, monitor) do
    receive do
      {:chunk, ^render, data} ->
        conn |> begin() |> write(render, monitor, data)

      # A render that produced nothing and exited cleanly is a zero-length
      # variant, not an error — the headers still describe it.
      {:done, ^render, _info} ->
        demonitor(monitor)
        conn |> begin() |> halt()

      {:error, ^render, failure} ->
        demonitor(monitor)
        log_failure(failure)
        ErrorJSON.halt_with(conn, reason_for(failure))

      {:DOWN, ^monitor, :process, ^render, reason} ->
        Logger.error("render died before producing output: #{inspect(reason)}")
        ErrorJSON.halt_with(conn, :render_failed)
    after
      deadline() ->
        demonitor(monitor)
        cancel_and_drain(render)
        ErrorJSON.halt_with(conn, :render_timeout)
    end
  end

  ## After the first byte

  defp stream(conn, render, monitor) do
    receive do
      {:chunk, ^render, data} ->
        write(conn, render, monitor, data)

      {:done, ^render, _info} ->
        demonitor(monitor)
        halt(conn)

      {:error, ^render, failure} ->
        log_failure(failure)
        abort(monitor, failure.class)

      {:DOWN, ^monitor, :process, ^render, reason} ->
        Logger.error("render died mid-stream: #{inspect(reason)}")
        abort(nil, :render_failed)
    after
      deadline() ->
        Render.cancel(render)
        abort(monitor, :timeout)
    end
  end

  defp write(conn, render, monitor, data) do
    case chunk(conn, data) do
      {:ok, conn} ->
        # Acknowledging is not bookkeeping: the pipeline stops forwarding above
        # its high-water mark, so a loop that never acked would receive one
        # buffer's worth of audio and then nothing, `{:done, _, _}` included.
        Render.ack(render, byte_size(data))
        stream(conn, render, monitor)

      {:error, reason} ->
        # The client is gone. Cancelling here is what makes teardown prompt;
        # the pipeline's consumer monitor would get there anyway, and does when
        # this process dies instead of returning.
        Logger.debug("client disconnected mid-stream: #{inspect(reason)}")
        demonitor(monitor)
        cancel_and_drain(render)
        halt(conn)
    end
  end

  # After a 200 the only signal left is an abnormal close: no terminating
  # chunk, connection torn down. Exiting is how that is expressed — the adapter
  # owns the socket, and returning a conn would complete the response normally
  # and hand the client a truncated file it believes is whole.
  #
  # The reason is `:shutdown`-tagged and carries the class, so an operator
  # reading the adapter's exit report can tell a deliberate teardown from a bug
  # in this module. Bandit logs it at error level either way — the tag does not
  # buy silence, only legibility — which is why `log_failure/1` has already said
  # what went wrong by the time this runs.
  #
  # No drain here, unlike the paths that return: this process is about to die,
  # and its mailbox with it.
  defp abort(monitor, class) do
    demonitor(monitor)
    exit({:shutdown, {:render_aborted, class}})
  end

  # `cancel/1` returns only once the render has stopped, and everything the
  # render ever sent us — queued chunks, the final `%{class: :cancelled}` — was
  # sent before that reply, so it is already in the mailbox and `after 0` is a
  # drain rather than a race.
  #
  # Draining matters because this process is Bandit's *connection* process and
  # is reused for the next request on a keep-alive connection. Those messages
  # would never match again — the next request pins a different render pid — so
  # they would accumulate for the life of the connection, and every selective
  # receive in the loop above would scan past all of them.
  defp cancel_and_drain(render) do
    Render.cancel(render)
    drain(render)
  end

  defp drain(render) do
    receive do
      {:chunk, ^render, _data} -> drain(render)
      {:done, ^render, _info} -> drain(render)
      {:error, ^render, _failure} -> drain(render)
    after
      0 -> :ok
    end
  end

  ## Response head

  defp begin(conn) do
    options = conn.assigns.options

    conn
    # `nil` charset: a `charset` parameter on `audio/mpeg` is meaningless, and
    # `put_resp_content_type/2` would add one.
    |> put_resp_content_type(Command.content_type(options), nil)
    |> put_resp_header("cache-control", @cache_control)
    |> put_resp_header("etag", etag(conn))
    |> put_resp_header("x-audio-proxy", "MISS")
    |> download_header(options)
    |> send_chunked(200)
  end

  # §5: the ETag *is* the cache key. Quoted because RFC 9110 defines an
  # entity-tag as a quoted-string — a bare token is not one, and a validator a
  # cache cannot compare is worse than none.
  defp etag(conn) do
    key = CacheKey.derive!(conn.assigns.options, Source.canonical(conn.assigns.source))

    ~s("#{key}")
  end

  defp download_header(conn, %{download: nil}), do: conn

  defp download_header(conn, %{download: name}) do
    put_resp_header(conn, "content-disposition", disposition(name))
  end

  # `dl` is opaque — `AudioProxy.Options` refuses control characters in it and
  # nothing else, so it arrives here as arbitrary text that has to survive
  # being a header value. Two things follow. Backslashes and quotes are
  # escaped, or the `filename` parameter ends early and the rest of the value
  # becomes syntax. And non-ASCII bytes are not header material at all: they
  # are replaced in the quoted fallback and carried properly by RFC 5987's
  # `filename*`, which is where a client that understands it looks first.
  defp disposition(name) do
    ascii = String.replace(name, ~r/[^\x20-\x7e]/u, "_")

    quoted =
      ascii
      |> String.replace("\\", "\\\\")
      |> String.replace(~s("), ~s(\\"))

    base = ~s(attachment; filename="#{quoted}")

    # `filename*` is for what the quoted form could not carry, which is the
    # non-ASCII case only. Escaping is not loss — a quote survives the quoted
    # form intact — so it must not trigger a second parameter.
    if ascii == name do
      base
    else
      base <> "; filename*=UTF-8''" <> URI.encode(name, &URI.char_unreserved?/1)
    end
  end

  ## Failures

  # The pipeline classifies, this maps. Anything it could not classify is a
  # server-side failure: 500 rather than a plausible-looking 4xx that would
  # tell the client to stop retrying something that might well work next time.
  defp reason_for(%{class: :not_found}), do: :not_found
  defp reason_for(%{class: :undecodable}), do: :undecodable_source
  defp reason_for(%{class: :timeout}), do: :render_timeout
  defp reason_for(%{class: _other}), do: :render_failed

  defp log_failure(%{class: class, exit_status: status, stderr: stderr}) do
    Logger.warning("render failed (#{class}, exit #{inspect(status)}): #{String.trim(stderr)}")
  end

  defp demonitor(nil), do: true
  defp demonitor(monitor), do: Process.demonitor(monitor, [:flush])

  defp deadline, do: Config.get(:render_timeout) * 1_000 + @deadline_margin
end
