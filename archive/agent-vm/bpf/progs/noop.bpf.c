// SPDX-License-Identifier: GPL-2.0
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

char LICENSE[] SEC("license") = "GPL";

// Scaffolding only: proves the CO-RE compile + skeleton-generation pipeline
// works end to end. No programs are attached here — real tracepoint
// programs are added in chunk G.
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u64);
} noop_map SEC(".maps");
