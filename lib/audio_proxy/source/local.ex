defmodule AudioProxy.Source.Local do
  @moduledoc """
  The `local://` source type: files under one configured directory.

  `local://previews/track.wav` names a path relative to `AP_LOCAL_ROOT`. The
  root is deployment configuration — a bind mount, a volume, a directory on a
  laptop — and it deliberately does not appear in the source's identity, so the
  same relative path is the same variant whatever a deployment mounted it at.

  When `AP_LOCAL_ROOT` is unset, local sources are disabled: nothing is
  mounted, so nothing is served. The root *is* the allowlist for disk, which is
  why this type has no allowlist of its own.

  ## Confinement

  Everything hostile a path can be is refused by `authorize/1`, and refused the
  same way — `{:error, :not_allowed}`, which the HTTP layer renders as 404.
  Same status as a missing file, on purpose: a distinct status would turn the
  root into an existence oracle for the filesystem around it.

  The order matters more than any single check:

  1. `AudioProxy.Source` has already decoded the source exactly once and
     refused control-class code points, NUL among them. A confinement check on
     a half-decoded string proves nothing, so it does not run on one.
  2. `Path.safe_relative/2` rejects absolute paths and any `..` that climbs out
     of the root, and normalizes `.` and interior `..` away.
  3. The result is joined to the root and resolved link by link, because
     `safe_relative` does not follow symlinks — a `previews` symlinked at
     `/etc` is a perfectly safe *relative* path.
  4. The resolved path must still sit under the resolved root. This is the
     invariant, and the one the property test pins: whatever is accepted, its
     final path has the root as a prefix.

  Nothing is normalized-and-continued. A path that fails any step is refused,
  not repaired. Step 2 is stricter than step 4 in one respect worth knowing
  about: OTP treats *any* absolute symlink target as unsafe, so a link
  inside the root that spells its target absolutely is refused even though
  the target is somewhere this type would happily serve. Relative links
  inside the root work; absolute ones want a root pointed at the resolved
  location instead.
  `parse/1` takes no part in this. It rejects an empty path and otherwise hands
  the body through verbatim, so that confinement lives in exactly one place and
  runs on every source, including one a caller built by hand. The cost is that
  two spellings of one file (`a/b` and `a//b`) are two cache keys; the benefit
  is that identity stays a pure function of the source string, with no root in
  it, and there is no second, weaker gate to forget about.

  ## The seam

  `stat/1` reads size and mtime — regular files only, since a directory or a
  FIFO is not something to hand an encoder — and hashes them into ETag
  material. `ffmpeg_input/1` returns the resolved absolute path. Both re-run
  confinement rather than trusting an earlier `authorize/1`.
  """

  @behaviour AudioProxy.Source.Type

  alias AudioProxy.Config

  @typedoc "A local source: a path relative to `AP_LOCAL_ROOT`, as written."
  @type t :: {:local, String.t()}

  # Symlink chains are followed, but not indefinitely; a cycle would otherwise
  # be an unkillable request. Well past anything a real layout needs.
  @max_link_hops 32

  @impl true
  def scheme, do: "local"

  @impl true
  def tag, do: :local

  @impl true
  def parse(""), do: {:error, :empty_path}
  def parse(path) when is_binary(path), do: {:ok, {:local, path}}

  @impl true
  def canonical({:local, path}), do: "local://" <> path

  @impl true
  def authorize(source) do
    case resolve(source) do
      {:ok, _absolute} -> :ok
      {:error, _reason} -> {:error, :not_allowed}
    end
  end

  @impl true
  def stat(source) do
    with {:ok, absolute} <- resolve(source) do
      case File.stat(absolute, time: :posix) do
        {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
          {:ok, %{size: size, etag: etag(size, mtime)}}

        _other ->
          {:error, :not_found}
      end
    end
  end

  @impl true
  def ffmpeg_input(source), do: resolve(source)

  @doc """
  A short human-readable sentence for one of this type's own reasons.
  """
  @spec message(atom()) :: String.t()
  def message(:empty_path), do: "local source has an empty path"
  def message(:not_allowed), do: "local source is outside the configured root"

  ## Resolution

  # The one gate. Every entry point goes through it, and every failure — no
  # root configured, a traversal attempt, a symlink out of the root — is the
  # same `:not_allowed`.
  @spec resolve(t()) :: {:ok, String.t()} | {:error, :not_allowed}
  defp resolve({:local, path}) when is_binary(path) do
    with {:ok, root} <- root(),
         {:ok, relative} <- relative(path, root),
         {:ok, absolute} <- real_path(Path.join(root, relative)),
         :ok <- confined(absolute, root) do
      {:ok, absolute}
    end
  end

  defp resolve(_source), do: {:error, :not_allowed}

  # The root is resolved on every request rather than at boot: a bind mount can
  # be re-pointed under a running container, and a stale resolved root would be
  # a confinement check against a directory that is no longer there.
  defp root do
    with root when is_binary(root) <- Config.get(:local_root),
         {:ok, resolved} <- real_path(root),
         true <- File.dir?(resolved) do
      {:ok, resolved}
    else
      _ -> {:error, :not_allowed}
    end
  end

  defp relative(path, root) do
    # A NUL would make the Path and File calls below raise, and a gate that
    # raises is a gate that returns 500. `AudioProxy.Source` already refuses
    # them; this is the belt to that suspenders, for hand-built sources.
    if path == "" or String.contains?(path, <<0>>) do
      {:error, :not_allowed}
    else
      case Path.safe_relative(path, root) do
        # "" is what `.` and `previews/..` normalize to: the root itself.
        {:ok, ""} -> {:error, :not_allowed}
        {:ok, relative} -> {:ok, relative}
        :error -> {:error, :not_allowed}
      end
    end
  end

  # Resolves an absolute path component by component, following any symlink it
  # meets. A component that does not exist is kept as written — `stat/1`, not
  # this function, is what answers "is it there".
  defp real_path(path), do: real_path(Path.split(Path.expand(path)), "/", @max_link_hops)

  defp real_path(_components, _resolved, 0), do: {:error, :not_allowed}
  defp real_path([], resolved, _hops), do: {:ok, resolved}
  defp real_path(["/" | rest], _resolved, hops), do: real_path(rest, "/", hops)

  defp real_path([component | rest], resolved, hops) do
    candidate = Path.join(resolved, component)

    case File.read_link(candidate) do
      {:ok, target} ->
        # Restart from the root: the target may itself be absolute, or climb
        # through further links of its own.
        target
        |> Path.expand(resolved)
        |> Path.split()
        |> Kernel.++(rest)
        |> real_path("/", hops - 1)

      {:error, _not_a_link} ->
        real_path(rest, candidate, hops)
    end
  end

  # Compared segment-wise rather than as strings, so that `/dataxxx` is not
  # read as living under `/data` and a root of `/` needs no special case.
  defp confined(absolute, root) do
    if absolute != root and List.starts_with?(Path.split(absolute), Path.split(root)) do
      :ok
    else
      {:error, :not_allowed}
    end
  end

  # Size and mtime, not content: an ETag is a version marker, and hashing the
  # bytes of a multi-gigabyte master to answer `/info` would defeat the point.
  defp etag(size, mtime) do
    :sha256
    |> :crypto.hash("#{size}-#{mtime}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end
end
