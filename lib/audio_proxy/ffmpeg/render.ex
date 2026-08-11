defmodule AudioProxy.Ffmpeg.Render do
  @moduledoc """
  One render: a subprocess spawned from an argv list, its stdout streamed to a
  consumer as ordered chunks.

  `AudioProxy.Ffmpeg.Command` decides *what* to run; this module runs it. One
  GenServer owns one subprocess, under `AudioProxy.Ffmpeg.RenderSupervisor`,
  and everything downstream — coalescing, chunked delivery, write-back — is a
  consumer of the message contract below rather than of ffmpeg itself.

  ## The consumer contract

  The consumer is a process, monitored from `init/1`, and it receives:

    * `{:chunk, render, binary}` — stdout bytes, in order
    * `{:done, render, %{exit_status: 0}}` — the subprocess exited cleanly and
      every byte it wrote has been delivered
    * `{:error, render, reason}` — anything else

  `render` is the pid, which is also the handle for `ack/2`. Exactly one
  `{:done, _, _}` or `{:error, _, _}` is sent, always after the last chunk, and
  the render process stops immediately afterwards. A consumer that also wants
  to hear about a crashed render should monitor it.

  ## Argv, never a shell

  `Port.open({:spawn_executable, _}, args: argv)` executes the binary directly.
  A source URL containing `;`, `$(…)` or a space is one argv element and stays
  data — the injection-safety property `AudioProxy.Ffmpeg.Command` is written
  for only holds because nothing re-parses its output.

  ## Buffering, and what it is not

  Ports have no passive read mode: the VM reads the subprocess pipe as fast as
  the OS hands bytes over and mails them here, whether or not anyone downstream
  is ready. So this process accounts *outstanding* bytes — forwarded but not
  yet acknowledged via `ack/2`. Above the high-water mark it stops forwarding
  and queues internally; ffmpeg then fills the ~64 KB OS pipe and blocks on its
  own write. `ack/2` drops the count and releases the queue.

  That is a bounded buffer, not true backpressure — between the high-water mark
  and ffmpeg actually blocking there is a pipe's worth of slack, and a consumer
  that never acks still holds whatever this process has queued. It is enough
  for preview-sized outputs, which is the decision recorded in CLAUDE.md. The
  escalation for full-length transcodes is the named-pipe pattern: ffmpeg
  writes to a `mkfifo`, and Elixir reads it passively with `IO.binread` in raw
  mode, where the OS pipe blocking *is* the backpressure. Nothing in the
  consumer contract above would change.

  ## Lifecycle, and the orphan guarantee

  **No ffmpeg process outlives its render.** Every way this GenServer can stop
  — a clean finish, `cancel/1`, the timeout, a dead consumer, the supervisor
  shutting down at VM stop — ends in `terminate/2`, which closes the port, then
  sends `SIGTERM`, then `SIGKILL` after a two-second grace. Exits are trapped
  so that the shutdown path is one of those ways rather than an exception to
  them.

  Closing the port is not enough on its own, which is the whole reason the
  escalation exists: the BEAM does not signal the process on the far side of a
  closed port. An ffmpeg blocked reading a slow HTTP input may not touch its
  stdout for minutes, never notice, and sit there holding a slot.

  ## Failure classification

  A failed render reports `%{class: _, exit_status: _, stderr: _}`, where the
  class is one of `:not_found`, `:undecodable`, `:timeout`, `:cancelled` or
  `:render_failed`. ffmpeg exits 1 for almost everything, so the class comes
  from matching a bounded tail of its stderr; the HTTP layer maps the class to
  a status rather than reading ffmpeg's prose itself.

  stderr goes to a per-render file under `scratch_dir/0` — merging it into
  stdout would splice diagnostics into the audio.
  """

  use GenServer

  require Logger

  # Forwarded-but-unacknowledged bytes at which forwarding pauses. Roughly a
  # second of 128 kbps audio is worth ~16 KB, so this is generous for previews
  # while still bounding a stalled consumer's cost to something a container can
  # hold per concurrent render.
  @high_water 1_048_576

  # How long a subprocess gets to honour SIGTERM before SIGKILL. Long enough
  # for ffmpeg to flush and close, short enough that a cancelled request is not
  # noticeably held open. PID reuse inside this window would in principle let
  # the KILL land on an innocent process; the window makes that implausible on
  # any real system, and the alternative — never escalating — is an orphan.
  @grace 2_000

  # How long to wait for a SIGKILLed process to actually disappear. Short: the
  # kernel does not negotiate, and this only covers delivery and reaping.
  @reap_grace 1_000
  @poll_interval 25

  # A bounded slice of ffmpeg's diagnostics: enough to classify and to put in a
  # log line, not enough to be a memory hazard.
  @stderr_tail_bytes 4_096

  @typedoc "A running render. Also the handle passed to `ack/2`."
  @type t :: pid()

  @typedoc "Why a render failed. See *Failure classification* in the moduledoc."
  @type failure :: %{
          class: :not_found | :undecodable | :timeout | :cancelled | :render_failed,
          exit_status: non_neg_integer() | nil,
          stderr: binary()
        }

  @typedoc "What a consumer receives. See the moduledoc."
  @type message ::
          {:chunk, t(), binary()}
          | {:done, t(), %{exit_status: 0}}
          | {:error, t(), failure()}

  defstruct [
    :port,
    :os_pid,
    :consumer,
    :monitor,
    :exit_status,
    :stderr_path,
    :timer,
    outstanding: 0,
    pending: :queue.new()
  ]

  @doc """
  Starts a render.

  Options:

    * `:args` — the argument vector, as built by
      `AudioProxy.Ffmpeg.Command.build/3`. Required; `argv[0]` is not included.
    * `:consumer` — the process receiving the messages above. Defaults to the
      caller, which is only useful in tests; under the supervisor the caller is
      the supervisor.
    * `:executable` — the binary to run. Defaults to `ffmpeg` on `PATH`.

  Returns `{:error, :ffmpeg_not_found}` when no executable was given and none
  is on `PATH`, and `{:error, {:executable_not_found, path}}` when an explicit
  one does not exist — a boot-time misconfiguration surfacing as a start error
  rather than as an exception on the request path.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    # Resolved here rather than in `init/1` on purpose: a `{:stop, reason}` from
    # `init/1` exits an already-linked process, which takes an unsuspecting
    # caller down with it. A misconfigured binary is a plain error tuple, and no
    # process is spawned to deliver it.
    with {:ok, executable} <- executable(Keyword.get(opts, :executable)) do
      opts =
        opts
        |> Keyword.put(:executable, executable)
        |> Keyword.put_new(:consumer, self())

      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      # A render is never restarted: its output stream is gone, and the
      # consumer that was watching it has already been told. The client
      # retries; the supervisor does not.
      restart: :temporary,
      shutdown: 5_000
    }
  end

  @doc """
  Acknowledges `bytes` the consumer has finished with, releasing that much of
  the buffer.

  A consumer that never acks receives at most the high-water mark plus one
  chunk, and then nothing further — including `{:done, _, _}`.
  """
  @spec ack(t(), non_neg_integer()) :: :ok
  def ack(render, bytes) when is_integer(bytes) and bytes >= 0 do
    GenServer.cast(render, {:ack, bytes})
  end

  @doc """
  Cancels a running render.

  The consumer is told (`%{class: :cancelled}`) before the render stops, so a
  cancellation is not mistaken for a stream that simply ended. Returns `:ok`
  once the subprocess is gone, which is what makes it usable as a barrier —
  including when the caller *is* the consumer.
  """
  @spec cancel(t()) :: :ok
  def cancel(render) do
    GenServer.call(render, :cancel, cancel_timeout())
  catch
    # Already finished on its own. Cancelling something that has stopped is
    # exactly the outcome asked for.
    :exit, _reason -> :ok
  end

  @doc """
  How long `cancel/1` may block: the whole worst case — the full grace, the
  reap wait, and the `kill` calls in between — plus margin.

  A call timeout below this would be indistinguishable from the render having
  already finished, and would hand back `:ok` for a subprocess still being
  killed. Public because a caller that cancels from its own `terminate/2` has
  to give itself a shutdown budget larger than this, and a hardcoded number
  there would drift the moment the grace changes.
  """
  @spec cancel_timeout() :: pos_integer()
  def cancel_timeout, do: @grace + @reap_grace + 3_000

  @doc """
  The subprocess' OS pid, or `nil` if it was reaped before it could be read.

  Exists for tests that have to prove the process is gone; nothing on the
  request path needs it.
  """
  @spec os_pid(t()) :: pos_integer() | nil
  def os_pid(render), do: GenServer.call(render, :os_pid)

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    args = Keyword.fetch!(opts, :args)
    consumer = Keyword.fetch!(opts, :consumer)
    executable = Keyword.fetch!(opts, :executable)

    # Everything that can fail happens *before* the spawn, and the order is the
    # point rather than tidiness. A raise after `Port.open/2` crashes `init/1`
    # without running `terminate/2`, so the kill discipline never gets to run
    # and the subprocess it would have killed is already alive. `mkdir_p!/1`,
    # `Process.monitor/1` and reading the configured timeout are all fallible;
    # none of them may sit downstream of a running ffmpeg.
    stderr_path = stderr_path()
    monitor = Process.monitor(consumer)
    timeout = timeout(opts)

    port = open_port(executable, args, stderr_path)

    {:ok,
     %__MODULE__{
       port: port,
       os_pid: read_os_pid(port),
       consumer: consumer,
       monitor: monitor,
       stderr_path: stderr_path,
       timer: Process.send_after(self(), :render_timeout, timeout)
     }}
  end

  @impl true
  def handle_call(:cancel, _from, state) do
    send(state.consumer, {:error, self(), %{class: :cancelled, exit_status: nil, stderr: ""}})

    # Replying from `terminate/2`'s far side is the point: the kill discipline
    # runs before the caller is unblocked, so `cancel/1` returning means the
    # subprocess is actually gone rather than merely asked to go.
    {:stop, :normal, :ok, state}
  end

  def handle_call(:os_pid, _from, state) do
    {:reply, state.os_pid, state}
  end

  @impl true
  def handle_cast({:ack, bytes}, state) do
    # Acknowledging more than was ever forwarded is a bug in the consumer, and
    # a silent clamp would hide it while quietly disabling the bound — the
    # count would sit at zero and forwarding would never pause again. Clamp
    # anyway, since crashing a render over an accounting slip helps nobody, but
    # say so.
    if bytes > state.outstanding do
      Logger.warning(
        "render consumer acknowledged #{bytes} bytes with only #{state.outstanding} outstanding; " <>
          "the buffer bound is only as good as this count"
      )
    end

    %{state | outstanding: max(state.outstanding - bytes, 0)} |> flush()
  end

  @impl true
  def handle_info({port, {:data, data}}, %__MODULE__{port: port} = state) do
    %{state | pending: :queue.in(data, state.pending)} |> flush()
  end

  # Data messages precede the exit status, so everything the subprocess wrote
  # is already queued here — but not necessarily forwarded, which is why the
  # completion message waits on the queue draining rather than on this.
  #
  # The timer is cancelled here rather than in `finish/2`, and the difference
  # matters: between this message and the last chunk reaching a slow consumer
  # there can be an arbitrary wait, and a timer still running across it would
  # report `:timeout` for a render that had already succeeded.
  # `AP_RENDER_TIMEOUT` bounds how long ffmpeg may run, and ffmpeg has stopped.
  def handle_info({port, {:exit_status, status}}, %__MODULE__{port: port} = state) do
    %{state | exit_status: status, timer: cancel_timer(state.timer)} |> flush()
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %__MODULE__{monitor: monitor} = state
      ) do
    # Nobody left to send anything to; `terminate/2` does the killing.
    {:stop, :normal, state}
  end

  def handle_info(:render_timeout, state) do
    finish(state, {:error, self(), %{class: :timeout, exit_status: nil, stderr: ""}})
  end

  # The port is linked to its owner and we trap exits, so its closure arrives
  # here after the exit status we have already handled.
  def handle_info({:EXIT, port, _reason}, %__MODULE__{port: port} = state) do
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Every stop path arrives here — a clean finish, a cancel, a timeout, a dead
  # consumer, and the supervisor's own shutdown, which is why exits are
  # trapped. One place to kill from is the whole orphan guarantee.
  @impl true
  def terminate(_reason, state) do
    close_port(state.port)
    terminate_subprocess(state)
    File.rm(state.stderr_path)
    :ok
  end

  ## Chunk flow

  # Forward whatever the outstanding budget allows, then finish if the
  # subprocess has exited and nothing is left to forward.
  defp flush(state) do
    state = forward(state)

    cond do
      is_nil(state.exit_status) -> {:noreply, state}
      not :queue.is_empty(state.pending) -> {:noreply, state}
      state.exit_status == 0 -> finish(state, {:done, self(), %{exit_status: 0}})
      true -> finish(state, {:error, self(), failure(state)})
    end
  end

  defp forward(%__MODULE__{outstanding: outstanding} = state) when outstanding >= @high_water do
    state
  end

  defp forward(state) do
    case :queue.out(state.pending) do
      {{:value, chunk}, pending} ->
        send(state.consumer, {:chunk, self(), chunk})

        forward(%{
          state
          | pending: pending,
            outstanding: state.outstanding + byte_size(chunk)
        })

      {:empty, _pending} ->
        state
    end
  end

  defp finish(state, message) do
    send(state.consumer, message)
    {:stop, :normal, state}
  end

  ## Subprocess

  # Erlang ports offer stdout or stdout-with-stderr-merged, and nothing else.
  # Merging would splice ffmpeg's diagnostics into the audio, so stderr goes to
  # a file — and redirecting to a file needs a shell, because there is no port
  # option for it.
  #
  # Introducing a shell is exactly what `AudioProxy.Ffmpeg.Command` exists to
  # avoid, so note what is and is not interpolated: the script below is a
  # compile-time constant with no user data in it. The binary arrives as `$0`
  # and its arguments as `"$@"`, both still separate argv elements, and the
  # path arrives through the environment. A source URL full of metacharacters
  # is quoted shell *data*, never shell text. `exec` then replaces the shell
  # with ffmpeg, so the pid read below is ffmpeg's own and there is no
  # intermediate process to orphan.
  @wrapper "/bin/sh"
  @wrapper_script ~S(exec "$0" "$@" 2>"$AP_RENDER_STDERR")

  defp open_port(executable, args, stderr_path) do
    Port.open(
      {:spawn_executable, @wrapper},
      [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        args: ["-c", @wrapper_script, executable | args],
        env: [{~c"AP_RENDER_STDERR", String.to_charlist(stderr_path)}]
      ]
    )
  end

  # Close the pipes, ask politely, then insist. `Port.close/1` alone only ends
  # the conversation: the BEAM does not signal the process on the far side, and
  # an ffmpeg blocked on a slow HTTP input may not write again for minutes and
  # so never notice the closed stdout. That gap is the orphan.
  defp terminate_subprocess(%__MODULE__{os_pid: nil}), do: :ok

  # Already reaped; its status is how we got here.
  defp terminate_subprocess(%__MODULE__{exit_status: status}) when not is_nil(status), do: :ok

  defp terminate_subprocess(%__MODULE__{os_pid: os_pid}) do
    signal(os_pid, "TERM")

    unless gone_within?(os_pid, @grace) do
      Logger.warning("render subprocess #{os_pid} ignored SIGTERM for #{@grace}ms; killing")
      signal(os_pid, "KILL")

      # Signal delivery is asynchronous, and the pid stays visible until it is
      # reaped, so returning here would mean returning while the process is
      # still listed. Everything that waits on this — `cancel/1` above all —
      # would then be a barrier that guarantees nothing.
      unless gone_within?(os_pid, @reap_grace) do
        Logger.error("render subprocess #{os_pid} survived SIGKILL")
      end
    end

    :ok
  end

  defp cancel_timer(nil), do: nil

  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
    nil
  end

  # Polling beats sleeping the whole grace: the common case is a process that
  # dies on the first signal in a millisecond or two, and this is on the path
  # of every cancelled request.
  defp gone_within?(os_pid, remaining) when remaining <= 0, do: not alive?(os_pid)

  defp gone_within?(os_pid, remaining) do
    if alive?(os_pid) do
      Process.sleep(@poll_interval)
      gone_within?(os_pid, remaining - @poll_interval)
    else
      true
    end
  end

  # `kill -0` tests for existence and permission without delivering anything.
  #
  # Unanswerable counts as alive. If `kill` is missing we cannot see the
  # process *or* kill it, and answering "gone" would turn a runtime we cannot
  # police into one that looks clean: every teardown would report success and
  # every subprocess would survive. Assuming the worst instead makes the
  # escalation run, fail, and say so.
  defp alive?(os_pid), do: AudioProxy.OsProcess.alive?(os_pid)

  defp signal(os_pid, signal), do: AudioProxy.OsProcess.signal(os_pid, signal)

  ## Failure classification

  # Exit status alone cannot tell a missing file from an undecodable one —
  # ffmpeg exits 1 for both — so the stderr tail decides, and the HTTP layer
  # maps the class rather than reading ffmpeg's prose itself.
  # Anchored to the phrases ffmpeg actually emits, and no looser. A bare
  # `Forbidden` or `Invalid data` would match any diagnostic containing the
  # word — including one about something else entirely — and the cost of a
  # false match here is a wrong HTTP status on a real failure, which is worse
  # than the honest `:render_failed` these would otherwise fall through to.
  @classifiers [
    {~r/No such file or directory|Server returned 40[34]|HTTP error 40[34]|40[34] (Not Found|Forbidden)/i,
     :not_found},
    {~r/Invalid data found when processing input|could not find codec parameters/i, :undecodable}
  ]

  defp failure(state) do
    stderr = stderr_tail(state.stderr_path)

    %{class: classify(stderr), exit_status: state.exit_status, stderr: stderr}
  end

  defp classify(stderr) do
    Enum.find_value(@classifiers, :render_failed, fn {pattern, class} ->
      if Regex.match?(pattern, stderr), do: class
    end)
  end

  # The tail, not the file: a decoder can produce megabytes of complaint, and
  # this ends up in a log line and possibly an error body. Reading from an
  # offset keeps the bound real rather than trimming after the fact.
  defp stderr_tail(nil), do: ""

  defp stderr_tail(path) do
    with {:ok, %File.Stat{size: size}} when size > 0 <- File.stat(path),
         offset = max(size - @stderr_tail_bytes, 0),
         {:ok, io} <- :file.open(path, [:read, :binary]) do
      tail =
        case :file.pread(io, offset, min(size, @stderr_tail_bytes)) do
          {:ok, data} -> data
          _other -> ""
        end

      :file.close(io)
      tail
    else
      _unreadable -> ""
    end
  end

  ## Scratch

  @doc false
  # Public only so the supervisor can sweep it at boot.
  #
  # The identity is node() plus System.pid(), because a non-distributed VM is
  # always `nonode@nohost`, which is a constant, not an identity. Two `mix test`
  # runs or release instances on one host therefore get distinct scratch
  # directories; a named node that somehow shares a pid namespace is still
  # separated by the node part.
  def scratch_dir,
    do: Path.join(System.tmp_dir!(), "audio_proxy_render-#{node()}-#{System.pid()}")

  defp stderr_path do
    File.mkdir_p!(scratch_dir())

    Path.join(scratch_dir(), "stderr-#{System.unique_integer([:positive, :monotonic])}.log")
  end

  defp timeout(opts) do
    case Keyword.get(opts, :timeout) do
      nil -> AudioProxy.Config.get(:render_timeout) * 1_000
      milliseconds -> milliseconds
    end
  end

  defp executable(nil) do
    case System.find_executable("ffmpeg") do
      nil -> {:error, :ffmpeg_not_found}
      path -> {:ok, path}
    end
  end

  defp executable(path) when is_binary(path) do
    if File.regular?(path), do: {:ok, path}, else: {:error, {:executable_not_found, path}}
  end

  # Read once, at startup: `Port.info/2` answers `nil` once the port is closed,
  # and the kill discipline needs this pid precisely when the port is gone.
  #
  # `nil` here is not an error. A subprocess that exits immediately — a bad
  # argument, `ffmpeg -version` — can be reaped before this line runs, and then
  # there is nothing left to signal. The exit status is already in the mailbox.
  defp read_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  defp close_port(nil), do: :ok

  defp close_port(port) do
    # Racing the subprocess' own exit is normal, and a closed port raises
    # rather than answering `false`.
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
