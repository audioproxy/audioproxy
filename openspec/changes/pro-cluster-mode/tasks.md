## 1. Membership

- [ ] 1.1 Cluster supervisor: dns_cluster/libcluster strategies (Fly `<app>.internal` IPv6, K8s headless DNS, static); cookie from secret; clusterless warning path
- [ ] 1.2 Fly release config: inet6 distribution, node naming from `FLY_PRIVATE_IP`; documented fly.toml pairing (concurrency limits + autostart)

## 2. Ownership & shedding

- [ ] 2.1 Rendezvous ownership module over (cache key, members); property test: all nodes agree for any member set, minimal reassignment on churn
- [ ] 2.2 Render-path integration at the single spawn/subscribe call site: owner check → Fly-Replay header or generic forward; flag per platform
- [ ] 2.3 Depth gossip broadcast + peer table; shed-by-redirect when saturated with an idle peer; cluster-wide-full → 429 unchanged

## 3. Tests

- [ ] 3.1 Multi-node ExUnit (peered nodes in test): storm → one subprocess cluster-wide; owner-loss mid-flight → re-election, duplicate tolerated
- [ ] 3.2 Degradation: discovery failure → single-node behavior; partition simulation → both sides correct; stale gossip → redirect never fails a request
- [ ] 3.3 Fly-path integration (staged app): autoscaled machine joins and takes ownership share; Fly-Replay round trip

## 4. Docs

- [ ] 4.1 PRO docs: platform setup (Fly reference walkthrough, K8s), security posture (cookie, private network, TLS knob), the hints-not-truth contract, distribution-mesh ceiling
