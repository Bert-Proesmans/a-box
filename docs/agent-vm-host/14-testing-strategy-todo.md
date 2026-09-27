---
component: testing-strategy-todo
source: 14-testing-strategy-plan.md
tags:
- agent-vm-host
- spec-todo
---
# Testing Strategy — Todo

A step's top-level box is a summary checkbox: check it only once every nested box under it is checked.

## Chunk 1 — Shared pytest test-marker layer

- [ ] Step 1.1 — [[14-testing-strategy-plan#Step 1.1 — Marker registration and environment-detection skip fixtures|Marker registration and environment-detection skip fixtures]]
  - [ ] Build a shared `conftest.py` registering `needs_kvm`, `needs_root`, `needs_bpf` as known pytest markers (no "unknown marker" warning)
  - [ ] Implement a live environment-detection check for each: `needs_kvm` = `/dev/kvm` exists and is readable/writable; `needs_root` = effective UID is 0; `needs_bpf` = treated equivalent to the `needs_root` check (no separate granular capability probe)
  - [ ] Implement a `pytest_collection_modifyitems` hook: for every collected item carrying one or more of the three markers, add a skip marker with a distinct, human-readable reason when the corresponding check fails; leave the item alone when the check passes
  - [ ] Confirm an unmarked item is never touched by this hook under any environment condition
  - [ ] Write a throwaway test module alongside `conftest.py`: exactly four test functions (`needs_kvm`, `needs_root`, `needs_bpf`, unmarked), each trivially passing
  - [ ] Verify: run the module with all three checks monkeypatched to "unavailable", confirm the three marked tests are each reported skipped with a distinct correct reason, and the unmarked test runs and passes
  - [ ] Verify: run again with all three checks monkeypatched to "available", confirm all four tests run and pass with no skip applied

- [ ] Step 1.2 — [[14-testing-strategy-plan#Step 1.2 — CI-safe vs full-hardware invocation profiles|CI-safe vs full-hardware invocation profiles]]
  - [ ] Define a "ci"/portable profile: `pytest -m "not needs_kvm and not needs_root and not needs_bpf"` (exclusion via `-m`, distinct from Step 1.1's skip-with-reason path)
  - [ ] Define a "full" profile: no `-m` filter, for the actual target host
  - [ ] Record both invocations in the repo's existing convention for documented commands (pytest.ini/pyproject.toml markers section plus two named entries, or a wrapper script/Makefile target)
  - [ ] State explicitly next to the two profiles that an unmarked test must always pass under the "ci" profile
  - [ ] Verify: run the "ci" profile against Step 1.1's four-test module in an unprivileged/non-KVM environment, confirm exactly the unmarked test executes and the three marked tests are excluded entirely (not individually skipped-with-reason) — confirm the profile's summary output reflects exclusion
  - [ ] Verify: run the "full" profile against the same module in the same under-provisioned environment, confirm it reproduces Step 1.1's skip-with-reason outcome for the three marked tests, with the unmarked test still passing
