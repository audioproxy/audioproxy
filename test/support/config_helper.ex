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

  @doc """
  The byte-limit floor, with `overrides` merged over it.

  Both limits are pinned far above anything this suite renders, because a
  boot-time `AP_MAX_SRC_BYTES` in a developer's shell must not be able to turn
  an assertion about coordinator behaviour into a size-limit failure. That
  sentence is the whole reason this function exists; the numbers themselves say
  nothing.

  It requires nothing, and it is the floor's lower layer:
  `AudioProxy.SignedRequest.base_config/1` builds on it, adding the key material
  and the mandatory `local_root` a signing test needs. A file that only wants
  the limits — one that signs nothing and resolves no local source — takes this
  instead:

      put_config(byte_limits())
      put_config(byte_limits(variant_store: {:file, tmp_dir}))

  As in `base_config/1`, a value the test is *about* goes in `overrides`, where
  a reader sees it, and wins over the floor.

  The floor is a fixed literal, deliberately not derived from
  `AudioProxy.Config.build!/1`: deriving it would make every test's baseline
  move when a production default moves.
  """
  @spec byte_limits(keyword() | map()) :: map()
  def byte_limits(overrides \\ %{}) do
    Map.merge(
      %{max_src_bytes: 2_000_000_000, max_variant_bytes: 2_000_000_000},
      Map.new(overrides)
    )
  end
end
