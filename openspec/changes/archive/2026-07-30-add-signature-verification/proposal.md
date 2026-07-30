## Why

Every URL is signed (API doc §1) — signature verification is the outermost gate of the request pipeline and blocks the render endpoint slice. It is pure crypto over the path, so it can be built and fully tested before any rendering exists.

## What Changes

- Implement HMAC-SHA256 signature verification: `base64url(HMAC-SHA256(key, salt ‖ path))` over everything after the signature segment.
- Constant-time comparison; 401 JSON error on missing/invalid signature.
- Dev mode: literal `insecure` accepted only when `AP_ALLOW_INSECURE` is set (disabled by default).
- A signing helper (used by tests and useful as a client reference implementation).
- Plug that extracts the signature segment and halts with 401 on failure.

## Capabilities

### New Capabilities

- `url-signing`: Generation and verification of signed proxy URLs, including the insecure dev escape hatch.

### Modified Capabilities

<!-- none -->

## Impact

- New: `lib/audio_proxy/signature.ex`, `lib/audio_proxy/plugs/verify_signature.ex`.
- Depends on: `init-project-scaffold` (config: `AP_KEY`, `AP_SALT`, `AP_ALLOW_INSECURE`).
- Blocks: `add-render-endpoint`.
