defmodule AudioProxy.Source.LocalPropertyTest do
  @moduledoc """
  The one property the confinement code exists to satisfy: whatever gets in,
  ends up under the root.

  The generator is deliberately hostile — segments drawn from `..`, `.`, empty
  strings, absolute prefixes and ordinary names — because a traversal bug is
  never in the path you thought of. Nothing here asserts what *should* be
  accepted; that is the example tests' job. This asserts only that acceptance
  implies confinement, which is the security claim.
  """

  # The configured root lives in `:persistent_term`, which is global.
  use ExUnit.Case, async: false
  use ExUnitProperties

  import AudioProxy.ConfigHelper

  alias AudioProxy.Source.Local

  @moduletag :tmp_dir

  # `~` is not special to any of this, but it is special to a shell, and a path
  # that reaches ffmpeg as an argv element must not need to be.
  @segments ["..", ".", "", "a", "b b", "previews", "etc", "~", "...", "track.wav"]

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "root")
    File.mkdir_p!(Path.join(root, "previews"))
    File.write!(Path.join(root, "previews/track.wav"), "RIFFfake")

    # A file to escape to, and a link that tries.
    File.mkdir_p!(Path.join(tmp_dir, "outside"))
    File.write!(Path.join(tmp_dir, "outside/secret.wav"), "SECRET")
    File.ln_s!("../outside", Path.join(root, "escape"))

    put_config(%{local_root: root})

    %{root: root}
  end

  defp hostile_path do
    gen all(
          segments <- list_of(member_of(@segments), min_length: 1, max_length: 6),
          leading_slash <- boolean()
        ) do
      joined = Enum.join(segments, "/")
      if leading_slash, do: "/" <> joined, else: joined
    end
  end

  property "an accepted path resolves under the root", %{root: root} do
    resolved_root = real_path(root)

    check all(path <- hostile_path()) do
      case Local.authorize({:local, path}) do
        {:error, :not_allowed} ->
          :ok

        :ok ->
          assert {:ok, absolute} = Local.ffmpeg_input({:local, path})

          assert List.starts_with?(Path.split(absolute), Path.split(resolved_root)),
                 "#{inspect(path)} was accepted but resolved to #{inspect(absolute)}, " <>
                   "which is outside #{inspect(resolved_root)}"
      end
    end
  end

  property "authorization never raises, whatever it is handed" do
    check all(path <- hostile_path()) do
      assert Local.authorize({:local, path}) in [:ok, {:error, :not_allowed}]
    end
  end

  property "acceptance does not depend on the root, only confinement does", %{root: root} do
    check all(path <- hostile_path()) do
      # Canonical identity is the invariant that must survive a root change.
      assert Local.canonical({:local, path}) == "local://" <> path
      assert String.starts_with?(Local.canonical({:local, path}), "local://")
      refute String.contains?(Local.canonical({:local, path}), root)
    end
  end

  defp real_path(path) do
    path
    |> Path.split()
    |> Enum.reduce("/", fn
      "/", _acc -> "/"
      component, acc -> resolve_component(Path.join(acc, component))
    end)
  end

  defp resolve_component(candidate) do
    case File.read_link(candidate) do
      {:ok, target} -> target |> Path.expand(Path.dirname(candidate)) |> real_path()
      {:error, _not_a_link} -> candidate
    end
  end
end
