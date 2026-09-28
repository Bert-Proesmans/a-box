# agent-vm-host chunks 2-4: dedicated VM-launcher device access, and the
# boot-time platform preflight (KVM usability, cgroup v2-only, memory
# posture). See docs/agent-vm-host/02-host-platform{,-plan,-todo}.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  preflight = pkgs.writeShellApplication {
    name = "agent-vm-host-preflight";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = ''
      # Runs every check regardless of earlier failures, so a negative run
      # reports every violated guarantee in one pass, not just the first.
      # Needs root (for the runuser probe below) when run manually.
      status=0

      fail() {
        echo "FAIL: $1" >&2
        status=1
      }

      # --- KVM availability (chunk 2, step 2.2) ---
      if [ ! -d /sys/module/kvm ]; then
        fail "KVM kernel module not loaded on this host."
      elif [ ! -e /dev/kvm ]; then
        fail "KVM device present but not usable - outer hypervisor nested virtualization not enabled; contact host owner."
      elif ! runuser -u vm-launcher -- sh -c 'exec 3<>/dev/kvm' 2>/dev/null; then
        fail "KVM device present but not usable - outer hypervisor nested virtualization not enabled; contact host owner."
      else
        echo "OK: /dev/kvm usable by vm-launcher"
      fi

      # --- cgroup v2 exclusively (chunk 3, step 3.2) ---
      if [ ! -r /sys/fs/cgroup/cgroup.controllers ]; then
        fail "unified cgroup v2 controller interface not present."
      elif [ -n "$(findmnt -t cgroup -n 2>/dev/null)" ]; then
        fail "legacy cgroup v1 hierarchy mounted alongside cgroup v2."
      else
        echo "OK: cgroup v2 exclusive"
      fi

      # --- memory posture: no swap, no KSM (chunk 4, step 4.1) ---
      if [ "$(wc -l < /proc/swaps)" -ne 1 ]; then
        fail "a swap device is active - this host must never activate swap (guest memory confidentiality)."
      else
        echo "OK: no swap device active"
      fi

      if [ "$(cat /sys/kernel/mm/ksm/run)" != "0" ]; then
        fail "KSM is running - this host must never enable KSM (cross-tenant page-dedup side channel)."
      else
        echo "OK: KSM disabled"
      fi

      exit "$status"
    '';
  };
in
{
  # Dedicated, unprivileged account for opening /dev/kvm - kept separate
  # from the interactive admin login so guest-launching code never needs a
  # human's account or root. Nested virtualization (boot.kernelModules'
  # kvm-amd/kvm-intel, set on the base host) is necessary but not
  # sufficient: this host itself runs as a guest
  # (virtualisation.hypervGuest.enable), so /dev/kvm only works here if the
  # outer hypervisor also has nested virt enabled for this guest - that
  # outer layer is out of scope for this configuration to detect or set.
  users.groups.vm-launcher = { };
  users.users.vm-launcher = {
    isSystemUser = true;
    group = "vm-launcher";
    extraGroups = [ "kvm" ];
    description = "agent-vm-host VM launcher - unprivileged /dev/kvm access";
  };

  # cgroup v2 is a strict platform guarantee, not a default: every
  # cgroup-touching component in this subsystem (jailer, systemd resource
  # directives, kvm-pit placement) targets v2 with no v1 fallback path.
  # Systemd itself already refuses legacy v1 unless forced via kernel
  # params - this assertion keeps that forcing from ever landing quietly.
  assertions = [
    {
      assertion = !(lib.elem "systemd.unified_cgroup_hierarchy=0" config.boot.kernelParams);
      message = "agent-vm-host requires cgroup v2 exclusively - do not force legacy v1 via kernel params.";
    }
  ];

  # Host memory posture for VM density: multiple mutually-untrusted guests
  # share this host, so neither guarantee is left as an implicit default.
  # No swap: risks writing guest memory contents to persistent storage.
  swapDevices = lib.mkForce [ ];
  # No KSM: risks a cross-tenant page-deduplication side channel.
  hardware.ksm.enable = lib.mkForce false;

  environment.systemPackages = [ preflight ];

  systemd.services.agent-vm-host-preflight = {
    description = "agent-vm-host platform preflight: KVM, cgroup v2, memory posture";
    after = [
      "systemd-udev-settle.service"
      "local-fs.target"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${preflight}/bin/agent-vm-host-preflight";
    };
  };
}
