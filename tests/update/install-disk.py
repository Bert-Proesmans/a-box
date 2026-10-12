# Runs the installer ISO in QEMU on a blank disk through the serial console, then stores the disk
# as a compressed qcow2 image: the unwritten space costs nothing.
import os
import shutil
import subprocess
import sys

import pexpect

out = sys.argv[1]
disk = "disk.raw"

subprocess.run(["qemu-img", "create", "-f", "raw", disk, os.environ["diskSize"]], check=True)

# Firmware variables are writable; the installer adds its boot entry to them. They are not kept.
shutil.copy(os.environ["ovmfVars"], "vars.fd")
os.chmod("vars.fd", 0o644)

vm = pexpect.spawn(
    "qemu-system-x86_64",
    [
        # Nested virtualisation: TSC-deadline timers never fire.
        "-enable-kvm", "-machine", "q35", "-cpu", "max,-kvmclock",
        "-smp", "2", "-m", "1024",
        "-nographic", "-monitor", "none", "-nic", "none",
        "-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={os.environ['ovmfCode']}",
        "-drive", "if=pflash,format=raw,unit=1,file=vars.fd",
        "-cdrom", os.environ["iso"],
        # The only virtio disk: /dev/vda.
        "-drive", f"if=virtio,format=raw,file={disk}",
    ],
    encoding="utf-8",
    timeout=300,
    logfile=sys.stdout,
)

vm.expect_exact("a-box installer")
vm.expect_exact("# ")
vm.sendline("a-box-install /dev/vda")
vm.expect_exact("Press [Enter] to begin installation")
vm.sendline("")

i = vm.expect_exact(["DONE. Please reboot", "Formatting /dev/vda failed"], timeout=600)
if i != 0:
    sys.exit("installer failed")

# Everything is on the virtual disk once the guest has synced and powered off.
vm.sendline("sync")
vm.sendline("poweroff -f")
vm.expect(pexpect.EOF)
vm.close()

subprocess.run(["qemu-img", "convert", "-f", "raw", "-O", "qcow2", "-c", disk, out], check=True)
