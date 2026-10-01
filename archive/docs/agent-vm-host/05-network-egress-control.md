---
component: network-egress-control
source: agent-vm-host-spec.md
spec-section: §5
tags:
- agent-vm-host
- spec-component
---
# Network Egress Control

## Guest-Side Transport

Since there is no virtio-net (see [[03-vmm-firecracker|VMM: Firecracker]]), any HTTP client library expecting a `host:port` proxy target needs a local endpoint to talk to. The guest runs a minimal **vsock↔TCP shim** — e.g. `socat`, which supports `AF_VSOCK` — bound to loopback, translating `127.0.0.1:<port>` to the host-side vsock proxy port. `HTTP_PROXY`/`HTTPS_PROXY` (configured during [[04-guest-pid1-init|pid1-init's startup sequence]]) point at this loopback address.

## DNS Resolution — Deliberately Absent in the Guest

### Why It's Absent
With `HTTP_PROXY`/`HTTPS_PROXY` set, a well-behaved client never resolves the destination hostname itself:
- For HTTPS, it sends `CONNECT api.anthropic.com:443` to the proxy verbatim — the hostname travels as a string, never through `getaddrinfo()`.
- For plain HTTP, it sends an absolute-URI request line straight to the proxy.

Resolution happens **exactly once, on the host**, inside mitmproxy, using the host's own resolver. The guest's C library is never in that path for legitimate traffic.

### Empty resolv.conf — Fail Fast
Consequently, the guest's `/etc/resolv.conf` ships **empty (or pointing at `127.0.0.1` with nothing listening there)**, so any lookup fails fast (`ECONNREFUSED`) rather than hanging on a timeout. This is **not an oversight to fix** — it falls straight out of "no virtio-net device exists": even a correctly configured resolver would have no interface to send a query over.

### DNS Attempts as a Canary
This absence doubles as a **canary**: a correctly-behaved session should generate *zero* DNS attempts. Any DNS attempt that appears means some tool isn't honoring the proxy configuration. This is exactly why "DNS attempts" is one of the four signal categories [[07-bpf-monitoring|BPF]] captures, independent of allowlist/proxy enforcement — it's a structural misbehavior detector, not a policy check.

### Implementation Note — Verify Proxy Honoring Per Tool
#implementation-note Verify every tool in the Nix closure (git, pip, npm if added later) actually honors `http_proxy`/`https_proxy` for *all* of its network paths — some package managers have had bugs or separate code paths that fall back to direct resolution before honoring proxy config. Worst case here is a loud failure (BPF-flagged, request never leaves the guest), not silent exfiltration — but it's worth a smoke test per tool during image build.

## Host-Side Proxy: mitmproxy

### TLS MITM
**mitmproxy** (Python) performs full **TLS MITM**, exactly like a corporate forward proxy (Zscaler/Squid-with-SSL-bump style): it terminates TLS from the guest and re-encrypts to the real destination.

### CA Certificate Baked into the Guest Image
The proxy's CA certificate is **baked into the guest's Nix image trust store at build time** — not provisioned at runtime. Rotating the CA means rebuilding the image. See [[09-guest-rootfs|Guest Rootfs]] for the image build process this bakes into.

### Policy — Allowlist Only
**Policy: allowlist of domains/destinations only.** Everything not explicitly permitted is blocked and logged. See [[#What's on the Allowlist]] below for current contents.

### Credential Injection
The guest is configured with a **placeholder API key** (set during [[04-guest-pid1-init|pid1-init's environment setup]]). A mitmproxy addon replaces the `Authorization` header with the real Anthropic API key **only** for the allowlisted Anthropic API destination, on the way out. The real key never exists in guest memory or filesystem.

The same addon tags the flow (e.g. `flow.metadata["credential_injected"]`) with whether it actually performed the swap for that request — an audit signal recorded by [[11-session-transcript-receivers|the transcript addon]] independent of the (always redacted) header value itself.

### Why mitmproxy (vs a Custom Rust Proxy or Squid)
Chosen over a custom Rust proxy or Squid specifically for **feature fit**: mitmproxy already provides scriptable allowlisting and header rewriting with minimal custom code — despite not matching the Rust/Go/C preference order used for the rest of the stack. See [[15-decisions-log|Decisions Log]] for how this tradeoff was weighed.

### Host-Wide Singleton Service
Runs as its own host-wide singleton systemd service, independent of any session's lifecycle — see [[10-session-lifecycle-orchestration|Session Lifecycle & Host Orchestration]] for how sessions attach to and detach from this long-lived service.

## Per-Session Listen Ports

*(for splitting `proxy.jsonl` by guest — see [[11-session-transcript-receivers|Session Transcript & Stream Receivers]] for that file)*

### Why One Shared Port Doesn't Work
mitmproxy is one host-wide process serving every concurrently-running session, so a single shared listen port gives its addons no way to tell which session a given flow belongs to.

### Slot Pool Design
Fix: mitmproxy binds one additional TCP listen port **per concurrency slot** — a fixed pool of size `max_concurrent_sessions` ([[10-session-lifecycle-orchestration|the host-wide config's concurrency sizing]]), the same sizing pattern already used for [[12-production-hardening|the hugepage pool]]. A session acquires a free slot at `launch` and releases it at `stop`; that slot's index is the *same* resource-allocation concept [[12-production-hardening|jailer's per-session uid/gid allocator]] uses — **one shared slot allocator, not two independent pools**.

### Guest-Facing Bridge & Slot Assignment
Each session's guest-facing bridge (the [[#Guest-Side Transport|guest-side vsock↔TCP shim]], which is the proxy-path counterpart to [[06-workspace-and-repo-delivery|the git-service wrapper on the workspace/repo-delivery path]]) is told its assigned slot at process start and relays to `127.0.0.1:<mitm_base_port + slot>` instead of one fixed port.

### Transcript Addon Session Resolution
mitmproxy's transcript addon ([[11-session-transcript-receivers|the session-transcript receiver design]]) resolves a flow's session by reading the local port the connection arrived on (`flow.client_conn.sockname`) and looking it up against a small on-disk slot-assignment file (session_id + session_dir per slot) that `launch`/`stop` keep current. This lookup table is necessary because the mapping changes over a session's lifetime while mitmproxy itself is a long-lived singleton that never restarts between sessions.

### Implementation Note — Multiple Listen Addresses
#implementation-note Confirm mitmproxy supports multiple simultaneous listen addresses in one process (multiple `mode` entries, available in recent mitmproxy versions) before committing to this design. If it doesn't, the fallback is **one mitmproxy instance per slot** instead of per host, which would change the "host-wide singleton" framing described in [[10-session-lifecycle-orchestration|Session Lifecycle & Host Orchestration]]. #open-question

## What's on the Allowlist

### Anthropic API Endpoint
The Anthropic API endpoint (for Claude Code) — credential-injected as described above, reached as normal internet HTTPS, TLS-MITM'd.

### Host-Local Git Service (loopback entry)
[[06-workspace-and-repo-delivery|The host-local git service]] — allowlisted **not by domain** but as an exact **`127.0.0.1:<GIT_PORT>` loopback entry**, since mitmproxy itself is a host process and that address is the host's own loopback interface, where the git service actually listens. No fake internal hostname or DNS rewriting is needed.

All *other* loopback/private-range targets stay **denied**, so the proxy can't be turned into an SSRF pivot onto other host-local services. The guest never reaches `github.com` directly.

### Package Registries — Not Decided Yet
#open-question Not decided yet — may go through a local caching/pull-through mirror (matching the git approach) or be domain-allowlisted direct-to-internet, decided per ecosystem as they're added. The allowlist mechanism must support either kind of destination per entry (loopback-style local mirror, or domain-style direct internet).

## Related

- [[03-vmm-firecracker]] — "no virtio-net" is the root cause the entire vsock-based proxy design follows from
- [[06-workspace-and-repo-delivery]] — owns the host-local git service that appears on the allowlist as a loopback entry
- [[07-bpf-monitoring]] — DNS attempts (the canary described above) are one of the four signal categories it captures
- [[10-session-lifecycle-orchestration]] — wires the mitmproxy singleton into session `launch`/`stop`, and owns the concurrency-slot sizing (`max_concurrent_sessions`)
- [[11-session-transcript-receivers]] — consumes mitmproxy's per-flow output as `proxy.jsonl`, including the credential-injection audit tag
- [[12-production-hardening]] — the per-session slot allocator here is the same allocation concept as its uid/gid and hugepage pools
