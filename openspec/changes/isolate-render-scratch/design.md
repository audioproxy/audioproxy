## Context

Two properties are in tension, and the current code gets one of them by giving
up the other without noticing.

1. **Isolation.** An instance must never delete a file another live instance is
   using. Violated today: `nonode@nohost` makes the namespace a constant.
2. **Reclamation.** Files orphaned by `kill -9`, an OOM kill or a crashed
   container must eventually be removed. This is why the sweep exists at all —
   each render already deletes its own stderr file on the way out
   (`File.rm(state.stderr_path)`), so the sweep only ever sees corpses.

Perfect isolation is trivial (never delete anything you did not create).
Perfect reclamation is trivial (delete everything at boot). Today's code takes
the second and mislabels it as the first. The decision is where between them to
land, and the answer differs by deployment: the shipped container is one
instance per `/tmp` and neither property is under strain, while a developer's
laptop is the case that actually breaks.

## Goals / Non-Goals

**Goals:**

- Two VMs on one host, both `nonode@nohost`, never touch each other's stderr
  files.
- Orphans from a hard kill still get reclaimed, without a human deleting
  anything by hand.
- A classification failure caused by a missing stderr file becomes impossible
  for this reason, so `:not_found` and `:undecodable` keep meaning 404 and 415.

**Non-Goals:**

- A general scratch-file framework. This is one directory holding one kind of
  short-lived file.
- Surviving `/tmp` being wiped mid-render. That is the OS's business.
- Making stderr durable or moving it out of the filesystem. The file exists
  because a Port cannot separate stderr from stdout without one; that design is
  settled.

## Decisions

**The identity becomes the OS process, not the node.** `System.pid/0` returns
the OS pid of the VM, which is exactly "this instance" — distinct for two
`mix test` runs, stable for the life of the VM, and already a string.

    Path.join(System.tmp_dir!(), "audio_proxy_render-#{node()}-#{System.pid()}")

Keeping `node()` costs nothing and still separates two *named* nodes that
somehow share a pid namespace (separate containers, shared mount).

**The sweep becomes liveness-checked, and this is the part to get right.** With
a per-pid directory, an instance's own directory is always empty at boot, so
sweeping only itself would reclaim nothing and the orphans would accumulate
forever. So the sweep looks at *sibling* directories and removes those whose
owning pid is no longer alive — `kill -0`, which the project already uses in
`AudioProxy.Eventually.alive?/1`.

Pid reuse is the obvious objection: a stale directory named for pid 4242 could
be read as live because something unrelated now holds 4242. The consequence is
benign in a way worth stating — the directory is *not* deleted, so we leak a
few kilobytes until the next boot that happens to see 4242 free. Isolation is
never violated by a wrong guess in this direction, and the failure mode of the
opposite guess (deleting a live instance's file) is the bug being fixed. When
the two are not symmetric, prefer the harmless one.

**Rejected: a boot-time random token.** Isolation is just as good and there is
no pid-reuse question, but nothing can then distinguish a crashed instance's
directory from a running one's, so reclamation needs a lock file or an mtime
heuristic. That is more machinery for a worse answer.

**Rejected: age-based sweeping** ("delete files older than an hour"). It gives
up on correctness in exchange for not having to ask whether anything is alive,
and it is wrong for exactly the render that matters: a long transcode holds its
stderr file open for as long as it runs.

**Rejected for now: an `AP_SCRATCH_ROOT` config variable.** It would let an
operator separate instances explicitly, but it makes the safe behaviour opt-in,
adds a config key, a README row and an `llms-full.txt` row, and answers a
question nobody has asked. The per-pid default is correct without it. Revisit
if a deployment turns up that needs the scratch on a specific volume.

## Risks / Trade-offs

- [The sweep now stats sibling directories at boot] → bounded by how many
  instances have ever crashed on this host, and it happens once, before the
  supervisor accepts a render. If it ever grew expensive, the answer is to skip
  it on a directory younger than this boot, not to sweep blindly.
- [`kill -0` is POSIX] → so is everything else here; the release image is
  Debian, and `AudioProxy.Eventually` already depends on it in the suite. Worth
  keeping the liveness check in one place rather than inlining a second copy.
- [A test that asserts on the *path* would now see a pid in it] →
  `render_lifecycle_test.exs` reads `stderr_path` from state but does not
  assert its shape. Checked before writing this; if that changes, the test is
  asserting an implementation detail and should stop.
- [Reclamation is now one boot later in the pid-reuse case] → stated above and
  accepted deliberately.
