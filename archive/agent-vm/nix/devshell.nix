{ pkgs }:

let
  python = pkgs.python3.withPackages (
    ps: with ps; [
      click
      pytest
      mypy
      requests
      requests-unixsocket
    ]
  );
  agentvm = import ./host-package.nix { inherit pkgs; };
in
pkgs.mkShell {
  packages = [
    # Packaged CLI itself, so `agentvm --version` works directly in the
    # devshell without an editable install (chunk A2).
    agentvm

    # Rust, targeting x86_64-unknown-linux-musl for the static pid1-init
    # guest binary. Built via nixpkgs' pkgsStatic package set rather than
    # rustup/fenix (see agent-vm/nix/guest-init.nix for why this works
    # without cross-compilation: build and host CPU architecture match).
    pkgs.pkgsStatic.rustPlatform.rust.rustc
    pkgs.pkgsStatic.rustPlatform.rust.cargo

    # C/libbpf toolchain (chunk A4/G).
    pkgs.llvmPackages.clang-unwrapped
    pkgs.bpftools
    pkgs.libbpf
    pkgs.linuxHeaders
    pkgs.pkg-config
    pkgs.elfutils
    pkgs.zlib

    # Host orchestration (chunk A2+).
    python

    # VMM (chunk B+).
    pkgs.firecracker

    # Squashfs image building/inspection for device1-v0 (chunk B2+).
    pkgs.squashfsTools
  ];
}
