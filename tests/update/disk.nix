# The disk a manual install produces: the real installer ISO, booted through OVMF in a QEMU VM,
# runs `a-box-install /dev/vda` on a blank disk. The result is the GPT with ESP, zram and data
# partitions, btrfs with its subvolumes, and the test updater on the ESP. Needs KVM.
{
  runCommand,
  qemu_kvm,
  OVMF,
  python3,

  updater,
}:
runCommand "a-box-test-disk"
  {
    nativeBuildInputs = [
      qemu_kvm
      (python3.withPackages (ps: [ ps.pexpect ]))
    ];
    requiredSystemFeatures = [ "kvm" ];

    iso = updater.installerIso;
    ovmfCode = "${OVMF.fd}/FV/OVMF_CODE.fd";
    ovmfVars = "${OVMF.fd}/FV/OVMF_VARS.fd";
    # Sparse: room for two generations in the data partition, but only written blocks count.
    diskSize = "16G";
  }
  ''
    python3 ${./install-disk.py} $out
  ''
