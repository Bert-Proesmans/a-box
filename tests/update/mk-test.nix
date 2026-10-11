# One update scenario: nodes cache and machine, the shared python prelude, then `testScript`.
# `cache` is a NixOS module with the scenario's network blocks.
{
  testers,
  testDefaults,
  vm,
  cacheBase,
  generations,
  binaryCache,
  testDisk,
}:
{
  name,
  cache,
  testScript,
}:
testers.runNixOSTest {
  name = "a-box-update-${name}";

  # An updater stuck in its emergency shell would otherwise hold the build for an hour.
  globalTimeout = 1500;

  defaults = testDefaults;

  nodes.cache.imports = [
    cacheBase
    cache
  ];

  # Only the VM: the updater boots the generations from the test disk.
  nodes.machine = vm;

  testScript =
    { nodes, ... }:
    ''
      import os
      import subprocess
      import tempfile

      gens = {1: "${generations."1"}", 2: "${generations."2"}"}

      # The cache already holds both generations; publishing moves the pointer.
      def publish(n):
          cache.succeed(f"cp ${binaryCache}/pointer-{n} /srv/www/a-box/machine")

      # Writable overlay on the disk, so every step starts from the previous one's state.
      # QEMU reads NIX_DISK_IMAGE at start; set it only once cache is running.
      overlay = tempfile.NamedTemporaryFile()

      def start():
          subprocess.run([
              "${nodes.machine.virtualisation.qemu.package}/bin/qemu-img", "create",
              "-f", "qcow2", "-b", "${testDisk}/a-box-test.raw", "-F", "raw", overlay.name,
          ], check=True)
          os.environ["NIX_DISK_IMAGE"] = overlay.name
          machine.start(allow_reboot=True)

      boot_order = None

      def expect(n):
          global boot_order
          machine.wait_for_unit("multi-user.target")
          t.assertEqual(machine.succeed("cat /etc/a-box-generation").strip(), str(n))
          t.assertEqual(machine.succeed("readlink -f /run/current-system").strip(), gens[n])
          # Started by systemd-boot from the ESP the updater filled, not by the updater or firmware.
          t.assertIn(f"init={gens[n]}/init", machine.succeed("cat /proc/cmdline"))
          machine.succeed("ls /sys/firmware/efi/efivars | grep -q '^LoaderEntrySelected-'")

          # The updater boots through BootNext; the firmware boot order stays as found.
          order = machine.succeed("cat /sys/firmware/efi/efivars/BootOrder-* 2>/dev/null | od -An -tx1").strip()
          if boot_order is None:
              boot_order = order
          t.assertEqual(order, boot_order)

      cache.wait_for_unit("nginx.service")
      cache.wait_for_unit("multi-user.target")
    ''
    + testScript;
}
