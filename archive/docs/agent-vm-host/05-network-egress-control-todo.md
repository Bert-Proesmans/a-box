---
component: network-egress-control-todo
source: 05-network-egress-control-plan.md
tags:
- agent-vm-host
- spec-todo
---
# Network Egress Control — Build Checklist

A step's top-level box is a summary — check it only once every nested box under it is checked.

## Chunk 1 — Guest-side transport foundation

- [ ] Step 1.1 — Guest-side vsock↔TCP shim binary — [[05-network-egress-control-plan#Step 1.1 — Guest-side vsock↔TCP shim binary]]
  - [ ] Packaged `socat` invocation (static build, AF_VSOCK support) binding a fixed, well-known TCP port on `127.0.0.1` inside the guest
  - [ ] On each accepted connection, opens a new vsock connection to a fixed, well-known proxy vsock port and relays bytes bidirectionally, unbounded, until either side closes
  - [ ] Throwaway host-side TCP echo listener stood up purely to exercise the relay for this step
  - [ ] Verify: launch guest via existing VMM launcher (placeholder pid1-init already starts proxy-shim child), configure throwaway host-side echo listener on the vsock proxy port, connect plain TCP client to guest's loopback shim port, confirm bytes round-trip unchanged shim → vsock → echo listener → vsock → shim → client
- [ ] Step 1.2 — DNS-absent guest configuration & fail-fast proof — [[05-network-egress-control-plan#Step 1.2 — DNS-absent guest configuration & fail-fast proof]]
  - [ ] Produces the guest's DNS resolver configuration content (empty/inert `resolv.conf`) as an artifact for [[09-guest-rootfs]] to bake in (image build itself out of scope)
  - [ ] Standalone test harness performing a `getaddrinfo()`-style hostname lookup against this exact resolver configuration
  - [ ] Flag as follow-up test obligation for [[09-guest-rootfs]]: every tool in the guest's eventual Nix closure must honor `http_proxy`/`https_proxy` for all network code paths (not attempted here — tool closure doesn't exist yet)
  - [ ] Verify: run test harness against the produced resolver config, confirm fast-failure (connection-refused-class error, not a timeout)
  - [ ] Verify: configuration artifact is in a form [[09-guest-rootfs]] can drop directly into the image's `/etc` at build time

## Chunk 2 — Host-side mitmproxy core & end-to-end reachability

- [ ] Step 2.1 — mitmproxy TLS MITM core engine, CA, and singleton framing — [[05-network-egress-control-plan#Step 2.1 — mitmproxy TLS MITM core engine, CA, and singleton framing]]
  - [ ] Generates a mitmproxy CA certificate/key pair, output as an artifact for [[09-guest-rootfs]] to later bake into the guest trust store (not done in this task)
  - [ ] Configures and packages a mitmproxy instance as a long-running foreground process (matching how a future systemd service would exec it)
  - [ ] Listens on one fixed, well-known TCP port; performs full TLS MITM using the generated CA for any HTTPS `CONNECT`
  - [ ] Forwards every request to its real destination with no allowlist restriction (open pass-through) — policy enforcement deliberately out of scope here
  - [ ] Verify: start engine directly (no guest/vsock plumbing), point a plain TLS-capable HTTP client at its listen port with the CA trusted, confirm a request to a real external HTTPS destination round-trips successfully with the client seeing the CA's cert instead of the origin's
- [ ] Step 2.2 — Host-side vsock↔TCP relay bridging guest shim to mitmproxy — [[05-network-egress-control-plan#Step 2.2 — Host-side vsock↔TCP relay bridging guest shim to mitmproxy]]
  - [ ] Host-side relay program: given a dedicated per-VM host-side vsock socket path and the fixed proxy vsock port, accepts the guest-initiated connection and relays bytes bidirectionally, unbounded (no buffering/capping/transforming), to a TCP connection against mitmproxy's listen port
  - [ ] Single fixed mitmproxy port, single guest instance for this task (no per-session multiplexing yet)
  - [ ] Standalone, directly runnable program (systemd unit wiring out of scope)
  - [ ] Verify: launch guest with real Chunk 1 shim (no longer pointed at throwaway echo listener), start this relay + the mitmproxy engine, issue a real HTTPS request from inside the guest through the loopback shim to a real external destination, confirm response arrives back correctly and mitmproxy's own console/log shows it handled and re-encrypted the request

## Chunk 3 — Allowlist enforcement

- [ ] Step 3.1 — Allowlist default-deny mechanism — [[05-network-egress-control-plan#Step 3.1 — Allowlist default-deny mechanism]]
  - [ ] Replaces open pass-through with a default-deny mitmproxy addon
  - [ ] Allowlist data structure/config format supports domain-style entries (hostname, optional port) and loopback-style entries (exact `127.0.0.1:<port>`)
  - [ ] Addon blocks and logs (without forwarding) any request whose destination doesn't exactly match an entry of either kind; allows through only matches
  - [ ] One placeholder entry of each kind configured to prove both matching paths work
  - [ ] Any other loopback/private-range destination not equal to the allowlisted loopback entry is blocked the same as any other non-matching destination (no special-casing of loopback ranges as inherently trusted)
  - [ ] Verify: through full guest → shim → relay → mitmproxy path — allowlisted domain succeeds; allowlisted loopback target succeeds; non-allowlisted domain blocked+logged; non-allowlisted loopback/private-range address (distinct from the allowed one) blocked+logged
- [ ] Step 3.2 — Real allowlist entries, git-receive-pack rejection, package-registry gap — [[05-network-egress-control-plan#Step 3.2 — Real allowlist entries, git-receive-pack rejection, package-registry gap]]
  - [ ] Configures the allowlist addon with exactly two real entries: the Anthropic API domain, and [[06-workspace-and-repo-delivery]]'s git service exact loopback address/port — replacing the two placeholder entries
  - [ ] Adds git-receive-pack path-rejection rule scoped specifically to the git service's loopback entry
  - [ ] No package-registry allowlist entry added or planned (resolved decision: no runtime package-manager installs against any registry, ever — everything pre-baked into [[09-guest-rootfs]]'s Nix closure)
  - [ ] Verify: through full guest → shim → relay → mitmproxy path — request to real Anthropic API domain allowed + TLS-MITM'd; upload-pack-style request (fetch/clone/ls-remote-shaped) to git service loopback succeeds; request with `git-receive-pack` in path against that same loopback entry rejected; any other domain or loopback/private-range address still blocked as before

## Chunk 4 — Credential injection

- [ ] Step 4.1 — Credential injection addon — [[05-network-egress-control-plan#Step 4.1 — Credential injection addon]]
  - [ ] mitmproxy addon replaces `Authorization` header with the real Anthropic API key (sourced from host-side configuration, never hardcoded/guest-reachable), only for requests matching the allowlisted Anthropic API destination
  - [ ] Tags flow metadata with a boolean recording whether the substitution happened for that request
  - [ ] For every other destination (including git service loopback entry), header left exactly as received, metadata tagged `false`
  - [ ] Exposes the destination IP mitmproxy actually connected to (via its own connection object) in a way [[11-session-transcript-receivers]]'s future transcript addon can read (not built here)
  - [ ] No file-writing or logging behavior built here — only in-memory flow tag and header substitution
  - [ ] Verify: through full guest → shim → relay → mitmproxy path — request with guest's placeholder credential to allowlisted Anthropic destination: outgoing `Authorization` header carries the real key, flow tagged `true` (checked via addon in-process state or a temporary debug log used only for verification)
  - [ ] Verify: request with same placeholder credential to git service loopback entry: header untouched, flow tagged `false`

## Chunk 5 — Per-session concurrency-slot isolation

- [ ] Step 5.1 — Shared concurrency slot allocator — [[05-network-egress-control-plan#Step 5.1 — Shared concurrency slot allocator]]
  - [ ] Allocator: given a fixed pool size (`max_concurrent_sessions`), hands out a free integer slot index, marks it in-use, accepts a release call
  - [ ] Safe for concurrent callers (multiple sessions acquiring/releasing around the same time)
  - [ ] Refuses to hand out a slot when the pool is fully allocated, reporting that condition distinctly from a normal grant
  - [ ] Persists allocation state (on-disk state file with appropriate locking) so it survives being invoked independently per call — no long-lived daemon assumed
  - [ ] Verify: acquire slots up to pool size, confirm each a distinct previously-unused index; next acquire beyond pool size refused; release one slot, confirm available for subsequent acquire; state persists correctly across separate invocations
- [ ] Step 5.2 — mitmproxy multi-listener wiring & slot-assignment file — [[05-network-egress-control-plan#Step 5.2 — mitmproxy multi-listener wiring & slot-assignment file]]
  - [ ] Extends mitmproxy engine to bind one TCP listen port per slot in the pool (fixed base port + slot index), entire pool pre-bound once at startup
  - [ ] Slot-assignment file: on-disk structure mapping each slot's assigned listen port to a session_id/session_dir pair
  - [ ] Write path invoked on slot acquire (populate entry) and release (clear entry), called from the Step 5.1 allocator's acquire/release so the two stay in lockstep by construction
  - [ ] File format/update mechanism makes live-lookup (never cache/reuse a resolved session across flows) the natural usage pattern for the future transcript addon
  - [ ] Verify: acquire two slots, confirm assignment file shows two distinct port→session_id mappings; confirm mitmproxy actually listening on both ports (bare TCP connect probe); release one slot, confirm its entry clears while the other's mapping/listener stay intact
  - [ ] Verify recycling: acquire a slot, release it, acquire a different session into that same slot/port, confirm assignment file reflects only the new occupant with no trace of the previous one
- [ ] Step 5.3 — Slot-aware guest shim and host relay — [[05-network-egress-control-plan#Step 5.3 — Slot-aware guest shim and host relay]]
  - [ ] Guest-side shim (Chunk 1) accepts its assigned slot index as a startup parameter, computes target port as base port + slot instead of one fixed port
  - [ ] Host-side relay (Chunk 2) accepts a slot index as a startup parameter, bridges to that slot's specific mitmproxy listen port instead of the one fixed port
  - [ ] Both changes are parameterizations of existing code, not new relay logic
  - [ ] Verify: acquire two slots (simulating two concurrent sessions), launch two guests each with shim on a different assigned slot, launch a matching host-side relay per guest on its own slot
  - [ ] Verify: through both guests simultaneously — each guest's HTTPS request reaches mitmproxy on its own slot's port, is allowed/blocked and credential-injected exactly as Chunks 3–4 prove for a single guest, and traffic from one guest's slot never appears on the other guest's slot

## Related

- [[05-network-egress-control-plan]] — the plan note this checklist derives from.
- [[05-network-egress-control]] — the spec note behind the plan.
