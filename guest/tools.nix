{
  runCommand,
  removeReferencesTo,
  busybox,
  socat,
  applets,
}:
# The guest's only executables: one busybox binary with a symlink per applet, and socat. Both are
# copied out of their packages, so the closure of this path is this path.
runCommand "a-box-guest-tools" { nativeBuildInputs = [ removeReferencesTo ]; } ''
  mkdir -p $out/bin
  install -m755 ${busybox}/bin/busybox $out/bin/busybox
  # Only udhcpc's default.script path; without this the whole busybox package, with every applet
  # symlink, would be in the closure.
  remove-references-to -t ${busybox} $out/bin/busybox
  install -m755 ${socat}/bin/socat $out/bin/socat

  # The forwarder to the host proxy needs AF_VSOCK addresses.
  $out/bin/socat -V | grep -q 'WITH_VSOCK 1'

  for applet in ${toString applets}; do
    $out/bin/busybox --list | grep -qx "$applet"
    ln -s busybox $out/bin/$applet
  done
''
