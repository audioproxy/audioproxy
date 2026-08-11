## Why

`AudioProxy.Ffmpeg.RenderSupervisor.init/1` sweeps the render scratch directory
at boot, deleting everything in it:

```elixir
defp sweep_scratch do
  scratch = Render.scratch_dir()

  with {:ok, entries} <- File.ls(scratch) do
    Enum.each(entries, &File.rm(Path.join(scratch, &1)))
  end
end
```

The directory it sweeps is namespaced per *node*:

```elixir
def scratch_dir, do: Path.join(System.tmp_dir!(), "audio_proxy_render-#{node()}")
```

and the comment above it says exactly what that namespacing is for:

> Namespaced per node, because the sweep deletes everything it finds. Two
> instances sharing a `/tmp` — a dev server and a `mix test` run on one laptop
> is the everyday case — would otherwise delete each other's live stderr files
> at boot, and the symptom would be a render that failed with no diagnostics
> and an unhelpful `:render_failed`.

**The namespacing does not achieve that, because a non-distributed VM is always
`nonode@nohost`.** Every `mix test` run, and every `mix run`/release started
without `--name`, resolves `scratch_dir/0` to the same
`audio_proxy_render-nonode@nohost`. So the case the comment names as the
everyday one is precisely the case that is not covered: two runs sharing a
`/tmp` sweep each other's live stderr files at boot, and each surviving render
misclassifies, because the classifier reads a file that is no longer there.

## Evidence

Reproduced while verifying `extract-test-fixtures`. Two checkouts of
**unconverted** code, `mix test --only ffmpeg` concurrently, twelve runs: the
failure appeared in **five**, in both of the classifier's flavours.

```
1) test real failures a nonexistent input classifies as :not_found
   right: {:error, %{exit_status: 254, stderr: "", class: :render_failed}, ""}

1) test real failures a non-audio input classifies as :undecodable
   right: {:error, %{exit_status: 183, stderr: "", class: :render_failed}, ""}
```

`stderr: ""` with a non-zero exit is the signature: `stderr_tail/1` returns `""`
for a file it cannot read, `classify/1` matches no pattern against an empty
string, and every real failure therefore degrades to `:render_failed`.

The consequence in production is not a flaky test. `:not_found` and
`:undecodable` are what the HTTP layer maps to **404** and **415**; a swept
stderr file turns both into a **500**. It needs two instances sharing a `/tmp`,
which is a developer's laptop today and any co-tenanted deployment tomorrow.

## What Changes

- `scratch_dir/0` gains an identity that actually distinguishes two VMs on one
  host, rather than one that collapses to a constant. See `design.md` — the
  candidates are OS pid, a boot-time random token, and an `AP_`-prefixed
  override, and they differ in what happens to a *crashed* instance's files.
- The boot sweep stops being "delete everything in one shared directory". What
  replaces it has to keep the property the sweep exists for — files orphaned by
  `kill -9`, OOM or a crashed container do get cleaned up — without the
  authority to delete a *live* instance's files.
- The misleading comment goes, replaced by one that describes what the code
  does.
- A regression test that fails against today's code: two scratch identities
  derived in one VM must differ, and a sweep must not remove a file belonging
  to a live instance.

## Capabilities

### Modified Capabilities

- `render-pipeline` — gains requirements for scratch isolation between instances and for
  what the boot sweep may delete.

## Impact

- Modified: `lib/audio_proxy/ffmpeg/render.ex` (`scratch_dir/0`, the comment),
  `lib/audio_proxy/ffmpeg/render_supervisor.ex` (`sweep_scratch/0`).
- Possibly new config: an `AP_` variable for the scratch root, if `design.md`'s
  decision needs one. Docs follow it if so — `README.md`'s configuration table,
  `llms-full.txt`'s config table.
- `test/audio_proxy/ffmpeg/render_lifecycle_test.exs` reads `stderr_path` from
  render state and is the natural home for the regression test.
- Small: one function's identity, one sweep's predicate.
- **Found by `extract-test-fixtures`, which fixed the same defect class in
  `test/`** and deliberately did not touch `lib/`. That change's tasks 3.3 and
  5.5 carry the reproduction; this is the deferral they name.
