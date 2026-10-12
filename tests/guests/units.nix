{ pkgs, guest }:
let
  # The stub image with an init that also fetches through the proxy (see init.sh); wget is not
  # in the image's default applets.
  testGuest = (guest.override { applets = guest.applets ++ [ "wget" ]; }).overrideScope (
    final: prev: {
      init = final.mkScript {
        src = ./init.sh;
        replacements = {
          tools = "${final.tools}";
          stub = "${prev.init}";
        };
      };
    }
  );
in
pkgs.testers.runNixOSTest {
  name = "a-box-guests-units";

  globalTimeout = 400;

  defaults = {
    # Nested virtualisation: TSC-deadline timers never fire.
    virtualisation.qemu.options = [ "-cpu max,-kvmclock" ];
    boot.kernelParams = [ "lapic=notscdeadline" ];
  };

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        ../../modules/guests.nix
        # Unfinished: still the stand-in proxy. proxy.nix runs a guest against the real
        # modules/guest-proxy; swapping it in here needs guest.py's and init.sh's expectations
        # (the stub's "proxy-stub saw" line) adapted.
        ./proxy-stub.nix
      ];

      _module.args.guest = testGuest;

      virtualisation.memorySize = 1536;

      # Firecracker needs /dev/kvm: nested one level further.
      boot.kernelModules = [ "kvm-intel" ];

      # The module expects /persistent; the test has a plain directory.
      systemd.tmpfiles.settings."10-persistent"."/persistent".d.mode = "0755";

      a-box.guests = {
        max = 2;
        memoryMiB = 128;

        # Rotation after a few lines, two old files kept.
        logRotateBytes = 4096;
        logKeepFiles = 2;
      };

      # a-box-log@ stops when nothing needs it, so a started one needs a holder.
      systemd.targets.a-box-test-logger.wants = [ "a-box-log@2.service" ];

      # Plays Firecracker's side of the console FIFO: systemd opens it as root for stdout, like
      # it does for the guest unit, and the test writes to it through /proc/<pid>/fd/1.
      systemd.services.test-console-feed.serviceConfig = {
        StandardOutput = "file:/run/a-box/console-2";
        ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      };
    };

  # One script per scenario, run in order on the same node.
  testScript =
    ''
      import shlex

      start_all()
      machine.wait_for_unit("multi-user.target")
    ''
    + builtins.concatStringsSep "" (
      map builtins.readFile [
        ./logger.py
        ./guest.py
      ]
    );
}
