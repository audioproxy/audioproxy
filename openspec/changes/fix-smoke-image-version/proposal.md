## Why

A local `bin/smoke-image` run builds the image with an empty `VERSION`. The check `OCI version label is set` then fails. The script reads the version from `mix.exs` with the regex `version:\s*"…"`. In `96e5200`, `mix.exs` changed to `@version "…"` with `version: @version`. Since then, the regex finds no match and returns `nil`. `docker build` receives `VERSION=` and the label is empty.

CI does not see this. CI builds the image with its own build arguments and runs the script with `SKIP_BUILD=1`. Thus only a local build fails, and the failure looks like an image defect.

## What Changes

- Read the version from the `@version` attribute in `mix.exs`.
- Stop the script with a clear error if it finds no version. An empty label must not be possible again after a future change to `mix.exs`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `ci-pipeline`: a local smoke build must label the image with the version from `mix.exs`, and must stop if it finds no version.

## Impact

`bin/smoke-image` only. No change to CI, the image or `lib/`.
