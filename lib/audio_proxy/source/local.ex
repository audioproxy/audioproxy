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

  Every hostile *path* is refused by `authorize/1`, and refused the same way —
  `{:error, :not_allowed}`, which the HTTP layer renders as 404. Same status as
  a missing file, on purpose: a distinct status would turn the root into an
  existence oracle for the filesystem around it.

  A hostile *filesystem object* is a different question, and one `authorize/1`
  deliberately does not answer: a FIFO or a directory under the root is a
  perfectly legitimate path. Those are refused by `stat/1` and `ffmpeg_input/1`,
  which are the two functions that actually touch the file — see *The seam*.

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
  `parse/1` takes almost no part in this. It collapses empty and `.` segments —
  lexical work that is safe under any filesystem, and stops one file from
  wearing several cache keys — and otherwise hands the path through. It does
  not touch `..`, and it leaves a leading `/` in place, so an absolute path
  stays absolute and gets refused rather than quietly reinterpreted. Everything
  that needs to know what is on disk stays in `authorize/1`, in one place, run
  on every source including one a caller built by hand.

  Two bounds are enforced before any of it: at most 64 path components and
  1024 bytes. `Path.safe_relative/2` is superlinear
  in component count — a thousand components costs seconds of scheduler time on
  one process — so the cap is a denial-of-service control.

  ## The seam

  `stat/1` reads size and mtime and hashes them into ETag material.
  `ffmpeg_input/1` returns the resolved absolute path. Both re-run confinement
  rather than trusting an earlier `authorize/1`, and both refuse anything that
  is not a regular file: handing ffmpeg a FIFO is how you get a process that
  blocks forever on a read that never completes, holding a render slot until
  the timeout kills it.

  ## What confinement does not cover

  Confinement is defined over *paths*, and two things escape that definition.
  Both are deployment assumptions, not code defects, and both are documented in
  the README:

    * **Hardlinks.** A hardlink inside the root pointing at an inode outside it
      is indistinguishable from an ordinary file to any path-based check.
    * **Time of check to time of use.** `ffmpeg_input/1` returns a path, and
      ffmpeg opens it a moment later. Anything that can rewrite the root in that
      window can swap the file for a symlink. Closing this needs the render
      pipeline to pass an already-open descriptor, which is tracked with
      `add-render-endpoint`.

  Both require write access to the root, which is the assumption to hold:
  **mount it read-only, and do not let untrusted code write into it.**
  """

  @behaviour AudioProxy.Source.Type

  alias AudioProxy.Config

  @typedoc "A local source: a path relative to `AP_LOCAL_ROOT`, as written."
  @type t :: {:local, String.t()}

  # Symlink chains are followed, but not indefinitely; a cycle would otherwise
  # be an unkillable request. Well past anything a real layout needs.
  @max_link_hops 32

  # `Path.safe_relative/2` is superlinear in component count — measured on this
  # machine: 100 components 7.9 ms, 250 → 65 ms, 500 → 397 ms, 1000 → 2764 ms.
  # Without a cap, a ~2 KB path buys ~3 s of scheduler time on one process, so
  # the cap is a denial-of-service control, not tidiness. Both bounds are far
  # past any real audio layout, and a path longer than `PATH_MAX` could not be
  # opened anyway.
  @max_components 64
  @max_path_bytes 1024

  @impl true
  def scheme, do: "local"

  @impl true
  def tag, do: :local

  @impl true
  def parse(path) when is_binary(path) do
    case normalize(path) do
      "" -> {:error, :empty_path}
      normalized -> {:ok, {:local, normalized}}
    end
  end

  @impl true
  def canonical({:local, path}) when is_binary(path), do: "local://" <> path

  @impl true
  def authorize(source) do
    case resolve(source) do
      {:ok, _absolute} -> :ok
      {:error, _reason} -> {:error, :not_allowed}
    end
  end

  @impl true
  def stat(source) do
    with {:ok, absolute} <- resolve(source),
         {:ok, %File.Stat{size: size, mtime: mtime}} <- regular_stat(absolute) do
      {:ok, %{size: size, etag: etag(size, mtime)}}
    end
  end

  @impl true
  def ffmpeg_input(source) do
    # The file type is re-checked here rather than trusted from an earlier
    # `stat/1`: handing ffmpeg a FIFO is what makes it block forever on a read
    # that never completes, holding a render slot until the timeout. A caller
    # that skipped `stat/1`, or called them in the other order, must not be
    # able to cause that.
    with {:ok, absolute} <- resolve(source),
         {:ok, _stat} <- regular_stat(absolute) do
      {:ok, absolute}
    end
  end

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
    # `/` is refused as hard as an unset root. Every relative path is trivially
    # "under" it, so confinement stops meaning anything — and the way an
    # operator arrives there is never deliberate: `AP_LOCAL_ROOT=${DIR}/` with
    # `DIR` unset expands to exactly that. Boot validation refuses it too; this
    # is the second gate, for a config written straight into `:persistent_term`.
    with root when is_binary(root) <- Config.get(:local_root),
         {:ok, resolved} <- real_path(root),
         false <- resolved == "/",
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
    if path == "" or String.contains?(path, <<0>>) or oversized?(path) do
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

  # Checked before `Path.safe_relative/2`, never after — the point is to not
  # hand it the input that makes it expensive. Counting is linear.
  defp oversized?(path) do
    byte_size(path) > @max_path_bytes or
      length(String.split(path, "/")) > @max_components
  end

  # Lexical only, and deliberately blind to `..`: collapsing `a/b/..` here would
  # mean identity depended on a *guess* about what the filesystem looks like,
  # and `..` is `authorize/1`'s business anyway. Dropping empty and `.` segments
  # is safe under any filesystem, and stops one file from wearing several cache
  # keys (`a//b`, `a/./b`, `a/b`).
  #
  # A leading `/` survives, so an absolute path stays absolute and is refused
  # rather than silently reinterpreted as a relative one.
  defp normalize("/" <> _rest = path), do: path

  defp normalize(path) do
    path
    |> String.split("/")
    |> Enum.reject(&(&1 == "" or &1 == "."))
    |> Enum.join("/")
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

      # The only two answers that mean "carry on": `:einval` is "not a symlink",
      # `:enoent` is a component that does not exist yet — `stat/1` answers that,
      # not this function.
      {:error, errno} when errno in [:einval, :enoent] ->
        real_path(rest, candidate, hops)

      # Anything else (`:eacces` on an unreadable parent, `:eloop`, `:enotdir`)
      # means we could not determine whether this component is a symlink. A
      # confinement check on a path we failed to resolve is not a check, so it
      # is refused instead of assumed safe.
      {:error, _undetermined} ->
        {:error, :not_allowed}
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

  # Regular files only. A directory, FIFO, socket or device under the root is
  # not something to hand an encoder, and is reported as absent rather than as
  # a distinct status — same no-oracle rule as everything else here.
  defp regular_stat(absolute) do
    case File.stat(absolute, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, stat}
      _other -> {:error, :not_found}
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
