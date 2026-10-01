CLANG      ?= clang
BPFTOOL    ?= bpftool
CC         ?= cc
PKG_CONFIG ?= pkg-config

# Kernel UAPI headers (linux/types.h etc). libbpf's own vendored headers are
# not a complete kernel header set, so this must point at a real one -
# passed in by the Nix derivation, or overridden by hand in a devshell.
KERNEL_HEADERS_CFLAGS ?=

BUILD := build

BPF_CFLAGS    := -g -O2 -target bpf -D__TARGET_ARCH_x86 $(KERNEL_HEADERS_CFLAGS) $(shell $(PKG_CONFIG) --cflags libbpf)
LIBBPF_CFLAGS := $(shell $(PKG_CONFIG) --cflags libbpf)
LIBBPF_LIBS   := $(shell $(PKG_CONFIG) --libs libbpf) -lelf -lz

all: $(BUILD)/loader

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/noop.bpf.o: progs/noop.bpf.c | $(BUILD)
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@

$(BUILD)/noop.skel.h: $(BUILD)/noop.bpf.o
	$(BPFTOOL) gen skeleton $< > $@

$(BUILD)/loader: loader/main.c $(BUILD)/noop.skel.h
	$(CC) $(LIBBPF_CFLAGS) -I$(BUILD) loader/main.c -o $@ $(LIBBPF_LIBS)

clean:
	rm -rf $(BUILD)

.PHONY: all clean
