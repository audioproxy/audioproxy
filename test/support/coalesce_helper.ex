defmodule AudioProxy.CoalesceHelper do
  @moduledoc """
  Clears `AudioProxy.RenderCoordinator`'s registry between tests.

  Coalescing keys on the cache key, which is the normalized options plus the
  *canonical* source — `local://piece.wav`, not the absolute path. That is
  right in production, where `AP_LOCAL_ROOT` is one directory, and awkward in a
  suite where every test file points that root at a tmp dir of its own and then
  asks for the same filename: two tests a second apart would otherwise share a
  render, and the second would see `COALESCED` for something it believes it
  started.

  So tests that care about single-flight start from an empty registry. Note
  what this is *not* a workaround for: a finished coordinator lingering, and a
  later request attaching to it, is the designed behaviour and has its own
  tests. This only stops one test's renders from being another test's.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @supervisor AudioProxy.RenderCoordinator.Supervisor

  @doc """
  Stops every running coordinator, now and again when the test exits.

  The trailing sweep matters as much as the leading one: a test that leaves a
  render mid-flight would otherwise hand it to whoever runs next.
  """
  @spec reset_coordinators() :: :ok
  def reset_coordinators do
    on_exit(&stop_all/0)
    stop_all()
  end

  defp stop_all do
    @supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_id, pid, _type, _modules} ->
      DynamicSupervisor.terminate_child(@supervisor, pid)
    end)
  end
end
