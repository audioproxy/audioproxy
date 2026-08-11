## 1. Reproduce first

- [ ] 1.1 **Reproduce before fixing.** Two checkouts on one host, `mix test --only ffmpeg test/audio_proxy/ffmpeg/render_ffmpeg_test.exs` concurrently, repeatedly — it appeared in 5 of 12 runs while verifying `extract-test-fixtures`. The signature is `stderr: ""` with a non-zero exit and `class: :render_failed` where the test expects `:not_found` or `:undecodable`. Keep the capture; it is what task 4.2 asserts against
- [ ] 1.2 Confirm the mechanism rather than assuming it: with two runs going, watch `$TMPDIR/audio_proxy_render-nonode@nohost/` and observe one run's boot emptying it while the other's render is live

## 2. Isolate

- [ ] 2.1 `scratch_dir/0` becomes per-instance: `audio_proxy_render-#{node()}-#{System.pid()}`
- [ ] 2.2 Replace the comment above it. The current one describes a guarantee the code did not provide; the new one says what the identity is and why the pid rather than the node — a non-distributed VM is always `nonode@nohost`, which is a constant, not an identity
- [ ] 2.3 Check every reader of `scratch_dir/0` — `RenderSupervisor.sweep_scratch/0` and `Render.stderr_path/0` today — and confirm none of them cached the old value at compile time

## 3. Sweep only orphans

- [ ] 3.1 `sweep_scratch/0` walks *sibling* `audio_proxy_render-*` directories rather than its own, which is empty at boot by construction
- [ ] 3.2 A sibling is swept only when its owning pid is not alive. Reuse the project's existing liveness check rather than writing a second `kill -0`; if the current one lives in `test/support`, promote it rather than duplicating it
- [ ] 3.3 A directory whose owner cannot be established is **left alone**. Leaking kilobytes until a later boot is the harmless direction; deleting a live instance's file is the bug being fixed
- [ ] 3.4 Remove the swept directory itself, not only its contents, or the sweep leaks an empty directory per crashed instance forever

## 4. Prove it

- [ ] 4.1 A test that fails against today's code: two scratch identities derived in one VM differ. Today they are equal, because both are `nonode@nohost`
- [ ] 4.2 A test for the sweep's predicate: a directory belonging to a live pid survives it; one belonging to a dead pid does not. Use the current OS pid for the live case, and a pid that has exited for the dead one
- [ ] 4.3 Confirm nothing asserts on the *shape* of `stderr_path`. `render_lifecycle_test.exs` reads it from state; it must keep working with a pid in the path
- [ ] 4.4 Re-run 1.1's reproduction and confirm it stays green across at least a dozen concurrent rounds — it was 5 in 12, so a handful of clean rounds proves nothing

## 5. Verify

- [ ] 5.1 `mix test`, `mix test --only ffmpeg` and `mix test --include integration` green
- [ ] 5.2 `mix compile --warnings-as-errors` and `mix format --check-formatted`
- [ ] 5.3 After a full run, the system temp dir holds no `audio_proxy_render-*` directories from the run that just finished — this is the leftover `extract-test-fixtures`'s task 5.5 had to exempt, and closing it is how this change proves itself from the outside
- [ ] 5.4 No `AP_` config variable was added. If the implementation wanted one, that is a design change and `design.md` says why it was rejected — argue it there first, and follow it into `README.md` and `llms-full.txt` if the argument wins
