{
  lib,
  stdenv,
  runCommand,
  writeText,
  systemd,
  systemdUkify,

  kernel,
  initrd,
  kernelParams,

  # File name, os-release ID and PRETTY_NAME.
  name,
  id,
  prettyName,
}:
runCommand name
  {
    nativeBuildInputs = [ systemdUkify ];
  }
  ''
    ukify build \
      --linux=${kernel}/bzImage \
      --initrd=${initrd}/initrd \
      --cmdline=${lib.escapeShellArg (toString kernelParams)} \
      --uname=${kernel.modDirVersion} \
      --os-release=@${writeText "os-release" ''
        ID=${id}
        PRETTY_NAME="${prettyName}"
      ''} \
      --stub=${systemd}/lib/systemd/boot/efi/linux${stdenv.hostPlatform.efiArch}.efi.stub \
      --output=$out
  ''
