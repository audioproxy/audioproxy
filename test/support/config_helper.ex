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
    validate_keys!(overrides, "AudioProxy.ConfigHelper.put_config/1")

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

  @doc """
  Raises unless every key of `overrides` is one `AudioProxy.Config` defines.

  The config floor stops the *environment* from silently changing what a test
  asserts. This stops a *typo* from doing the same thing: `probe_timout: 1`
  merges cleanly, installs a key nothing reads, and leaves `probe_timeout` at
  whatever the floor or the boot environment gave it — so the test fails far
  from the mistake, or passes while asserting something weaker than intended.
  That sentence is why this function exists.

  `caller` names the helper the override was handed to, so the message points
  at the call site that wrote the key rather than at the merge below it.

  The acceptable set is `Map.keys(AudioProxy.Config.build!(%{}))`, computed
  here rather than restated: a new setting is accepted the moment `lib/`
  defines it, with no edit to this file. `build!/1` on an empty environment is
  pure — it reads nothing and stores nothing — and the `:s3` sub-map is checked
  one level down against `build!(%{}).s3`, because that is the group whose keys
  are least familiar. Nothing below `:s3` is a map, so there is no deeper
  recursion.

  Only key *names* are checked. Values are `AudioProxy.Config.build!/1`'s
  business, and a test that pins a deliberately invalid value is a legitimate
  thing to write.
  """
  @spec validate_keys!(map(), binary()) :: :ok
  def validate_keys!(overrides, caller) when is_map(overrides) do
    reference = AudioProxy.Config.build!(%{})

    check_keys!(overrides, Map.keys(reference), caller, "")

    case Map.fetch(overrides, :s3) do
      {:ok, s3} when is_map(s3) -> check_keys!(s3, Map.keys(reference.s3), caller, ":s3 ")
      _other -> :ok
    end
  end

  defp check_keys!(map, known, caller, label) do
    case Enum.reject(Map.keys(map), &(&1 in known)) do
      [] ->
        :ok

      [unknown | _rest] ->
        raise ArgumentError,
              "#{caller}: unknown #{label}config key #{inspect(unknown)}" <>
                suggestion(unknown, known)
    end
  end

  # Jaro is what a typo looks like to a string metric. Below the threshold the
  # key is named and nothing is guessed: a wrong suggestion sends the reader
  # somewhere worse than no suggestion at all.
  @suggestion_threshold 0.8

  defp suggestion(unknown, known) do
    unknown = Atom.to_string(unknown)

    known
    |> Enum.map(&{&1, String.jaro_distance(unknown, Atom.to_string(&1))})
    |> Enum.max_by(&elem(&1, 1), fn -> nil end)
    |> case do
      {key, score} when score > @suggestion_threshold -> " — did you mean #{inspect(key)}?"
      _none -> ""
    end
  end
end
