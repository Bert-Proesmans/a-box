{ pkgs, device1-v0 }:

# Chunk B2/B3/C1 check: the image contains exactly `/init`, `/bin/echo_agent`
# (chunk C1's stub agent), and the four empty pseudo-fs mount-point
# directories B3's pid1-init needs (see the comment in device1-v0.nix - they
# can't be created at runtime on a read-only root), nothing else.
pkgs.runCommand "agent-vm-device1-v0-check"
  {
    nativeBuildInputs = [ pkgs.squashfsTools ];
  }
  ''
    unsquashfs -l ${device1-v0} | sort > listing
    cat listing

    printf '%s\n' \
      squashfs-root \
      squashfs-root/bin \
      squashfs-root/bin/echo_agent \
      squashfs-root/dev \
      squashfs-root/init \
      squashfs-root/proc \
      squashfs-root/sys \
      squashfs-root/tmp \
      | sort > expected

    actual=$(cat listing)
    expected=$(cat expected)
    if [ "$actual" != "$expected" ]; then
      echo "unexpected squashfs contents:"
      cat listing
      exit 1
    fi

    touch $out
  ''
