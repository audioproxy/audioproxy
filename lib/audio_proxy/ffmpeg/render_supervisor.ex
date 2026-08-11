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

  require Logger

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

  # Each render in this VM deletes its own stderr file, so this VM's directory
  # is empty at boot by construction. Siblings belong to other instances that
  # may have died with the VM — a `kill -9`, an OOM, a crashed container — and
  # are reclaimed only when their owning OS pid is no longer alive. A directory
  # whose owner cannot be established is left alone: leaking kilobytes until a
  # later boot is harmless; deleting a live instance's file is the bug being
  # fixed.
  @doc false
  def sweep_scratch do
    scratch = Render.scratch_dir()
    tmp = System.tmp_dir!()
    own = Path.basename(scratch)

    with {:ok, entries} <- File.ls(tmp) do
      entries
      |> Enum.filter(&String.starts_with?(&1, "audio_proxy_render-"))
      |> Enum.reject(&(&1 == own))
      |> Enum.each(&sweep_sibling(Path.join(tmp, &1), &1))
    end
  end

  defp sweep_sibling(path, name) do
    case owner_pid(name) do
      nil ->
        :ok

      os_pid ->
        if AudioProxy.OsProcess.alive?(os_pid) do
          :ok
        else
          reclaim(path)
        end
    end
  end

  defp owner_pid(name) do
    case Regex.run(~r/^audio_proxy_render-.*-(\d+)$/, name) do
      [_, pid_str] -> String.to_integer(pid_str)
      nil -> nil
    end
  end

  defp reclaim(path) do
    case File.rm_rf(path) do
      {:ok, _} ->
        :ok

      {:error, reason, file} ->
        Logger.warning("could not reclaim scratch #{file}: #{inspect(reason)}")
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
