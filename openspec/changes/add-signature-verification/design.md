## Context

The signature is the first path segment, computed over salt ‖ everything-after-it (API doc §1). Stdlib only: `:crypto.mac/4` and `Base.url_encode64`.

## Goals / Non-Goals

**Goals:**
- Byte-exact, constant-time verification; a reference signer usable by tests and clients.

**Non-Goals:**
- Parsing the options/source (later slices). Multiple key-pair rotation (not in v1 API doc).

## Decisions

- **Sign the raw request path**, not a re-encoded form: verification uses `conn.request_path` split once on the second `/`, so escaping ambiguities can't bite. The signed string is exactly what the client built.
- **`Plug.Crypto.secure_compare/2`** for constant-time comparison (ships with Plug — no new dep). Compare the *decoded* MAC bytes; reject non-decodable base64url before comparing.
- **Unpadded base64url** on output; accept both padded and unpadded input.
- **`insecure` handled inside the same plug** so ordering can't accidentally bypass it in prod.

## Risks / Trade-offs

- [Signing raw path means clients must sign the URL-escaped form] → document with a worked example in the README; the `enc/` source form exists precisely to avoid escaping headaches.
