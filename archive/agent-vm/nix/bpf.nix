{ pkgs }:

# Chunk A4 scaffolding: builds the no-op CO-RE BPF object + libbpf loader
# under agent-vm/bpf/. Proves the clang/libbpf/bpftool skeleton pipeline
# works. Real tracepoint programs and a load-time check (which needs
# CAP_BPF/root) are added in chunk G.
pkgs.stdenv.mkDerivation {
  pname = "agent-vm-bpf-scaffold";
  version = "0.0.1";

  src = ../bpf;

  nativeBuildInputs = [
    pkgs.llvmPackages.clang-unwrapped
    pkgs.bpftools
    pkgs.pkg-config
  ];

  buildInputs = [
    pkgs.libbpf
    pkgs.elfutils
    pkgs.zlib
  ];

  makeFlags = [
    "KERNEL_HEADERS_CFLAGS=-I${pkgs.linuxHeaders}/include"
  ];

  installPhase = ''
    mkdir -p $out/bin
    cp build/loader $out/bin/agent-vm-bpf-loader
  '';

  meta.description = "agent-vm chunk A4: libbpf CO-RE no-op scaffold + loader";
}
