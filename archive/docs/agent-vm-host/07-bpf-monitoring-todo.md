---
component: bpf-monitoring-todo
source: 07-bpf-monitoring-plan.md
tags:
- agent-vm-host
- spec-todo
---
# BPF Monitoring — Build Checklist

A step's top-level box is a summary — check it only when every nested box under it is checked.

## Chunk 1 — Guest eBPF Toolchain & Process/Network Capture

- [ ] **Step 1 — Build toolchain, skeleton, and process-exec capture** [[07-bpf-monitoring-plan#Step 1.1 — Build toolchain, skeleton, and process-exec capture]]
  - [ ] Set up a new build for a compiled eBPF program plus a small, statically-linkable libbpf-based userspace loader, in this repo's C/libbpf toolchain convention
  - [ ] eBPF program attaches to the kernel's process-execution tracepoint (or equivalent stable attach point), captures each exec event: at minimum the executed path/command and its arguments
  - [ ] Loader loads/attaches the program, reads captured events as they occur, prints one NDJSON object per event to its own stdout
  - [ ] Each object carries at least: a timestamp, an event-type discriminator (process-exec), the captured command/argument payload
  - [ ] Loader runs until manually interrupted; does not exit on its own after one event
  - Code structured so each later capture category can be added as its own attach point feeding the same pipeline/output, without restructuring this step's work
  - [ ] Verify: build program+loader, run loader with sufficient privilege on a suitable Linux host, execute a handful of ordinary shell commands in another terminal while it runs; confirm one well-formed JSON line per command executed containing its path/arguments, and no line emitted for non-exec activity
- [ ] **Step 2 — Network syscall capture (connect/sendto)** [[07-bpf-monitoring-plan#Step 1.2 — Network syscall capture (connect/sendto)]]
  - [ ] Extend the program+loader to attach to the kernel's `connect` and `sendto` syscall entry points, capture each occurrence: at minimum the calling process, syscall name, and destination info (address/port, or as much as available)
  - [ ] Emit each as its own NDJSON line on the loader's existing stdout stream, same common envelope (timestamp, event-type discriminator, payload), event-type distinguishing network from exec
  - [ ] Verify: run loader with sufficient privilege; in another terminal run ordinary commands (confirm exec events still fire) and make a couple of outbound network connections (e.g. to a local test listener); confirm one NDJSON line per `connect`/`sendto` call observed, correctly tagged as network and distinct from exec events

## Chunk 2 — File & DNS Capture, Unified Export Schema

- [ ] **Step 1 — File-open capture, distinguishing read vs. write** [[07-bpf-monitoring-plan#Step 2.1 — File-open capture, distinguishing read vs. write]]
  - [ ] Extend the program+loader to attach to the kernel's file-open path (open/openat family), capture each file-open event: at minimum the path opened and whether opened for reading, writing, or both
  - [ ] Emit each as its own NDJSON line on the existing stdout stream, same common envelope, event-type distinguishing file-open from exec/network, payload making the read-vs-write distinction explicit and unambiguous
  - [ ] Verify: run loader with sufficient privilege; in another terminal perform file opens in distinct modes (reading an existing file, creating/writing a new file, opening a file for both); confirm one NDJSON line per open with correct path and correct read/write mode, alongside exec and network events still firing correctly
- [ ] **Step 2 — DNS-attempt capture and the common export schema** [[07-bpf-monitoring-plan#Step 2.2 — DNS-attempt capture and the common export schema]]
  - [ ] Extend the program+loader to attach to the guest's DNS-resolution attempt path, capture each attempt: at minimum the hostname being looked up (if available) and which process triggered it
  - [ ] Emit each as its own NDJSON line using the same common envelope, own distinct event-type value
  - Does not add a session identifier field to the common envelope (session identification is entirely downstream/host-side)
  - [ ] Review/tighten the shared envelope (timestamp, event-type discriminator, payload) so all four event types now use it consistently — same field names and timestamp format across all four
  - [ ] Verify: trigger a hostname lookup (a tool performing its own resolution, not via a configured proxy), confirm one correctly-tagged DNS-attempt NDJSON line appears
  - [ ] Verify: re-run a smoke check across all four categories together (exec, network connect, file open, DNS lookup), confirm each produces exactly one correctly-tagged, schema-consistent NDJSON line, no category producing zero or duplicate lines

## Chunk 3 — Continuous vsock Export & pid1-init Integration

- [ ] **Step 1 — Continuous export over a handed-off connection** [[07-bpf-monitoring-plan#Step 3.1 — Continuous export over a handed-off connection]]
  - [ ] Change the loader so it writes NDJSON lines to a specific inherited, already-open file descriptor passed at startup (fixed documented FD number or equivalent well-known hand-off convention), falling back to its own stdout only when no such descriptor is supplied
  - [ ] Confirm the loader never exits once it starts capturing (short of an unrecoverable error)
  - [ ] Verify (a): re-run the previous steps' standalone checks (exec/network/file/DNS events on stdout) — nothing regressed when no hand-off descriptor is given
  - [ ] Verify (b): standalone test harness opens a connected pair of file descriptors (Unix domain socket pair or pipe), starts the loader with one end handed off as the export descriptor, triggers a few events of each of the four kinds, confirms well-formed NDJSON lines arrive on the other end of the pair
- [ ] **Step 2 — Extend the guest kernel with BPF/CO-RE support** [[07-bpf-monitoring-plan#Step 3.2 — Extend the guest kernel with BPF/CO-RE support]]
  - [ ] Add a second kernel-build derivation, additive to and built from the same base config as the existing minimal one, turning on `CONFIG_BPF`, `CONFIG_BPF_SYSCALL`, `CONFIG_DEBUG_INFO_BTF`, `CONFIG_KPROBES`, `CONFIG_KPROBE_EVENTS`, `CONFIG_BPF_EVENTS`, `CONFIG_PERF_EVENTS` on top of everything the baseline already enables
  - [ ] Does not remove or change any of the baseline's existing options; distinct build output name/attribute so callers can select which kernel to launch
  - [ ] Baseline derivation itself remains unchanged and independently buildable exactly as before
  - [ ] Verify (a): build both kernel variants, confirm the baseline is unaffected (still builds, still an uncompressed ELF `vmlinux`, still lacking the new options)
  - [ ] Verify (b): build and boot the new variant (trivial placeholder init is fine), confirm the guest exposes `/sys/kernel/btf/vmlinux` and can successfully load one trivial no-op BPF program of each needed type — one kprobe-attached, one tracepoint-attached
- [ ] **Step 3 — Replace the pid1-init placeholder loader** [[07-bpf-monitoring-plan#Step 3.3 — Replace the pid1-init placeholder loader]]
  - [ ] Wire the compiled program+loader into the real boot path in place of the placeholder loader pid1-init invokes, using the exact existing hand-off contract (direct child-process invocation, no shell; open BPF-export vsock connection passed as the inherited export descriptor)
  - [ ] Does not modify pid1-init's own sequencing, privilege-drop timing, or any other step — only swaps which binary is invoked
  - [ ] Verify: launch a full guest boot through the existing VMM launcher, configured to boot Step 2's BPF-capable kernel variant (not the default baseline), with the real program/loader in place; from the host connect to the instance's dedicated vsock socket on the BPF-export port; confirm well-formed NDJSON lines arrive continuously as guest activity happens, correctly tagged across at least a few of the four event categories (trigger exec activity and a file open or two)
  - [ ] Verify: loader still invoked strictly before pid1-init's capability-drop step completes (its startup marker/behavior still precedes that step's boot-console marker)

## Chunk 4 — Host-Side `bpf.jsonl` Receiver

- [ ] **Step 1 — Standalone, growth-bounded receiver** [[07-bpf-monitoring-plan#Step 4.1 — Standalone, growth-bounded receiver]]
  - [ ] Implement as a small script (per the settled host-orchestration-language decision): accepts exactly one guest-initiated connection on a socket path dedicated to one specific session
  - [ ] Simple loop: read up to a bounded chunk size, append exactly what was read to a per-session output file, sleep briefly, repeat — this pairing is the only bandwidth limiting (no separate rate-limiter)
  - [ ] Enforce a hard cap of 100 MB written per output file: once reached, stop reading, close the accepted connection, close and remove the listening socket, exit
  - [ ] Does not attempt to stop exactly on a newline/JSON-line boundary (truncated partial line past the cap is expected)
  - [ ] Does not drain-and-discard once capped — guest's writer is deliberately left to block/fail against the now-closed socket
  - [ ] Invocable directly, taking at least: socket path to listen on, output file path to append to
  - Does not build any process-supervision, restart, or systemd-unit wiring — that's a separate later component
  - [ ] Verify (a): run the script against a throwaway Unix domain socket + output file path; from a separate test process, write a modest amount of well-formed NDJSON-shaped data, confirm it lands byte-for-byte in the output file
  - [ ] Verify (b): write enough data to cross the 100 MB cap deliberately; confirm the script stops accepting further bytes at the cap, the accepted connection and listening socket both end up closed, the script exits, and the output file's size does not meaningfully exceed the cap
- [ ] **Step 2 — End-to-end proof against real guest output** [[07-bpf-monitoring-plan#Step 4.2 — End-to-end proof against real guest output]]
  - [ ] Launch a full guest boot through the existing VMM launcher, configured to boot the Chunk 3 Step 2 BPF-capable kernel variant, with the real eBPF program/loader in place (Chunk 3), and start the standalone receiver script (Step 1) pointed at that instance's dedicated BPF-export socket path + a fresh per-session output file, before or as the guest boots
  - No new code needed beyond, at most, small glue to launch both pieces together
  - [ ] Verify: while the guest is running, trigger guest activity spanning all four captured categories (shell command, file open in each read/write mode, outbound network connection attempt, hostname lookup); confirm each shows up as a well-formed, correctly-tagged NDJSON line in the receiver's output file, in close-to-real-time (not only after the guest stops)
  - [ ] Verify: run a second pass generating enough guest-side activity to push the output file's size toward the 100 MB cap; confirm the receiver still stops itself, closes its socket, and exits exactly as in Step 1's standalone test — now against a real guest connection

## Related

- [[07-bpf-monitoring]] — the spec this plan implements.
- [[07-bpf-monitoring-plan]] — the plan this checklist tracks.
