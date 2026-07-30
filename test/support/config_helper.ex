defmodule AudioProxy.ConfigHelper do
  @moduledoc """
  Swaps `AudioProxy.Config` values for the duration of a single test.

  The stored config lives in `:persistent_term` so that every process — including
  the render tasks and ffmpeg port owners that later slices spawn — sees the same
  values. That makes it global state, so a test using `put_config/1` must set
  `async: false`; the previous config is restored on exit.

  Prefer `AudioProxy.Config.build!/1` over this helper when you only need to
  check parsing or validation: it is pure and safe to run async.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Merges `overrides` into the stored config, restoring the original on test exit.
  """
  @spec put_config(map()) :: AudioProxy.Config.t()
  def put_config(overrides) when is_map(overrides) do
    previous = AudioProxy.Config.all()
    on_exit(fn -> AudioProxy.Config.put_all(previous) end)

    previous |> Map.merge(overrides) |> AudioProxy.Config.put_all()
  end
end
