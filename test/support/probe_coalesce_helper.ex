defmodule AudioProxy.ProbeCoalesceHelper do
  @moduledoc """
  Clears `AudioProxy.ProbeCoordinator`'s registry between tests.

  The same hazard `AudioProxy.CoalesceHelper` exists for, one endpoint earlier
  and rather sharper. Probes coalesce on the *canonical source* —
  `local://piece.wav`, not the absolute path — so every test file that points
  `AP_LOCAL_ROOT` at a tmp directory of its own and then asks about the same
  filename is, as far as this registry is concerned, asking about one source.
  Two tests a second apart would otherwise share a verdict.

  Sharper than the render case because the coordinator holds a verdict for a
  linger *after* the probe finishes, and because tests routinely mount different
  `ffprobe` stand-ins for the same filename. A verdict produced by one test's
  stand-in is a plausible-looking answer for another test's, which is exactly
  the failure that is hard to read from the outside.

  Note what this is *not* a workaround for: a joiner attaching to a held verdict
  is the designed behaviour and has its own tests in
  `AudioProxy.ProbeCoordinatorTest`. This only stops one test's probe from being
  another test's.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @supervisor AudioProxy.ProbeCoordinator.Supervisor

  @doc """
  Stops every probe coordinator, now and again when the test exits.

  The trailing sweep matters as much as the leading one: a test that leaves a
  verdict lingering would otherwise hand it to whoever runs next.
  """
  @spec reset_probes() :: :ok
  def reset_probes do
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
