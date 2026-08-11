# Design — add-azure-client

## Decision: SAS-only auth, no SharedKey

Azure offers two ways to authenticate a request with an account key: **SharedKey** (an HMAC over canonicalized headers and resource, recomputed per request, in the `Authorization` header) and a **service SAS** (an HMAC over a string-to-sign describing permissions/expiry/resource, appended to the URL as query parameters, valid for its window).

The client uses SAS for everything. Rationale:

- The proxy *must* implement SAS regardless — `presign_get/3` is the whole point of the input-side architecture (ffmpeg Range-reads a URL; source bytes never cross the BEAM).
- Every other operation the facade needs (HEAD, PUT blocks, commit, DELETE, ranged GET) is permitted by a SAS with the right permission letters, issued as a vanilla `:httpc` request with no auth header.
- SharedKey's canonicalization (sorted `x-ms-` headers, canonicalized resource with sorted query params) is precisely the fiddly, provider-drifting surface `add-s3-client` taught us not to own. SAS's string-to-sign is a fixed newline-joined field list per API version.

So: **one signing routine**, exercised by every code path including the tests — a bug in it cannot hide in an operation that uses the other scheme. Internal SAS tokens are minted per operation with short expiry and minimal permissions (`r` for HEAD/GET, `cw` for writes, `d` for delete).

Cost accepted: the account key must be present to mint SAS (that is the config group), and every URL we issue internally carries a time-boxed capability. Expiry for internal operations is short (minutes); `presign_get/3` takes the caller's TTL exactly as the S3 facade does.

## Decision: pin one `x-ms-version`, assert it in tests

The SAS string-to-sign's field list *changes between API versions* (fields were appended in 2018-11-09, 2020-02-10, 2020-12-06…). The client pins a single `x-ms-version` as a module attribute, builds the matching string-to-sign, and the test suite contains known-answer vectors for that version. Bumping the version is a deliberate edit that fails KAT vectors until the string-to-sign is updated with it. Azurite supports current versions, so the pin is whatever Azurite and the live service both accept at implementation time.

## Decision: endpoint shapes

Default endpoint is `https://{account}.blob.core.windows.net` (account-in-host). `AP_AZURE_ENDPOINT` overrides the whole origin, and when set, the account rides in the path (`{endpoint}/{account}/{container}/{blob}`) — that is Azurite's addressing and also covers sovereign clouds by origin. The canonicalized resource inside the SAS string-to-sign is `/blob/{account}/{container}/{blob}` in both shapes, so signing is endpoint-independent; only URL assembly branches.

## Decision: streaming writes are Put Block + Put Block List

Single-shot Put Blob requires the full body up front, which the tee's progressive chunks never have. Block staging fits the streaming shape natively: each arriving chunk group becomes `Put Block` with a fixed-length base64 block ID (zero-padded counter), and completion is one `Put Block List` carrying content type, cache control, and `x-ms-meta-*`. No minimum block size exists (unlike S3's 5 MiB multipart floor), so the store-side grouping constant is a throughput choice, not a correctness one; the 50,000-block ceiling is unreachable under `AP_MAX_VARIANT_BYTES` with any sane grouping, and a guard asserts it anyway. An abandoned upload leaves uncommitted blocks that Azure garbage-collects after 7 days — no cleanup obligation on our side, noted in the module doc.

## Error mapping

Same discipline as `AudioProxy.S3`: a small closed set of atoms (`:not_found`, `:access_denied`, `:not_configured`, timeouts) plus `{:http, status, body}` for the rest; consumers map exhaustively with no catch-all. Azure answers 404 `BlobNotFound`/`ContainerNotFound` (folded to `:not_found`), 403 `AuthenticationFailed`/`AuthorizationFailure` (`:access_denied`), 409s for container state — kept in the `{:http, 409, _}` escape hatch until a consumer proves a need to name them.

## Testing

- KAT vectors for the SAS string-to-sign at the pinned version (the part a live service would mask: a wrong signature against Azurite still "works" if Azurite is lenient — vectors are the ground truth).
- Azurite behind `@tag :azurite` for the full facade surface: head/get/put_stream/delete round-trips, ranged GET, metadata round-trip, 404/403 mapping.
- Property test: block ID sequence is fixed-length, ordered, unique for any chunk count.
