defmodule AudioProxy.VariantStore.Tee do
  @moduledoc """
  The write-back: a coordinator subscriber that streams a render into the
  variant store.

  The render policy (CLAUDE.md) is to render at full speed into the
  write-back and let clients lag the render — which makes the tee not a
  special mechanism but simply one more subscriber to
  `AudioProxy.RenderCoordinator`'s broadcast, one that consumes eagerly and
  writes through `AudioProxy.VariantStore.put_stream/3`. It never
  acknowledges anything (the coordinator releases the pipeline itself) and it
  never throttles anything (broadcast is a `send`, so a slow disk shows up
  as this process' mailbox, bounded by the coordinator's retention cap).

  Because it *is* a subscriber, the disconnect policy changes exactly where
  the proposal says it does: with a store configured the tee keeps the
  subscriber count above zero after the last client leaves, so the render
  completes into the store and the next request is a HIT, where cache-off
  keeps today's cancel.

  ## Ending

  Three terminal outcomes, mirroring the coordinator's own:

    * `{:done, …}` — the chunk stream ends, `put_stream/3` commits, the
      variant is readable.
    * `{:error, …}`, or the coordinator dying mid-render — the stream raises
      `AudioProxy.VariantStore.Tee.Abort`, `put_stream/3` discards its
      staging, nothing is readable. Silent here: the render's own failure
      path has already told every client and the log.
    * The *write* failing under a healthy render — logged and instrumented
      via `AudioProxy.Telemetry.store_write_failure/1`, and invisible to
      clients, whose bytes flow from the coordinator and not from the store.

  A mailbox deadline backstops all three, the same way the render action's
  does: a coordinator that stops saying anything at all cannot leave this
  process (and its staged temp file) behind forever. It restarts on every
  message and sits above `AP_RENDER_TIMEOUT`, so the pipeline's own timeout
  is what normally fires.

  Started under `AudioProxy.VariantStore.Tee.Supervisor` — placed *before*
  the render tree in the application, so on shutdown the coordinators (which
  cancel their renders, aborting their tees) go first.
  """

  alias AudioProxy.{Config, Telemetry, VariantStore}

  @supervisor __MODULE__.Supervisor

  # Added to the configured render timeout for the mailbox deadline; the
  # pipeline's timer should fire first and arrive here as a broadcast error.
  @deadline_margin 2_000

  defmodule Abort do
    @moduledoc """
    Raised inside the tee's chunk stream when the render fails, is cancelled,
    or goes silent — the signal `put_stream/3` turns into discard-and-return.
    Never an error worth reporting: the render's own path already has.
    """
    defexception [:reason]

    @impl true
    def message(%__MODULE__{reason: reason}), do: "render aborted: #{inspect(reason)}"
  end

  @doc "The task supervisor tees run under, for the application tree."
  @spec supervisor() :: {module(), keyword()}
  def supervisor, do: {Task.Supervisor, name: @supervisor}

  @doc """
  Starts a tee subscribed to `render` (a coordinator pid), writing `key`.

  The caller — the coordinator itself, in `init/1` — must register the
  returned pid as a subscriber before the first chunk is broadcast.
  """
  @spec start(pid(), VariantStore.key(), VariantStore.metadata()) ::
          {:ok, pid()} | {:error, term()}
  def start(render, key, metadata) do
    Task.Supervisor.start_child(@supervisor, fn -> run(render, key, metadata) end)
  end

  defp run(render, key, metadata) do
    monitor = Process.monitor(render)

    case VariantStore.put_stream(key, chunks(render, monitor), metadata) do
      :ok ->
        :ok

      # The render died; the store discarded its staging. Everyone who needs
      # to know already does.
      {:error, %Abort{}} ->
        :ok

      {:error, reason} ->
        Telemetry.store_write_failure(%{key: key, reason: reason})
    end
  end

  # The coordinator's broadcast, replayed as a lazy enumerable for
  # `put_stream/3`. Raising is the abort channel — see `Abort`.
  defp chunks(render, monitor) do
    deadline = Config.get(:render_timeout) * 1_000 + @deadline_margin

    Stream.resource(
      fn -> :streaming end,
      fn :streaming ->
        receive do
          {:chunk, ^render, data} -> {[data], :streaming}
          {:done, ^render, _info} -> {:halt, :done}
          {:error, ^render, failure} -> raise Abort, reason: {:render_failed, failure.class}
          {:DOWN, ^monitor, :process, ^render, reason} -> raise Abort, reason: {:down, reason}
        after
          deadline -> raise Abort, reason: :deadline
        end
      end,
      fn _state -> :ok end
    )
  end
end
