{ pkgs, kernel }:

# Chunk B1 check: no VM boot yet (that's B4) - just prove the build produced
# a real, non-empty x86 Linux boot image.
pkgs.runCommand "agent-vm-guest-kernel-check"
  {
    nativeBuildInputs = [ pkgs.file ];
  }
  ''
    test -s ${kernel}/vmlinux
    file ${kernel}/vmlinux | tee $out
    grep -q 'ELF 64-bit.*executable, x86-64' $out
  ''
