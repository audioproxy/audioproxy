## Context

Split out of `add-source-resolver`, which now owns only the encoding layer and the type dispatch table. Both forms here were implemented once already on that branch and taken back out; the decisions below are what that work established, including five defects an adversarial review found. They are recorded as decisions rather than rediscovered.

## Goals / Non-Goals

**Goals:**
- Two source types behind `AudioProxy.Source.Type`, one allowlist, one place where "is this source permitted" is answered for anything remote.

**Non-Goals:**
- The storage backends. Both forms ship with "no backend" stubs behind the seam: the HTTPS backend is `add-https-source-backend`, the S3 backend is `add-s3-client` (which has the SigV4 client it needs).
- IDN/punycode conversion. Hosts are matched as written; an operator allowlisting an internationalized domain writes its punycode form.

## Decisions

- **Canonical identity for an HTTPS source keeps the URL's own percent-encoding.** Only the outer path escaping that `AudioProxy.Source` strips is resolved. `https://h/a%2Fb` and `https://h/a/b` are different objects on many servers, so folding that layer would hand two variants one cache key. Dot segments are left alone for the same reason: only the origin knows whether it resolves them. The visible cost is that an already-escaped URL needs double escaping in the `plain/` form (`%2520`) — which is what `enc/` exists for.
- **Everything that is a second spelling of one resource folds away**: case, a trailing root dot, an explicit `:443`, an absent path, an empty query, a fragment. Each would otherwise buy one object a second cache key.
- **IP literals normalize through `:inet.parse_strict_address/1`, not the lenient parser.** The lenient one accepts inet_aton shorthand, where `1.2` means 1.0.0.2 and `01.2.3.4` means 1.2.3.4. Collapsing those would let an allowlist entry for `1.2.3.4` silently admit `01.2.3.4`; left as text they stay distinct subjects and are refused unless an operator names them.
- **Allowlist wildcards are asymmetric, and the asymmetry is the security property.** Buckets take a trailing-`*` prefix glob (`previews-*`) over a namespace the operator controls. Hosts take a leading-`*.` suffix glob anchored to a label boundary (`*.media.example`) over a namespace anyone can register into. A host *prefix* glob is the footgun this forecloses: `cdn.*` reads as "our CDN" and would mean "any host starting `cdn.`", including `cdn.evil.com`. A pattern whose `*` sits anywhere but the documented position matches nothing rather than matching loosely.
- **Bucket matching is case-sensitive, host matching folds case.** That is what S3 and DNS respectively do.
- **An IP-literal host is matched bracketless** — the pattern for `https://[::1]/…` is `::1` — because that is the form `URI` parses out. Documented, because the canonical URL shows the brackets and the mismatch would otherwise fail closed and silently.
- **Authorization must return a verdict, never raise.** The gate re-parses the URL it is handed rather than trusting the tuple's shape, so a caller that constructs one by hand gets `{:error, :not_allowed}` instead of a `URI.Error` out of a security check.
- **`http://` and userinfo are refused at the grammar**, not merely left unallowlisted. Cleartext fetches and credentials-in-URL have no place in a source, and refusing them early keeps the allowlist a single-axis policy: host, and nothing else.

## Risks / Trade-offs

- [An HTTPS source is an SSRF vector even behind an allowlist] → deny-by-default when the variable is unset, https-only, no userinfo, and the allowlist gates the host rather than the URL. Allowlisted hosts are trusted by definition; that trust is the operator's to grant, and the README says so.
- [Two source types in one slice] → they share the allowlist mechanism and the "remote, therefore gated" posture; splitting them would duplicate that and leave the pattern matcher homeless.
- [Both forms ship before their storage backends] → deliberate: the backends implement against the seam these forms define. Until they land, a remote source parses and authorizes but cannot be rendered — pinned by an explicit test per form, so the gap is a failing assertion away from being forgotten.
