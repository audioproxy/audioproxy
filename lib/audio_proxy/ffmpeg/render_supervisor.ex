defmodule AudioProxy.Ffmpeg.RenderSupervisor do
  @moduledoc """
  Supervises the running renders — one child per subprocess.

  A `DynamicSupervisor` rather than a pool: renders are started on demand by
  request-handling processes, live as long as their subprocess, and are never
  restarted (`AudioProxy.Ffmpeg.Render` is `:temporary`). What bounds the
  number of them is `AP_MAX_CONCURRENCY`, enforced by the semaphore slice, not
  a supervisor limit — a render that is refused should be refused before a
  subprocess is spawned, with a 429, rather than by failing to start here.

  Being in the supervision tree is also what makes shutdown a lifecycle path
  like any other: stopping the application terminates these children, each
  child's `terminate/2` runs, and the subprocesses go with them.
  """

  use DynamicSupervisor

  alias AudioProxy.Ffmpeg.Render

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    sweep_scratch()

    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # Each render deletes its own stderr file, so anything still here belongs to
  # a render that died with the VM — a `kill -9`, an OOM, a crashed container.
  # Boot is the one moment at which "nothing is running, so everything here is
  # stale" is true, which makes it the one safe moment to sweep.
  defp sweep_scratch do
    scratch = Render.scratch_dir()

    with {:ok, entries} <- File.ls(scratch) do
      Enum.each(entries, &File.rm(Path.join(scratch, &1)))
    end
  end

  @doc """
  Starts a supervised render. See `AudioProxy.Ffmpeg.Render.start_link/1` for
  the options.

  `:consumer` is **required** here, unlike in `Render.start_link/1` where it
  defaults to the caller. Under a `DynamicSupervisor` the caller is the
  supervisor, so that default would quietly mail the whole chunk stream into
  the supervisor's mailbox and leave the process that wanted the bytes waiting
  forever. Omitting it raises at the call site instead, because it is a bug in
  the caller rather than a condition to handle.

  A `:peaks` option selects `AudioProxy.Peaks.Render` instead, which speaks the
  same contract and runs two of these underneath itself. Dispatching here
  rather than in `AudioProxy.RenderCoordinator` is what keeps coalescing,
  write-back and delivery ignorant of the one format that is not an encode —
  and the inner renders arrive here without the key, so they dispatch to the
  plain pipeline the way everything else does.
  """
  @spec start_render(keyword()) :: DynamicSupervisor.on_start_child()
  def start_render(opts) when is_list(opts) do
    _consumer = Keyword.fetch!(opts, :consumer)

    child =
      if Keyword.has_key?(opts, :peaks), do: {AudioProxy.Peaks.Render, opts}, else: {Render, opts}

    DynamicSupervisor.start_child(__MODULE__, child)
  end
end
