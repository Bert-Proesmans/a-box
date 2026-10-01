---
component: in-guest-hardening-plan
source: 08-in-guest-hardening.md
tags:
- agent-vm-host
- spec-plan
---

# In-Guest Hardening — Implementation Plan

## Blueprint

[[08-in-guest-hardening]] specifies almost no in-guest process isolation
beyond the microVM boundary itself: the single applied measure is capability
dropping — setuid to an unprivileged user and strip all Linux capabilities
before exec-ing the agent — and that mechanism is already built, as step 6
of [[04-guest-pid1-init|pid1-init's]] startup sequence, in
[[04-guest-pid1-init-plan#Step 4.2 — Drop privileges|Step 4.2]] of that
plan. There is nothing left for this plan to construct on that front. What
this plan does build is independent proof: that Step 4.2's mechanism
genuinely leaves the exec'd agent process with zero privilege at runtime
(not merely a self-reported syscall return code), and that each of the
three measures the spec explicitly declines — seccomp filtering, read-only
rootfs enforcement, nsjail-style namespace isolation — is truly absent from
the guest's runtime, not just undocumented. Both checks are wired into
[[04-guest-pid1-init-plan#Step 4.3 — exec into the agent|Step 4.3's]]
placeholder agent process, the one point in the sequence that runs *after*
privileges are dropped and *after* pid1's own image is gone.

This plan does not build: the setuid+capability-strip mechanism itself
(already built, see the cross-link above), any seccomp filter, any
read-only rootfs enforcement, or any namespace-isolation layer — see
[[08-in-guest-hardening#Rationale|the spec's own rationale]] for why (the
microVM boundary is the real isolation boundary for a guest kernel running
a single, non-multi-tenant workload; capability dropping is cheap
defense-in-depth on top of it; a seccomp allowlist tolerant of arbitrary
shell commands against [[09-guest-rootfs|the guest rootfs's whitelisted
tool closure]] wasn't judged worth its maintenance cost). Nothing here is
re-argued, only cross-linked.

**Open gap check:** [[15-decisions-log]]'s "Still open" section has no item
tagged against [[08-in-guest-hardening]]. One resolved decision applies —
"eBPF load privilege" (BPF loaded while pid1-init is still root, strictly
before the capability drop) — but it is an ordering constraint on
[[04-guest-pid1-init-plan]]'s own Steps 3.1/4.2 and
[[07-bpf-monitoring-plan#Step 3.3 — Replace the pid1-init placeholder loader|Step 3.3]],
not a build item for this plan; it is not re-derived here. One detail the
spec itself leaves silent, flagged rather than guessed: "strip all Linux
capabilities" doesn't say whether the capability *bounding* (and ambient)
sets must also be cleared, or only the effective/permitted/inheritable sets
that [[04-guest-pid1-init-plan#Step 4.2 — Drop privileges|Step 4.2]]
already clears. Step 1.1 below is written to surface that discrepancy
empirically if it exists, rather than assume it away; any resulting fix
belongs to Step 4.2 of the pid1-init plan, which this plan does not modify.

## Chunks

1. **Chunk 1 — Independent hardening verification.** Proves, from outside
   pid1-init's own self-reported markers, that the already-built capability
   drop leaves the exec'd agent process with zero privilege, and that the
   three explicitly-declined measures are genuinely absent at runtime.
   (Steps 1.1–1.2)

---

## Chunk 1 — Independent Hardening Verification

### Step 1.1 — Independent proof the capability drop leaves zero privilege

This step doesn't rebuild
[[04-guest-pid1-init-plan#Step 4.2 — Drop privileges|Step 4.2's]]
setuid+capability-strip mechanism; it extends the placeholder agent process
that [[04-guest-pid1-init-plan#Step 4.3 — exec into the agent|Step 4.3]]
already execs into, adding a check performed by an interface pid1 itself
never controls.

```text
Context already built: a pid1 binary (built in 04-guest-pid1-init-plan)
that, after loading eBPF while root, switches its user/group identity to a
dedicated unprivileged account and strips its effective, permitted, and
inheritable capability sets, then execs into a placeholder agent binary
with its environment, credential placeholder, and working directory
prepared, and its standard input/output wired to the guest's stdio vsock
connection. That placeholder agent currently echoes its input back and
prints its received environment/working directory once, as pid1-init-plan's
own boot-sequence proof.

Specification facts to ground this task in: this design's only in-guest
hardening measure is capability dropping — no seccomp, no nsjail-style
namespaces, no read-only rootfs enforcement. The boot-console marker
pid1-init already writes at its privilege-drop step only reports what the
dropping syscalls themselves returned, from inside the same process that
issued them. This task adds a genuinely independent check, performed by the
exec'd process itself only after it has fully replaced pid1's own process
image, using an interface pid1 doesn't control: the kernel's own
/proc/self/status accounting of that process's actual capability sets,
plus a live attempt at an operation that should now be structurally
impossible regardless of what any capability-set field claims.

Task: extend the placeholder agent binary built in 04-guest-pid1-init-plan's
Step 4.3 (still a throwaway placeholder — the real Claude Code agent binary
is out of scope everywhere in this plan) to perform, as its very first
action before its existing echo/environment-dump behavior: read its own
/proc/self/status and extract the CapInh, CapPrm, CapEff, and CapBnd
fields; separately, attempt one operation that requires root or a specific
capability regardless of these fields' values (for example, attempting to
set its own real/effective UID back to 0, or attempting to create a raw
socket) and record whether it succeeded or failed with EPERM. Print one
further distinct marker to stdout, over the stdio vsock connection, ahead
of its existing markers, reporting all four capability-set values verbatim
and the outcome of the privileged-operation attempt.

Verify by launching the guest through the existing VMM launcher exactly as
04-guest-pid1-init-plan's own end-to-end verification does, then, from the
host, reading the connected stdio vsock stream and confirming: CapInh,
CapPrm, and CapEff all report fully empty, and the attempted privileged
operation reports failure with EPERM. Report the CapBnd value verbatim
rather than treating any particular value as pass/fail — whether the
bounding set must also be empty is an open, unresolved detail this task
does not decide (see this plan's Blueprint). This is the plan's first
proof that the stated hardening measure genuinely holds at runtime, not
merely in the dropping syscalls' own return codes.
```

### Step 1.2 — Independent proof the three declined measures are truly absent

Builds directly on Step 1.1's verification harness, in the same placeholder
agent process, adding the negative-space checks for the three measures the
spec explicitly declines. Closes the plan.

```text
Context already built: the placeholder agent binary from
04-guest-pid1-init-plan's Step 4.3, now extended (previous step) to report
its own capability-set fields and a privileged-operation-attempt outcome
as its first action after being exec'd, before its pre-existing
echo/environment-dump behavior.

Specification facts to ground this task in: 08-in-guest-hardening states
three measures are explicitly not applied, by design: no seccomp
filtering, no read-only rootfs enforcement, no nsjail-style namespace
isolation. This is a deliberate scope boundary, not an oversight — the
microVM boundary already isolates this single-tenant guest kernel,
capability dropping is cheap defense-in-depth on top of it, and a seccomp
allowlist tolerant of the guest rootfs's arbitrary whitelisted CLI tools
wasn't judged worth its maintenance cost. This task's job is to prove each
of the three absences is real at runtime, in the same exec'd process the
previous step already instrumented — not to add any of the three measures,
and not to alter anything pid1-init or the workspace-assembly steps
already built.

Task: extend the same placeholder agent binary to add three further
checks, run immediately after the previous step's capability report and
before the pre-existing echo behavior, each printing its own distinct
marker to stdout over the stdio vsock connection:

- Seccomp absence: read the Seccomp field from /proc/self/status and
  report its value verbatim (0 means no filter is active anywhere in the
  boot path that reached this process; anything else means this design's
  stated absence doesn't hold).
- No read-only rootfs enforcement: attempt to write a small marker file
  into the merged overlay workspace mount point (assembled in
  04-guest-pid1-init-plan's Step 1.2) and report whether the write
  succeeded — a successful write proves the workspace is genuinely
  writable, not read-only-enforced on top of the capability drop.
- No added namespace isolation: read this process's own mount, PID, and
  user namespace identifiers (the target inode numbers behind the
  /proc/self/ns/* symlinks) and report them verbatim. As a temporary
  diagnostic addition to pid1-init for this verification only (not a
  permanent change to its sequence), have pid1 print the same three
  namespace identifiers, taken from itself, to the boot console right
  before it execs.

Verify by launching the guest through the existing VMM launcher exactly as
before, then from the host reading the stdio vsock stream and confirming:
Seccomp reports 0, the workspace write-marker reports success, and the
three namespace identifiers are printed. Separately, read pid1's own
namespace identifiers from the boot console and confirm all three match
the exec'd process's values exactly — proving no nsjail-style namespace
layer was inserted between pid1 and the agent it exec'd into. This closes
the plan: every measure 08-in-guest-hardening claims — capability dropping
applied; seccomp, read-only-rootfs enforcement, and namespace isolation all
absent — is now independently provable at runtime, not merely asserted.
```

## Related

- [[08-in-guest-hardening]] — the spec note this plan derives from.
- [[04-guest-pid1-init]] — owns the startup sequence whose step 6 is this
  spec's capability-drop mechanism.
- [[04-guest-pid1-init-plan]] — Step 4.2 (drop privileges) already builds
  the capability-drop mechanism this plan verifies rather than rebuilds;
  Step 4.3 (exec into the agent) is the placeholder process both steps
  here extend; Step 1.2 (overlay workspace assembly) is what Step 1.2's
  write-marker check targets.
- [[07-bpf-monitoring]] and [[07-bpf-monitoring-plan]] — Step 3.3 wires the
  real eBPF loader against the same root-before-drop ordering this plan's
  capability-drop verification runs downstream of; not re-derived here.
- [[03-vmm-firecracker]] — the microVM boundary this design deliberately
  relies on instead of duplicating process-level isolation.
- [[09-guest-rootfs]] — the whitelisted-tool closure that shapes why a
  seccomp allowlist was judged not worth its cost.
- [[15-decisions-log]] — "eBPF load privilege" resolved decision (ordering
  constraint on 04/07's plans, not a build item here); no "Still open"
  item is tagged against this spec. The capability-bounding-set gap this
  plan flags in its Blueprint is this plan's own finding, not a
  decisions-log entry.
