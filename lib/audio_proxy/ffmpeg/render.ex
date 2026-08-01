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

  ## Lifecycle

  > #### Incomplete until task 1.3 {: .warning}
  >
  > This slice lands the mechanism. Consumer death and process shutdown
  > currently close the port, which drops the subprocess' stdout and usually
  > kills it by `SIGPIPE` — *usually* is not a guarantee, and ffmpeg reading a
  > slow HTTP input may not write again for a while. The explicit
  > `SIGTERM` → `SIGKILL` escalation, the render timeout and `cancel/1` are the
  > hardening slice.
  """

  use GenServer

  require Logger

  # Forwarded-but-unacknowledged bytes at which forwarding pauses. Roughly a
  # second of 128 kbps audio is worth ~16 KB, so this is generous for previews
  # while still bounding a stalled consumer's cost to something a container can
  # hold per concurrent render.
  @high_water 1_048_576

  @typedoc "A running render. Also the handle passed to `ack/2`."
  @type t :: pid()

  @typedoc "What a consumer receives. See the moduledoc."
  @type message ::
          {:chunk, t(), binary()}
          | {:done, t(), %{exit_status: 0}}
          | {:error, t(), term()}

  defstruct [
    :port,
    :os_pid,
    :consumer,
    :monitor,
    :exit_status,
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

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    args = Keyword.fetch!(opts, :args)
    consumer = Keyword.fetch!(opts, :consumer)
    executable = Keyword.fetch!(opts, :executable)

    port =
      Port.open(
        {:spawn_executable, executable},
        [:binary, :exit_status, :use_stdio, :hide, args: args]
      )

    {:ok,
     %__MODULE__{
       port: port,
       os_pid: os_pid(port),
       consumer: consumer,
       monitor: Process.monitor(consumer)
     }}
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
  def handle_info({port, {:exit_status, status}}, %__MODULE__{port: port} = state) do
    %{state | exit_status: status} |> flush()
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %__MODULE__{monitor: monitor} = state
      ) do
    {:stop, :normal, state}
  end

  # The port is linked to its owner and we trap exits, so its closure arrives
  # here after the exit status we have already handled.
  def handle_info({:EXIT, port, _reason}, %__MODULE__{port: port} = state) do
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_port(state.port)
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
      true -> finish(state, {:error, self(), {:exit_status, state.exit_status}})
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
  defp os_pid(port) do
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
