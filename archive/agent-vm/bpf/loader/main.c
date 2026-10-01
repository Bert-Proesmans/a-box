// SPDX-License-Identifier: GPL-2.0
#include <stdio.h>

#include "noop.skel.h"

// Scaffolding only: opens/loads the no-op skeleton and exits. Real
// attach/poll logic is added in chunk G once real programs exist.
int main(void) {
    struct noop_bpf *skel = noop_bpf__open_and_load();
    if (!skel) {
        fprintf(stderr, "failed to open/load noop BPF skeleton\n");
        return 1;
    }

    noop_bpf__destroy(skel);
    return 0;
}
