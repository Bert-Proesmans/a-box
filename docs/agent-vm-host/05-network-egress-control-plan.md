---
component: network-egress-control-plan
source: 05-network-egress-control.md
tags:
- agent-vm-host
- spec-plan
---
# Network Egress Control — Implementation Plan

## Blueprint

[[05-network-egress-control]] specifies the guest's entire path to the outside
world — and the host machinery that watches and rewrites everything on it.
Nothing in this component exists yet. The finished state this plan builds
toward: a guest-side vsock↔TCP shim with DNS deliberately absent; a host-side
mitmproxy engine performing full TLS MITM under a default-deny allowlist,
injecting the real Anthropic credential only where allowed, running as a
host-wide singleton; and a per-session concurrency-slot mechanism (shared
listen-port pool, slot-assignment file, slot-aware shim/relay) that lets that
one singleton process serve many concurrent, mutually-isolated sessions.

Build order follows the spec's own dependency chain: the guest can't reach
anything until its loopback shim and DNS-absent configuration exist; the host
can't enforce anything until a bare TLS-MITM engine exists and is actually
reachable from a guest through a relay; policy (allowlist) and secrecy
(credential injection) are each independently provable extensions of that
reachable, unrestricted path; and per-session isolation (the slot pool) is a
multiplication of everything already working, not a prerequisite for it — a
single guest's full path (shim → relay → mitmproxy → allowlist → credential
injection → destination) must work before multiplying it across sessions
makes sense to build or verify.

This plan does not build: the Firecracker device/vsock model
([[03-vmm-firecracker]], already planned), the guest's pid1 boot sequence
that launches the shim as a child process
([[04-guest-pid1-init]], already planned), the guest rootfs image build or
CA-trust-store baking ([[09-guest-rootfs]]), the git service itself
([[06-workspace-and-repo-delivery]]), the per-session systemd unit graph or
`launch`/`stop` CLI wiring ([[10-session-lifecycle-orchestration]]), or the
`proxy.jsonl`-writing transcript addon that consumes this component's
credential-injection tag and slot-assignment file
([[11-session-transcript-receivers]]). Where a step needs a stand-in for one
of those (a throwaway echo listener, a simulated launch/stop call), that is
called out explicitly as throwaway, not as that component's real deliverable.

**Resolution status:** all three items [[15-decisions-log]] once listed as
open against this spec are now resolved and folded into the steps below,
not re-derived: "package registry strategy per ecosystem" (Step 3.2 — this
guest has no runtime package-install path for any ecosystem at all; nothing
is added, or ever expected to be added, to the allowlist for it), "mitmproxy
multi-listener support" (Step 5.2 — confirmed against mitmproxy's own
source), and "static vs. dynamic per-slot listener lifecycle" (Step 5.2 —
the full slot pool is pre-bound once at startup, not opened/closed per
session). Three further decisions from that log were already resolved
before this plan existed and are likewise folded in rather than re-derived:
"vsock↔TCP shim implementation" (Step 1.1), "`proxy.jsonl` per-session
split" (Steps 5.1–5.2), and "`proxy.jsonl` content: resolved IP +
credential-injection audit" (Step 4.1).
## Chunks

1. **Chunk 1 — Guest-side transport foundation.** The vsock↔TCP shim binary
   and the DNS-absent guest configuration that makes hostname resolution
   fail fast instead of hang. (Steps 1.1–1.2)
2. **Chunk 2 — Host-side mitmproxy core & end-to-end reachability.** A bare
   TLS-MITM engine, plus the host-side relay that actually connects a guest
   (via Chunk 1's shim) to it — open pass-through, no policy yet. (Steps
   2.1–2.2)
3. **Chunk 3 — Allowlist enforcement.** Default-deny policy mechanism, then
   the two real entries (Anthropic API domain, git-service loopback) plus
   git-receive-pack rejection. (Steps 3.1–3.2)
4. **Chunk 4 — Credential injection.** Real-key substitution scoped to the
   Anthropic destination only, with an audit tag. (Step 4.1)
5. **Chunk 5 — Per-session concurrency-slot isolation.** The shared slot
   allocator, mitmproxy's per-slot listener/assignment-file mechanism, and
   slot-aware shim/relay — multiplying Chunks 1–4's single-guest path across
   concurrent sessions. (Steps 5.1–5.3)

---

## Step 1.1 — Guest-side vsock↔TCP shim binary

Chunk 1, first step. Foundation for this plan. Depends on the per-VM
dedicated vsock transport already proven in
[[03-vmm-firecracker-plan#Step 4 — vsock control-channel transport]]. This is
the real binary that [[04-guest-pid1-init-plan#Step 2.2 — Guest-side proxy-shim channel]]'s
placeholder stands in for — swapping pid1-init over to launch this real
binary instead of that placeholder is that plan's own follow-up, not
re-done here.

```text
You are building a component of a Firecracker-based guest VM subsystem's
network egress path, from its specification, from scratch. Nothing has been
implemented for this component yet.

Specification facts to ground this task in: there is no virtio-net device in
this guest — virtio-vsock is the only channel in or out. Any HTTP client
library expecting a conventional host:port proxy target needs a local
loopback endpoint to talk to, since it cannot reach a vsock port directly.
This component is a minimal guest-side program that binds a TCP listen
socket on loopback and translates every connection it accepts there into a
vsock connection to a fixed, well-known vsock port dedicated to proxy
traffic on the host side. It performs no protocol interpretation of its
own — it is a dumb bidirectional byte relay between the accepted TCP
connection and the vsock connection.

A settled build decision, already resolved and not to be re-derived: build
this program using `socat`'s own AF_VSOCK support (mainline since version
1.7.4), built statically via this repo's static-linking package set, rather
than writing a bespoke relay binary — matched to this repo's existing
preference for minimal custom code where an off-the-shelf tool already does
the job.

The guest's pid1-init process already knows how to launch a guest-side
proxy-shim child process by direct exec (no shell, no supervision) pointed
at a fixed loopback port and a fixed vsock port — currently wired to a
throwaway placeholder that only proves the observable contract. Swapping
that wiring over to the real binary this task produces is out of scope
here.

Task: produce a guest-side vsock↔TCP shim (a packaged `socat` invocation,
following this repo's convention for a small guest-included static
binary/tool) that: binds a fixed, well-known TCP port on `127.0.0.1` inside
the guest; on each accepted connection, opens a new vsock connection to a
fixed, well-known vsock port (the proxy port) and relays bytes
bidirectionally, unbounded, until either side closes. For this step, treat
the vsock proxy port's host-side counterpart as an arbitrary throwaway TCP
echo listener you also stand up purely to exercise the relay — the real
mitmproxy engine is a later, separate step and is out of scope here.

Verify: launch a guest through the existing VMM launcher with the
placeholder pid1-init that already starts a proxy-shim child process,
configure a throwaway host-side listener to accept the guest's vsock
proxy-port connection and echo bytes back, then connect a plain TCP client
to the guest's loopback shim port and confirm bytes round-trip unchanged
through shim → vsock → throwaway echo listener → vsock → shim → client.
This proves the shim's relay mechanics end to end before any real proxy
engine exists on the host side.
```

## Step 1.2 — DNS-absent guest configuration & fail-fast proof

Chunk 1, second step. Independent code-wise of Step 1.1, but completes the
guest-side foundation alongside it.

```text
Context already built: a guest-side vsock↔TCP shim (socat-based) that relays
a loopback TCP port to a fixed vsock proxy port, verified against a
throwaway echo listener.

Specification facts for this task: with `HTTP_PROXY`/`HTTPS_PROXY` pointed at
the loopback shim, a well-behaved client never resolves the destination
hostname itself — for HTTPS it sends `CONNECT host:port` to the proxy
verbatim, for HTTP it sends an absolute-URI request line — so the guest's
own resolver is never in the path for legitimate traffic. Real DNS
resolution happens exactly once, host-side, inside the proxy engine, using
the host's own resolver. Consequently the guest's DNS configuration must
ship deliberately empty (or pointed at `127.0.0.1` with nothing listening
there), so any lookup attempt fails immediately (`ECONNREFUSED`) rather than
hanging on a timeout — this is not an oversight to patch, it falls directly
out of there being no network interface for a query to travel over. This
absence deliberately doubles as a canary: a correctly-behaved session should
generate zero DNS attempts, and any DNS attempt observed is a structural
misbehavior signal, independent of and prior to any allowlist/policy
check — that capture already exists as one of
[[07-bpf-monitoring|BPF monitoring]]'s four signal categories and is not
rebuilt here.

Task: produce the guest's DNS resolver configuration content (an empty or
inert `resolv.conf`) as an artifact for
[[09-guest-rootfs|the guest rootfs image build]] to bake in — this task does
not build the image itself, only the configuration content and a
description of where it must land in the guest filesystem. Additionally,
write a small standalone test harness (whichever form matches this repo's
testing conventions) that performs a `getaddrinfo()`-style hostname lookup
against this exact resolver configuration and confirms it fails fast with a
connection-refused-class error rather than hanging until a timeout.

Open gap (implementation note from the specification, not a decision to make
here): every tool in the guest's eventual Nix closure (git, pip, npm if
added later) must actually honor `http_proxy`/`https_proxy` for all of its
network code paths — some package managers have had bugs or fallback paths
that resolve directly before honoring proxy config. This needs a smoke test
per tool once the guest's actual tool closure exists ([[09-guest-rootfs]],
not yet planned); flag this as a follow-up test obligation for that future
plan rather than attempting it here, since the tool closure doesn't exist
yet.

Verify: run the test harness against the produced resolver configuration and
confirm the fast-failure behavior. Confirm the configuration artifact is in
a form [[09-guest-rootfs|the guest rootfs plan]] can drop directly into the
image's `/etc` at build time.
```

---

## Step 2.1 — mitmproxy TLS MITM core engine, CA, and singleton framing

Chunk 2, first step. Pure host-side; independent of Chunk 1's code, joining
with it in Step 2.2.

```text
You are building the host-side proxy engine for a Firecracker-based guest VM
subsystem's network egress path, from its specification, from scratch.

Specification facts to ground this task in: the host-side proxy is
mitmproxy (Python), performing full TLS MITM exactly like a corporate
forward proxy (Zscaler/Squid-with-SSL-bump style) — it terminates TLS from
the guest side and re-encrypts to the real destination. Its CA
certificate is meant to be baked into the guest's trust store at image
build time (not provisioned at runtime); rotating the CA means rebuilding
the guest image. mitmproxy was chosen over a custom Rust proxy or Squid
specifically for feature fit — it already provides scriptable allowlisting
and header rewriting with minimal custom code, a deliberate exception to
this repo's usual Rust/Go/C preference order (see [[15-decisions-log]] for
the tradeoff). It runs as its own host-wide singleton systemd service,
independent of any session's lifecycle — the actual systemd unit definition
and how sessions attach/detach from it belongs to
[[10-session-lifecycle-orchestration]] (not yet planned); this task builds
the proxy engine program itself, directly runnable, not the unit file.

Task: generate a mitmproxy CA certificate/key pair for this engine to use,
output as an artifact [[09-guest-rootfs|the guest rootfs image build]] will
later bake into its trust store (not done in this task). Configure and
package a mitmproxy instance, invoked as a long-running foreground process
(matching how a systemd service would eventually exec it), that: listens on
one fixed, well-known TCP port; performs full TLS MITM using the generated
CA for any HTTPS `CONNECT` it receives; for this step only, forwards every
request to its real destination with no allowlist restriction at all (open
pass-through) — policy enforcement is a later, separate step and
deliberately out of scope here.

Verify: start the engine directly (not through any guest or vsock plumbing
yet), point a plain TLS-capable HTTP client at its listen port with the
generated CA trusted, and confirm a request to a real external HTTPS
destination round-trips successfully with the client seeing the CA's
certificate presented instead of the origin's — proving TLS MITM
re-encryption works end to end from a bare TCP client, before any
guest-side integration exists.
```

## Step 2.2 — Host-side vsock↔TCP relay bridging guest shim to mitmproxy

Chunk 2, second step. Builds on Step 1.1 (guest shim) and Step 2.1
(mitmproxy engine) — the first step where the two chunks' work joins into
one working path.

```text
Context already built: a guest-side vsock↔TCP shim relaying a guest loopback
port to a fixed vsock proxy port (verified against a throwaway echo
listener), and a host-side mitmproxy TLS-MITM engine listening on a fixed
TCP port with open pass-through policy (verified against a bare TCP
client).

Specification facts for this task: Firecracker's vsock device mediates
between host-side Unix-domain sockets and guest-side `AF_VSOCK` — not real
kernel `AF_VSOCK` on the host side (see
[[03-vmm-firecracker-plan#Step 4 — vsock control-channel transport]]'s
dedicated per-VM socket path). Something on the host must accept the
guest-initiated connection on that dedicated socket and bridge it to
mitmproxy's real TCP listen port. This bridge is a pure byte relay carrying
the guest's live HTTP(S) traffic — it must not buffer, cap, or transform
anything; per [[15-decisions-log]] and [[11-session-transcript-receivers]],
this relay is deliberately uncapped, unlike this subsystem's transcript
receivers, since capping it would sever legitimate in-progress transfers
rather than provide any safety benefit.

Task: build a host-side relay program that, given a dedicated per-VM
host-side vsock socket path (the same one established by
[[03-vmm-firecracker-plan#Step 4 — vsock control-channel transport]]) and
the fixed proxy vsock port, accepts the guest-initiated connection on that
port and relays bytes bidirectionally, unbounded, to a TCP connection
against the mitmproxy engine's listen port from the previous step. For this
task use a single fixed mitmproxy port and a single guest instance —
per-session multiplexing across concurrently-running guests is a later,
separate step and out of scope here. This program is standalone and
directly runnable; wiring it into a per-session systemd unit is
[[10-session-lifecycle-orchestration]]'s job, not built here.

Verify: launch a guest through the existing VMM launcher with the real shim
from Chunk 1 (no longer pointed at a throwaway echo listener), start this
relay pointed at that guest's dedicated vsock socket and the mitmproxy
engine's port, start the mitmproxy engine from the previous step, and from
inside the guest issue a real HTTPS request through the loopback shim to a
real external destination. Confirm the response arrives back in the guest
correctly and that mitmproxy's own console/log shows it handled and
re-encrypted the request. This is the first point this component produces a
genuinely working end-to-end proxied path: guest client → shim → vsock →
relay → mitmproxy → real destination and back.
```

---

## Step 3.1 — Allowlist default-deny mechanism

Chunk 3, first step. Builds on Step 2.2's reachable, open-pass-through path;
replaces its policy.

```text
Context already built: a host-side mitmproxy TLS-MITM engine, reachable
end-to-end from a guest through the vsock shim and relay, currently
forwarding every request with no restriction (open pass-through).

Specification facts for this task: policy is allowlist-only — everything not
explicitly permitted is blocked and logged. The allowlist mechanism must
support two different kinds of entries: domain-style entries (ordinary
internet HTTPS destinations, matched by hostname) and loopback-style
entries (exact `127.0.0.1:<port>` matches against the host's own loopback
interface, since mitmproxy itself is a host process and some allowlisted
destinations are host-local services, not internet domains). All other
loopback/private-range targets must stay denied by default, so the proxy
can never be turned into an SSRF pivot onto other host-local services — the
guest must never be able to reach an arbitrary host-local port just because
one specific loopback entry is allowed.

Task: replace the previous step's open pass-through with a default-deny
mitmproxy addon: build an allowlist data structure/configuration format
supporting both a domain-style entry (hostname, optionally with port) and a
loopback-style entry (exact `127.0.0.1:<port>` tuple), and an addon that,
for every request, blocks and logs (without forwarding) any request whose
destination does not exactly match an entry of either kind, and allows
through only those that do. Include one placeholder entry of each kind
purely to prove both matching paths work — real entries are wired in the
next step. Any other loopback or private-range destination (not equal to
the allowlisted loopback entry) must be blocked the same as any other
non-matching destination — do not special-case loopback ranges as
inherently more trusted.

Verify: with one placeholder domain entry and one placeholder loopback
entry configured, confirm through the full guest → shim → relay → mitmproxy
path: a request to the allowlisted domain succeeds, a request to the
allowlisted loopback target succeeds, a request to a non-allowlisted domain
is blocked and logged, and a request to a non-allowlisted loopback/
private-range address (distinct from the one allowlisted loopback entry) is
also blocked and logged — proving the SSRF backstop holds even though one
loopback entry is legitimately allowed.
```

## Step 3.2 — Real allowlist entries, git-receive-pack rejection, package-registry gap

Chunk 3, second step. Builds directly on Step 3.1's mechanism.

```text
Context already built: a default-deny mitmproxy allowlist addon supporting
domain-style and loopback-style entries, proven against one placeholder of
each kind plus an SSRF backstop for non-allowlisted loopback/private-range
targets.

Specification facts for this task: the allowlist's two real, currently-known
entries are: (1) the Anthropic API endpoint (for Claude Code), reached as
normal internet HTTPS and TLS-MITM'd, matched as a domain-style entry; (2)
[[06-workspace-and-repo-delivery|the host-local git service]], allowlisted
not by domain but as an exact `127.0.0.1:<GIT_PORT>` loopback entry, since
that is the host's own loopback interface where the git service actually
listens — no fake internal hostname or DNS rewriting is used for it. As
defense in depth on top of the git service's own read-only server
configuration (which is the actual read-only enforcement — see
[[06-workspace-and-repo-delivery]]), this proxy additionally rejects any
request whose path contains `git-receive-pack` directed at that loopback
entry, even though the backend doesn't expose that service anyway.

Package-registry strategy, resolved in [[15-decisions-log]]: this guest
never does live, runtime package-manager installs against any registry, for
any ecosystem — everything a session needs is pre-baked into
[[09-guest-rootfs|the guest rootfs Nix closure]] before the session starts,
and a repo needing something not already baked in gets that dependency
added to the tool allowlist and the image rebuilt, not fetched over the
network at runtime. This task therefore does not add, and is not expected
to ever need, a package-registry allowlist entry of either shape
(domain-style or loopback-mirror-style) — unlike the Anthropic API and git
entries above, there is no third real entry pending here.

Task: configure the allowlist addon from the previous step with exactly its
two real entries — the Anthropic API domain, and the git service's exact
loopback address/port — replacing the two placeholder entries used to prove
the mechanism. Add the additional git-receive-pack path-rejection rule
scoped specifically to the git service's loopback entry.

Verify: through the full guest → shim → relay → mitmproxy path, confirm a
request to the real Anthropic API domain is allowed and TLS-MITM'd, a
request to the git service's loopback address succeeds for an
upload-pack-style request (e.g. a fetch/clone/ls-remote-shaped request), a
request whose path contains `git-receive-pack` against that same loopback
entry is rejected even though nothing else changed, and a request to any
other domain or loopback/private-range address is still blocked exactly as
the previous step proved.
```
## Step 4.1 — Credential injection addon

Chunk 4, single step. Builds on Step 3.2's finalized allowlist entries.

```text
Context already built: a mitmproxy allowlist addon enforcing exactly two
real entries — the Anthropic API domain (TLS-MITM'd, direct internet) and
the git service's loopback entry (with `git-receive-pack` rejected) —
everything else blocked and logged.

Specification facts for this task: the guest is configured (during
[[04-guest-pid1-init-plan#Step 4.1 — Configure the agent's environment|pid1-init's
environment setup]]) with a placeholder API credential value, never the real
one. A mitmproxy addon must replace the `Authorization` header with the
real Anthropic API key, on the way out, only for requests matching the
allowlisted Anthropic API destination — never for any other destination,
including the git service's loopback entry. The real key must never exist
in guest memory or filesystem; it is injected only at this host-side point,
per request. Per the resolved "`proxy.jsonl` content: resolved IP +
credential-injection audit" decision in [[15-decisions-log]], the same
addon must tag the flow (in whatever per-flow metadata mechanism mitmproxy
exposes to addons) with whether it actually performed the swap for that
specific request — an audit signal consumed later by
[[11-session-transcript-receivers|the transcript addon]] (not built in this
task) independent of the always-redacted header value itself. This addon
also has access to the destination IP mitmproxy actually connected to (the
host's own DNS resolution result) via mitmproxy's own connection object;
expose it in a way that same future transcript addon can read, without
building the addon itself.

Task: build a mitmproxy addon that, for every request matching the
allowlisted Anthropic API destination only, replaces its `Authorization`
header value with a real Anthropic API key sourced from host-side
configuration (never hardcoded, never written to any guest-reachable path),
and tags that flow's metadata with a boolean recording whether the
substitution happened for that request. For every other destination
(including the git service's loopback entry), leave the header exactly as
received and tag the same metadata field `false`. Do not build any
file-writing or logging behavior here — this task only produces the
in-memory flow tag and header substitution; writing it out to a persisted
transcript is [[11-session-transcript-receivers]]'s job.

Verify: through the full guest → shim → relay → mitmproxy path, send a
request carrying the guest's placeholder credential to the allowlisted
Anthropic destination and confirm (by inspecting the addon's in-process
state or a temporary debug log used only for this verification) that the
outgoing request's `Authorization` header now carries the real key and the
flow is tagged `true`; send a request carrying the same placeholder
credential to the git service's loopback entry and confirm its header is
left untouched and the flow is tagged `false`.
```

---

## Step 5.1 — Shared concurrency slot allocator

Chunk 5, first step. Builds on nothing from Chunks 1–4 directly, but is the
foundation the rest of Chunk 5 multiplies Chunks 1–4's single-guest path
against.

```text
Context already built: a single mitmproxy engine enforcing an allowlist
(Anthropic domain + git loopback entry) and injecting the real Anthropic
credential, reachable through one guest's shim/relay pair on one fixed
port.

Specification facts for this task: mitmproxy runs as one host-wide
singleton process serving every concurrently-running session, so a single
shared listen port gives its addons no way to tell which session a given
flow belongs to. The fix is a fixed-size pool of concurrency slots, sized to
`max_concurrent_sessions`
([[10-session-lifecycle-orchestration|the host-wide config's concurrency
sizing]], not yet planned) — the same sizing pattern already used for
[[12-production-hardening|the hugepage pool]]. Per the resolved
"`proxy.jsonl` per-session split" decision in [[15-decisions-log]], a
session acquires a free slot at launch and releases it at stop, and that
slot index is the same resource-allocation concept
[[12-production-hardening|jailer's per-session uid/gid allocator]] (not yet
planned) will separately use — one shared slot allocator, not two
independent pools. This task builds only the allocator itself, general
enough for either consumer to use; wiring it into actual session
`launch`/`stop` CLI commands belongs to
[[10-session-lifecycle-orchestration]] (not yet planned).

Task: build a shared slot allocator: given a fixed pool size
(`max_concurrent_sessions`), it hands out a free integer slot index to a
caller requesting one, marks it in-use, and accepts a release call freeing a
previously-acquired slot back to the pool. It must be safe for concurrent
callers (multiple sessions acquiring/releasing around the same time) and
must refuse to hand out a slot when the pool is fully allocated, reporting
that condition distinctly from a normal grant. Persist allocation state so
it survives the allocator being invoked independently per call (no
long-lived daemon assumed, matching this subsystem's no-central-daemon
design) — e.g. an on-disk state file with appropriate locking around
acquire/release.

Verify: exercise the allocator directly (a small test harness, not through
any real session): acquire slots up to the pool size and confirm each is a
distinct, previously-unused index; confirm the next acquire beyond the pool
size is refused; release one slot and confirm it becomes available for a
subsequent acquire; confirm state persists correctly across separate
invocations of the allocator (simulating separate CLI calls).
```

## Step 5.2 — mitmproxy multi-listener wiring & slot-assignment file

Chunk 5, second step. Builds on Step 5.1's allocator.

```text
Context already built: a shared slot allocator handing out and releasing
integer slot indices from a fixed-size pool, with persisted state safe for
concurrent, separately-invoked callers.

Resolved in [[15-decisions-log|the mitmproxy multi-listener decision]]:
mitmproxy's `mode` option is a sequence, and its `proxyserver` addon
creates one independent server instance per parsed mode spec, rejecting
only exact duplicate listen addresses — so binding N independent forward-
proxy listeners (`--mode regular@<port>`, repeated) in one process is
supported.

Also resolved, in [[15-decisions-log|the static-vs-dynamic listener
lifecycle decision]]: this task binds the *entire* pool (all
`max_concurrent_sessions` ports) once, at mitmproxy startup, and never
touches mitmproxy's own listener set again — a VM session's launch/stop
only ever changes the slot-assignment file's mapping, not which ports are
listening. mitmproxy does support adding/removing listeners at runtime
too (via `ctx.options.update(mode=...)`), but that path is deliberately
not used here: verified against mitmproxy's own connection-handling source
that every accepted client connection gets entirely fresh handler/
connection-reuse state regardless of listener lifetime, so pre-binding the
static pool carries no extra cross-session leakage risk and avoids
building a second runtime control path into a long-lived process.

Specification facts for this task: mitmproxy binds one additional TCP
listen port per concurrency slot — a fixed pool of size
`max_concurrent_sessions` — instead of the single fixed port used so far. A
small on-disk slot-assignment file maps each slot's local listen port to
that slot's current occupant (session_id and session_dir), and is kept
current by session `launch`/`stop` (owned by
[[10-session-lifecycle-orchestration]], not yet planned — for this task,
simulate launch/stop with a direct call into the allocator from the
previous step). This lookup table exists because the mapping changes over a
session's lifetime while mitmproxy itself is a long-lived singleton that
never restarts between sessions. mitmproxy's own future transcript addon
([[11-session-transcript-receivers|not built in this task]]) will resolve a
flow's session by reading the local port the connection arrived on and
looking it up against this file — this task must produce a file format and
update mechanism that addon can rely on, without building the addon itself.
Per the standing safeguard in [[15-decisions-log|the static-vs-dynamic
listener lifecycle decision]], that future addon must perform this lookup
fresh for every flow and must never cache or carry a resolved session
across flows on the same port — this task's file format and update
mechanism must make that live-lookup usage pattern the natural one (e.g.
no assumption that a reader may snapshot the file once and reuse it).

Task: extend the mitmproxy engine (allowlist + credential injection intact)
to bind one TCP listen port per slot in the pool, at a fixed base port plus
the slot index. Build the slot-assignment file mechanism: a small on-disk
structure (whichever format matches this repo's conventions for small
structured on-disk state) mapping each slot's assigned listen port to a
session_id/session_dir pair, with a write path invoked when a slot is
acquired (populate the entry) and when it is released (clear the entry) —
call these from the previous step's allocator's acquire/release so the two
stay in lockstep by construction, not by convention.

Verify: acquire two slots via the allocator, confirm the assignment file now
shows two distinct port→session_id mappings, confirm mitmproxy is actually
listening on both corresponding ports (e.g. via a bare TCP connect probe to
each), release one slot and confirm its assignment-file entry clears while
the other slot's mapping and listener remain intact and correctly
associated. As a recycling proof: acquire a slot, release it, then acquire
a different session into that same slot/port and confirm the
slot-assignment file now reflects only the new occupant with no trace of
the previous one — proving the mapping itself never bleeds state across
occupants, matching the connection-level isolation mitmproxy already
provides.
```
## Step 5.3 — Slot-aware guest shim and host relay

Chunk 5, third and final step. Builds on Step 1.1's shim, Step 2.2's relay,
and Steps 5.1–5.2's slot pool and assignment file. Closes the plan.

```text
Context already built: a mitmproxy engine listening on one TCP port per
concurrency slot (base port + slot index), with a slot-assignment file
mapping each listen port to a session_id/session_dir, kept current by the
shared allocator's acquire/release calls.

Specification facts for this task: each session's guest-facing bridge — the
guest-side vsock↔TCP shim from Chunk 1 — is told its assigned slot at
process start and must relay to `127.0.0.1:<mitm_base_port + slot>` instead
of the one fixed port used until now. The host-side relay from Chunk 2,
similarly, must become session-scoped: each running session gets its own
relay instance, bridging that one session's dedicated vsock socket to that
session's specific slot port on mitmproxy — not a single shared relay for
every guest.

Task: extend the guest-side shim from Chunk 1 to accept its assigned slot
index as a startup parameter and compute its target port as the base port
plus that slot, rather than using a single fixed port. Extend the host-side
relay from Chunk 2 to also accept a slot index as a startup parameter and
bridge to that slot's specific mitmproxy listen port, rather than the one
fixed port used until now. Both changes are parameterizations of existing
code, not new relay logic.

Verify: using the allocator and assignment file from the previous step,
acquire two slots (simulating two concurrent sessions), launch two guests
each with its shim started with a different assigned slot, launch a
matching host-side relay per guest pointed at its own slot, and confirm
through both guests simultaneously: each guest's HTTPS request through its
own shim reaches mitmproxy on its own slot's port, is allowed/blocked and
credential-injected exactly as the allowlist and credential-injection
addons from Chunks 3–4 already prove for a single guest, and that traffic
from one guest's slot never appears as traffic on the other guest's slot.
This closes the plan: the full per-session-isolated proxy path — guest →
slot-aware shim → session-scoped relay → mitmproxy's slot-specific
listener → allowlist → credential injection → real destination — is now
provable end to end for multiple concurrent sessions, with
[[11-session-transcript-receivers]]'s own future addon left as the only
remaining consumer of the slot-assignment file this component already
produces correctly.
```

## Related

- [[05-network-egress-control]] — the spec this plan implements.
- [[15-decisions-log]] — resolved "vsock↔TCP shim implementation" (Step
  1.1), "`proxy.jsonl` per-session split" (Steps 5.1–5.2), "`proxy.jsonl`
  content: resolved IP + credential-injection audit" (Step 4.1),
  "package-registry strategy per ecosystem" (Step 3.2 — no runtime
  installs, ever), "mitmproxy multi-listener support" (Step 5.2), and
  "static vs. dynamic per-slot listener lifecycle" (Step 5.2) — all six
  folded into their respective steps, none open.
- [[03-vmm-firecracker-plan]] — Step 4's per-VM dedicated vsock transport is
  the device-model dependency Steps 1.1 and 2.2 rely on.
- [[04-guest-pid1-init-plan]] — Step 2.2's placeholder proxy-shim child
  process is what Step 1.1's real binary eventually replaces; Step 4.1's
  environment setup is where the guest's placeholder credential this
  component's Step 4.1 swaps out is configured.
- [[09-guest-rootfs]] — consumes Step 1.2's DNS-absent `resolv.conf`
  artifact and Step 2.1's generated CA certificate at image build time;
  neither is baked into an image by this plan.
- [[06-workspace-and-repo-delivery]] — owns the git service Step 3.2
  allowlists as a loopback entry and whose read-only config is the real
  enforcement behind this plan's defense-in-depth `git-receive-pack`
  rejection.
- [[10-session-lifecycle-orchestration]] — owns the systemd unit graph,
  singleton-service wiring, and `launch`/`stop` CLI that would call this
  plan's Step 5.1 allocator and Step 5.2 assignment-file writes for real;
  simulated with direct calls in this plan instead.
- [[11-session-transcript-receivers]] — consumes Step 4.1's
  credential-injection flow tag and resolved-IP exposure, and Step 5.2's
  slot-assignment file, to write `proxy.jsonl`; not built by this plan.
- [[12-production-hardening]] — Step 5.1's shared slot allocator is the same
  allocation concept its jailer per-session uid/gid allocator will separately
  consume.
- [[07-bpf-monitoring]] — independently captures DNS attempts as a canary
  signal on top of Step 1.2's DNS-absent configuration.
