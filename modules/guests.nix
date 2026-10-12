# Firecracker microVM guests: instance n = 1..max runs the image from `guest/` (default.nix).
# Control is plain systemctl on template units:
#
#   a-box-guest@n   Firecracker; BindsTo and ordered after the two units below
#   a-box-proxy@n   mitmproxy of the guest, with its entry socket and forwarder (modules/guest-proxy)
#   a-box-log@n     console logger: svlogd, timestamped, size-rotated, in /persistent
#
#   guest ──vsock CID n+2──> Firecracker ──unix /run/a-box/guest-n/vsock_3128──> proxy ──> internet
#     └── ttyS0 ──> Firecracker stdout ──fifo /run/a-box/console-n──> logger ──> /persistent/a-box/logs/guest-n/
#
# A guest's identity on the host is the proxy process its connection arrives at: one per instance,
# reached only through that instance's directory. The guest cannot choose it, and no other
# instance's users can enter the directory or open the proxy's loopback port.
#
# Users, all static (the logs in /persistent are owned by them, so uids must not drift), per n:
#
#   a-box-vm-n     Firecracker; group a-box-guest-n
#   a-box-proxy-n  mitmproxy; group a-box-proxy-n
#   a-box-entry-n  forwarder from the vsock socket to the proxy; group a-box-entry-n
#   a-box-log-n    svlogd; group a-box-log-n
#
# /run/a-box/guest-n is root:a-box-guest-n 1770: Firecracker creates its sockets in it, systemd
# the proxy's entry socket (owned by Firecracker's user); the sticky bit stops Firecracker from
# replacing the latter, and nothing else enters it.
{
  config,
  lib,
  pkgs,
  guest,
  ...
}:
let
  cfg = config.a-box.guests;

  instances = lib.range 1 cfg.max;

  # Firecracker's own estimate is <= 5 MiB for the VMM threads; the rest is margin for page tables
  # and KVM structures charged to the cgroup. Not measured.
  overheadMiB = 64;

  # CID 3 is the first valid guest CID.
  cid = n: n + 2;

  # Static ids per role: logs in /persistent keep their owner across boots, the root fs does not.
  uidBase = {
    vm = 20100;
    proxy = 20200;
    log = 20300;
    entry = 20400;
  };

  # One config file per instance, picked by `%i`; a missing file is an instance out of range.
  firecrackerConfigs = pkgs.linkFarm "a-box-guest-configs" (
    map (n: {
      name = "${toString n}.json";
      path = pkgs.writeText "a-box-guest-${toString n}.json" (
        builtins.toJSON {
          boot-source = {
            kernel_image_path = "${guest.kernel}";
            boot_args = guest.bootArgs;
          };
          drives = [
            {
              drive_id = "rootfs";
              path_on_host = "${guest.rootfs}";
              is_root_device = true;
              is_read_only = true;
            }
          ];
          machine-config = {
            vcpu_count = cfg.vcpus;
            mem_size_mib = cfg.memoryMiB;
            smt = false;
          };
          vsock = {
            guest_cid = cid n;
            uds_path = "/run/a-box/guest-${toString n}/vsock";
          };
          # Firecracker's own log lines default to stdout, which is the console stream. Dropped;
          # startup errors still reach stderr, which goes to the journal.
          logger.log_path = "/dev/null";
        }
      );
    }) instances
  );

  credentialName = lib.types.strMatching "[A-Za-z0-9_][A-Za-z0-9._-]*";

  # [*.|.]host[:port], same grammar as the addon; `lib.match` lists the groups: wildcard, host, the
  # host's tail, `:port`, port.
  entryPattern = "(\\*\\.|\\.)?([a-z0-9_]([a-z0-9._-]*[a-z0-9_])?)(:([0-9]{1,5}))?";

  credentialFile = "proxy-ca.pem";

  domainPolicy = lib.types.submodule {
    options.inject = lib.mkOption {
      type = lib.types.attrsOf credentialName;
      default = { };
      example = {
        x-api-key = "anthropic-key";
      };
      description = ''
        Request headers the proxy sets for this entry, header name -> name of the root-owned file
        under /persistent/a-box/secrets/guest-<n>/ whose content is the header value. A copy of the
        header sent by the guest is replaced. Applies to requests to the entry's hosts only.
      '';
    };
  };

  instancePolicy = lib.types.submodule {
    options.domains = lib.mkOption {
      type = lib.types.attrsOf domainPolicy;
      default = { };
      example = {
        "api.anthropic.com".inject.x-api-key = "anthropic-key";
        "*.example.com:8443" = { };
      };
      description = ''
        What the guest may reach through its proxy; everything else is refused and logged. Names are
        lowercase host names, optionally prefixed `*.` (subdomains only) or `.` (the name and its
        subdomains), optionally followed by `:port`; without a port the entry covers 80 and 443.
        When entries overlap the most specific one applies, including its `inject`. IP addresses are
        never allowed.

        The scheme is whatever the client sends: plain http as absolute-URI requests, https as
        CONNECT, which the proxy terminates with a certificate of its CA and re-encrypts towards
        the server (verified against the host trust store).
      '';
    };
  };

  mergeAll = f: lib.mergeAttrsList (map f instances);

  tmpfiles = mergeAll (
    n:
    let
      i = toString n;
    in
    {
      "/run/a-box/guest-${i}".d = {
        mode = "1770";
        user = "root";
        group = "a-box-guest-${i}";
      };

      # Firecracker's stdout, read by the logger only. systemd opens the write end as root.
      "/run/a-box/console-${i}".p = {
        mode = "0600";
        user = "a-box-log-${i}";
        group = "a-box-log-${i}";
      };

      "/persistent/a-box/logs/guest-${i}".d = {
        mode = "0700";
        user = "a-box-log-${i}";
        group = "a-box-log-${i}";
      };

      "/persistent/a-box/secrets/guest-${i}".d = {
        mode = "0700";
        user = "root";
        group = "root";
      };
    }
  );
in
{
  options.a-box.guests = {
    max = lib.mkOption {
      type = lib.types.ints.between 1 99;
      default = 8;
      description = ''
        Number of guest instances: a-box-guest@1 ... a-box-guest@<max>. Units for any other number
        refuse to start. Bounds the resource slice and the users, groups and directories.
      '';
    };

    vcpus = lib.mkOption {
      type = lib.types.ints.between 1 32;
      default = 1;
      description = "vCPUs per guest.";
    };

    memoryMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 512;
      description = "RAM per guest, in MiB.";
    };

    logRotateBytes = lib.mkOption {
      type = lib.types.ints.between 4096 2147483647;
      default = 4194304;
      description = "Size at which a guest's console log file is closed and a new one started.";
    };

    logKeepFiles = lib.mkOption {
      type = lib.types.ints.between 2 1000000;
      default = 32;
      description = ''
        Rotated console log files kept per guest; the oldest is deleted beyond that. Bounds the
        disk use to about logKeepFiles * logRotateBytes per guest.
      '';
    };

    policy = lib.mkOption {
      type = lib.types.attrsOf instancePolicy;
      default = { };
      example = {
        "1".domains."api.anthropic.com".inject.x-api-key = "anthropic-key";
      };
      description = ''
        Proxy policy per instance, keyed by instance number as a string. An instance without an
        entry may reach nothing.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = lib.all (k: lib.elem k (map toString instances)) (lib.attrNames cfg.policy);
        message = "a-box.guests.policy: keys must be instance numbers 1..${toString cfg.max}.";
      }
    ]
    ++ lib.concatMap (
      n:
      let
        domains = cfg.policy.${n}.domains;
        valid =
          d:
          let
            m = lib.match entryPattern d;
          in
          m != null
          # IP addresses are never allowed by the proxy, in any form a resolver parses (`127.1`,
          # `0x7f.1`): names do not end in a numeric label.
          && lib.match "(.*\\.)?([0-9]+|0x[0-9a-f]*)" (lib.elemAt m 1) == null
          && (lib.elemAt m 4 == null || lib.toInt (lib.elemAt m 4) < 65536);
      in
      map (d: {
        assertion = valid d;
        message = "a-box.guests.policy.${n}: entry `${d}` must be a lowercase host name, optionally prefixed `*.` or `.` and suffixed `:port`; IP addresses are not allowed.";
      }) (lib.attrNames domains)
      ++ map (h: {
        assertion = lib.match "[A-Za-z0-9-]+" h != null;
        message = "a-box.guests.policy.${n}: injected header `${h}` must match [A-Za-z0-9-]+.";
      }) (lib.concatMap (d: lib.attrNames d.inject) (lib.attrValues domains))
      ++ map (c: {
        assertion = c != credentialFile;
        message = "a-box.guests.policy.${n}: `${credentialFile}` is the proxy CA key, not a credential name.";
      }) (lib.concatMap (d: lib.attrValues d.inject) (lib.attrValues domains))
    ) (lib.attrNames cfg.policy);

    users.users = mergeAll (
      n:
      let
        i = toString n;
      in
      {
        "a-box-vm-${i}" = {
          isSystemUser = true;
          uid = uidBase.vm + n;
          group = "a-box-guest-${i}";
        };
        "a-box-proxy-${i}" = {
          isSystemUser = true;
          uid = uidBase.proxy + n;
          group = "a-box-proxy-${i}";
        };
        "a-box-entry-${i}" = {
          isSystemUser = true;
          uid = uidBase.entry + n;
          group = "a-box-entry-${i}";
        };
        "a-box-log-${i}" = {
          isSystemUser = true;
          uid = uidBase.log + n;
          group = "a-box-log-${i}";
        };
      }
    );

    users.groups = mergeAll (n: {
      "a-box-guest-${toString n}".gid = uidBase.vm + n;
      "a-box-proxy-${toString n}".gid = uidBase.proxy + n;
      "a-box-entry-${toString n}".gid = uidBase.entry + n;
      "a-box-log-${toString n}".gid = uidBase.log + n;
    });

    # The directories under /persistent live there directly, not bind-mounted over the root as
    # preservation does it: nothing reads them through another path. /persistent is mounted in the
    # initrd, before tmpfiles runs.
    systemd.tmpfiles.settings."50-a-box-guests" = tmpfiles // {
      "/run/a-box".d.mode = "0755";

      # Traversable by the loggers; their own directories are 0700.
      "/persistent/a-box".d.mode = "0711";
      "/persistent/a-box/logs".d.mode = "0711";

      "/persistent/a-box/secrets".d = {
        mode = "0700";
        user = "root";
        group = "root";
      };
    };

    # Guest RAM is anonymous memory of the Firecracker process: the slice caps all instances
    # together, so a runaway guest cannot take the host.
    systemd.slices.a-box-guests.sliceConfig.MemoryMax = "${
      toString (cfg.max * (cfg.memoryMiB + overheadMiB))
    }M";

    systemd.services."a-box-guest@" = {
      description = "Firecracker guest %i";

      # BindsTo: the guest stops when its proxy or logger goes away.
      bindsTo = [
        "a-box-proxy@%i.service"
        "a-box-log@%i.service"
      ];
      after = [
        "a-box-proxy@%i.service"
        "a-box-log@%i.service"
      ];

      # Instances are 1..max: only those have a config file.
      unitConfig.AssertPathExists = "${firecrackerConfigs}/%i.json";

      scriptArgs = "%i";
      script = ''
        run=/run/a-box/guest-$1

        # Firecracker binds both sockets without removing a leftover one.
        rm -f "$run/api.sock" "$run/vsock"

        exec ${pkgs.firecracker}/bin/firecracker \
          --id "guest-$1" \
          --api-sock "$run/api.sock" \
          --config-file ${firecrackerConfigs}/"$1".json
      '';

      serviceConfig = {
        Slice = "a-box-guests.slice";
        User = "a-box-vm-%i";
        Group = "a-box-guest-%i";
        SupplementaryGroups = [ "kvm" ];

        # Serial console -> logger. Opened by systemd as root, so the FIFO needs no access for the
        # Firecracker user. stderr stays out of the console stream.
        StandardOutput = "file:/run/a-box/console-%i";
        StandardError = "journal";

        TimeoutStopSec = "10s";

        # Firecracker leaves its API and vsock sockets behind at exit; removed as root (`+`), also
        # after a crash.
        ExecStopPost = "+${pkgs.coreutils}/bin/rm -f /run/a-box/guest-%i/api.sock /run/a-box/guest-%i/vsock";

        # Sockets Firecracker creates (API, vsock) are for the owner and root only.
        UMask = "0077";

        # A core dump would hold the guest's memory.
        LimitCORE = 0;

        # No NIC, no TAP: the guest reaches the host over vsock, which is a unix socket here.
        PrivateNetwork = true;
        RestrictAddressFamilies = "AF_UNIX";

        # Firecracker installs its own seccomp filter per thread; none is added on top.
        SystemCallArchitectures = "native";
        DevicePolicy = "closed";
        DeviceAllow = [ "/dev/kvm rw" ];

        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RemoveIPC = true;

        # Secrets and logs are out of reach, whatever their permissions.
        InaccessiblePaths = [ "/persistent" ];
        ReadWritePaths = [ "/run/a-box/guest-%i" ];
      };
    };

    # Proxy lifecycle follows the guest's, also when Firecracker exits on its own; the units are in
    # modules/guest-proxy (the entry socket follows the proxy). Started alone, it stops again at once.
    systemd.services."a-box-proxy@" = {
      partOf = [ "a-box-guest@%i.service" ];
      before = [ "a-box-guest@%i.service" ];
      unitConfig.StopWhenUnneeded = true;
    };

    systemd.services."a-box-log@" = {
      description = "Console log of guest %i";

      partOf = [ "a-box-guest@%i.service" ];
      before = [ "a-box-guest@%i.service" ];

      # Opening the FIFO blocks until Firecracker has it: a guest that never starts must not leave
      # the logger behind.
      unitConfig = {
        StopWhenUnneeded = true;
        AssertPathExists = "${firecrackerConfigs}/%i.json";
      };

      scriptArgs = "%i";
      script = ''
        dir=/persistent/a-box/logs/guest-$1

        # svlogd reads its rotation settings from here at startup.
        printf 's%s\nn%s\n' ${toString cfg.logRotateBytes} ${toString cfg.logKeepFiles} > "$dir/config"

        # Timestamps are UTC. Non-printable bytes become `_` (the guest controls them: no terminal
        # escapes in the files), so the console's CRLF ends each line in `_`. EOF, once Firecracker
        # has exited and the FIFO is drained, ends the process.
        exec ${pkgs.runit}/bin/svlogd -tt -r _ "$dir" < "/run/a-box/console-$1"
      '';

      # A stop comes after the guest's. Wait for svlogd to see EOF and flush instead of cutting
      # the last console lines off with SIGTERM.
      preStop = ''
        for _ in $(seq 100); do
          kill -0 "''${MAINPID:-}" 2>/dev/null || exit 0
          sleep 0.1
        done
      '';

      serviceConfig = {
        User = "a-box-log-%i";
        Group = "a-box-log-%i";

        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        NoNewPrivileges = true;
        PrivateNetwork = true;
        RestrictAddressFamilies = "AF_UNIX";
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
        UMask = "0077";
        ReadWritePaths = [ "/persistent/a-box/logs/guest-%i" ];
        InaccessiblePaths = [ "/persistent/a-box/secrets" ];
      };
    };
  };
}
