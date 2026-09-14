{ pkgs }:

# Statically-linked (musl) build of the pid1-init guest binary. Uses
# nixpkgs' pkgsStatic package set (musl libc, static linking) rather than
# rustup/fenix, per docs/agent-vm-host-plan.md A3 - this only works because
# build and host CPU architecture match (x86_64), so no actual
# cross-compilation toolchain juggling is needed, just a retargeted libc.
pkgs.pkgsStatic.rustPlatform.buildRustPackage {
  pname = "pid1-init";
  version = "0.0.1";

  src = ../guest;

  cargoLock.lockFile = ../guest/Cargo.lock;

  meta.description = "agent-vm guest pid1-init, statically linked against musl";
}
