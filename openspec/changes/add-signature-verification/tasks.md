## 1. Core signing module

- [x] 1.1 `AudioProxy.Signature.sign(path, key, salt)` → unpadded base64url HMAC-SHA256
- [x] 1.2 `AudioProxy.Signature.verify(sig_segment, rest_of_path)` → `:ok | {:error, :invalid_signature}` with constant-time compare, padded+unpadded acceptance, insecure-mode check
- [x] 1.3 Unit tests: known-answer vectors (fixed key/salt/path → precomputed sig), tamper tests (every mutated segment fails), garbage base64url, padded/unpadded equivalence
- [x] 1.4 Property test (StreamData): for random key/salt/path, `verify(sign(path), path) == :ok` and any single-byte path mutation fails

## 2. Plug integration

- [x] 2.1 `AudioProxy.Plugs.VerifySignature`: split `request_path`, verify, halt 401 JSON on failure, stash rest-of-path in `conn.assigns`
- [x] 2.2 Plug.Test coverage: valid pass-through, 401 body shape, `insecure` allowed only with `AP_ALLOW_INSECURE`, `/health` remains unsigned

## 3. Docs

- [x] 3.1 Update README: signing algorithm, worked example (key/salt/path → URL), dev-mode warning
