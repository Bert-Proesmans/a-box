---
component: in-guest-hardening-todo
source: 08-in-guest-hardening-plan.md
tags:
- agent-vm-host
- spec-todo
---
# In-Guest Hardening — Todo

A step's top-level box is a summary checkbox; check it only when every nested box under it is checked.

## Chunk 1 — Independent Hardening Verification

- [ ] Step 1.1 — Independent proof the capability drop leaves zero privilege — [[08-in-guest-hardening-plan#Step 1.1 — Independent proof the capability drop leaves zero privilege]]
  - [ ] Extend the Step 4.3 placeholder agent binary to read `/proc/self/status` and extract `CapInh`, `CapPrm`, `CapEff`, `CapBnd` as its first action, before the existing echo/env-dump behavior
  - [ ] Attempt one operation requiring root/a specific capability regardless of those fields (e.g. set real/effective UID back to 0, or create a raw socket) and record success or EPERM failure
  - [ ] Print one further distinct marker to stdout over the stdio vsock connection, reporting all four capability-set values verbatim plus the privileged-operation outcome, ahead of the existing markers
  - [ ] Verify: launch the guest via the existing VMM launcher exactly as 04-guest-pid1-init-plan's own end-to-end verification does; from the host, read the connected stdio vsock stream; confirm `CapInh`, `CapPrm`, `CapEff` all report fully empty and the attempted privileged operation fails with EPERM; report `CapBnd` verbatim without treating it as pass/fail
- [ ] Step 1.2 — Independent proof the three declined measures are truly absent — [[08-in-guest-hardening-plan#Step 1.2 — Independent proof the three declined measures are truly absent]]
  - [ ] Extend the same placeholder agent binary with three further checks, run immediately after Step 1.1's capability report and before the pre-existing echo behavior, each printing its own distinct marker over the stdio vsock connection
  - [ ] Seccomp absence: read the `Seccomp` field from `/proc/self/status`, report its value verbatim
  - [ ] No read-only-rootfs enforcement: attempt to write a small marker file into the merged overlay workspace mount point (assembled in 04-guest-pid1-init-plan's Step 1.2), report whether the write succeeded
  - [ ] No added namespace isolation: read this process's own mount, PID, and user namespace identifiers (the target inode numbers behind `/proc/self/ns/*`), report verbatim
  - [ ] As a temporary diagnostic addition to pid1-init for this verification only, have pid1 print the same three namespace identifiers, taken from itself, to the boot console right before it execs
  - [ ] Verify: launch the guest as before; from the host, read the stdio vsock stream and confirm `Seccomp` reports 0, the workspace write-marker reports success, and the three namespace identifiers are printed; separately read pid1's own namespace identifiers from the boot console and confirm all three match the exec'd process's values exactly

## Related

- [[08-in-guest-hardening]] — the spec this plan implements.
- [[08-in-guest-hardening-plan]] — the plan this checklist tracks.
