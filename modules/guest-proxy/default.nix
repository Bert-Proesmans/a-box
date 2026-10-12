# Per-guest forward proxy: one mitmproxy per instance, a-box-proxy@n, doing full TLS interception.
#
#   guest ─vsock 2:3128─> Firecracker ─> /run/a-box/guest-n/vsock_3128 ─> systemd-socket-proxyd
#     ─> 127.0.0.1:3128+n ─> mitmproxy (addon: allowlist, credentials, log) ─> internet
#
# The guest sends `CONNECT host:443` (https) or absolute-URI requests (http). mitmproxy terminates
# TLS with a certificate for `host` signed by the proxy CA (the one baked into the guest image,
# guest.proxyCa; the key is /persistent/a-box/secrets/proxy-ca.pem) and re-encrypts to the server,
# verifying it against the host trust store. DNS happens here, once; the guest has none.
#
# Units per instance n:
#
#   a-box-proxy-entry@n.socket   the unix socket Firecracker connects to; owned by a-box-vm-n, 0600
#   a-box-proxy-entry@n.service  systemd-socket-proxyd as a-box-entry-n: socket -> loopback port
#   a-box-proxy@n.service        mitmproxy as a-box-proxy-n, ready once its port is listening
#
# One process per instance, not one shared by all, because:
#
#   - Identity is the process, not a mapping the addon must get right. A guest cannot reach another
#     guest's proxy, and the proxy of guest n holds guest n's credentials only: a flaw reachable
#     from one guest's traffic exposes that instance, not every instance's secrets.
#   - A guest that floods or wedges its proxy (MemoryMax, TasksMax per unit) leaves the others be.
#   - Cost: 58 MiB anonymous memory per idle mitmproxy (measured, 12.2.3, no addon: Pss_Anon 57.9 MB,
#     Rss 81 MB, of which about 12 MB file pages shared between instances). 8 guests: about 0.5 GiB
#     on top of their 8 x (512 + 64) MiB. Units run only while their guest does.
#
# mitmproxy 12.2.3 cannot listen on a unix socket (`regular@[host:]port` is the whole mode syntax;
# mitmproxy/proxy/mode_servers.py calls asyncio.start_server(host, port)), hence the forwarder and
# a loopback port. Every local user can connect to a loopback port, so the kernel decides who may:
# the nftables table below rejects connections to proxy n's port from any user but a-box-entry-n
# (and the entry unit's own IPAddressAllow lets it reach nothing else).
#
# SSRF: names are resolved by mitmproxy at connect time, so a check on a resolved address in the
# addon would race with DNS rebinding. Two kernel-level guards act on the actual connect instead:
#
#   - nftables: the proxy users open no new connection to an address of this host (127/8, the
#     host's LAN and public addresses: `fib daddr type local`) or to a denied range. `reject`: the
#     proxy gets "connection refused" and answers the guest 502 at once.
#   - IPAddressDeny of the unit (cgroup BPF), the same ranges: silent drops (a connect hangs until
#     it times out), independent of nftables. It cannot cover the host's own addresses without also
#     cutting the proxy off from its listener, so 127.0.0.1 is allowed there.
#
# IPv6 is not opened at all (no AF_INET6): v4-mapped, NAT64 and ULA addresses need no enumeration.
# Exact `127.0.0.1:port` style entries for a future host-local service are not implemented: they
# would need a per-port exception in both guards.
#
# Credentials: LoadCredential per unit, from root-only files; the addon (addon.py, guard.py) sets
# the configured headers on requests to the entry's hosts and never logs a value. It also streams
# event-stream responses through (mitmproxy otherwise holds them to the end).
{
  config,
  lib,
  pkgs,
  guest,
  ...
}:
let
  cfg = config.a-box.guests;

  instances = map toString (lib.range 1 cfg.max);

  # Instance n's mitmproxy listens on 127.0.0.1:(basePort + n).
  basePort = 3128;

  # What the proxy may not connect to, even if an allowed name resolves there (DNS rebinding, a
  # wildcard domain pointing inward). 127.0.0.0/8 is here too; 127.0.0.1 itself is let through for
  # the listener, and nftables rejects connections the proxy opens to it (see above).
  deniedRanges = [
    "0.0.0.0/8" # "this" network
    "10.0.0.0/8" # private
    "100.64.0.0/10" # carrier-grade NAT
    "127.0.0.0/8" # loopback
    "169.254.0.0/16" # link-local, cloud metadata
    "172.16.0.0/12" # private
    "192.0.0.0/24" # IETF protocol assignments
    "192.168.0.0/16" # private
    "198.18.0.0/15" # benchmarking
    "224.0.0.0/3" # multicast, reserved, broadcast
  ];

  policyOf = n: (cfg.policy.${n} or { }).domains or { };

  credentialsOf = domains: lib.unique (lib.concatMap (d: lib.attrValues d.inject) (lib.attrValues domains));

  uidOf = user: config.users.users.${user}.uid;

  # The addon is checked at build time: pyflakes, then its unit tests (test_guard.py) against the
  # mitmproxy it runs in.
  checkPython = pkgs.python3.withPackages (ps: [
    ps.mitmproxy
    ps.pyflakes
  ]);

  addon =
    pkgs.runCommand "a-box-proxy-addon" { nativeBuildInputs = [ checkPython ]; }
      ''
        mkdir $out
        cp ${./addon.py} $out/addon.py
        cp ${./guard.py} $out/guard.py
        cp ${./test_guard.py} test_guard.py

        python -m pyflakes $out/addon.py $out/guard.py test_guard.py
        PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=$out python -m unittest -v test_guard
      '';

  # One policy file per instance, picked by `%i`; a missing one is an instance out of range.
  policies = pkgs.linkFarm "a-box-proxy-policies" (
    map (n: {
      name = "${n}.json";
      path = pkgs.writeText "a-box-proxy-${n}.json" (
        builtins.toJSON {
          instance = n;
          domains = policyOf n;
        }
      );
    }) instances
  );

  # Hardening shared by the proxy and its entry forwarder.
  sandbox = {
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    NoNewPrivileges = true;
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
    RemoveIPC = true;
    SystemCallArchitectures = "native";
    InaccessiblePaths = [ "/persistent" ];
    UMask = "0077";
    LimitCORE = 0;
  };

  # Per instance: the proxy's credentials (its CA key and the headers' values) and the owner of
  # the entry socket.
  perInstance = lib.listToAttrs (
    map (
      n:
      lib.nameValuePair "a-box-proxy@${n}" {
        overrideStrategy = "asDropin";
        serviceConfig.LoadCredential = [
          "proxy-ca.pem:/persistent/a-box/secrets/proxy-ca.pem"
        ]
        ++ map (c: "${c}:/persistent/a-box/secrets/guest-${n}/${c}") (credentialsOf (policyOf n));
      }
    ) instances
  );

  entrySockets = lib.listToAttrs (
    map (
      n:
      lib.nameValuePair "a-box-proxy-entry@${n}" {
        overrideStrategy = "asDropin";
        socketConfig.SocketUser = "a-box-vm-${n}";
      }
    ) instances
  );

  proxyUids = lib.concatMapStringsSep ", " (n: toString (uidOf "a-box-proxy-${n}")) instances;

  nftRules = ''
    chain output {
      type filter hook output priority filter; policy accept;

      # Entry: only a-box-entry-n opens connections to the port of proxy n.
    ${lib.concatMapStrings (n: ''
      ip daddr 127.0.0.1 tcp dport ${toString (basePort + lib.toInt n)} meta skuid != ${toString (uidOf "a-box-entry-${n}")} reject with tcp reset
    '') instances}
      # Egress: the proxies open no new connections to this host or the denied ranges.
      meta skuid { ${proxyUids} } ct state new fib daddr type local reject
      meta skuid { ${proxyUids} } ct state new ip daddr { ${lib.concatStringsSep ", " deniedRanges} } reject
    }
  '';
in
{
  assertions = [
    {
      assertion = config.services.resolved.enable;
      message = "a-box-proxy: names are resolved through systemd-resolved's NSS module (the proxy may not reach DNS servers in private ranges itself); enable services.resolved.";
    }
  ];

  # The loopback ports and the SSRF guard are enforced by nftables.
  networking.nftables = {
    enable = true;
    tables."a-box-proxy" = {
      family = "inet";
      content = nftRules;
    };
  };

  systemd.sockets = entrySockets // {
    "a-box-proxy-entry@" = {
      description = "Proxy entry of guest %i (vsock port 3128)";

      # Instances are 1..max: only those have a policy.
      unitConfig = {
        AssertPathExists = "${policies}/%i.json";
        # Needed by the proxy (below) and by nothing else: gone with it, also when the proxy
        # stops by itself because its guest is gone.
        StopWhenUnneeded = true;
      };

      partOf = [ "a-box-proxy@%i.service" ];

      socketConfig = {
        ListenStream = "/run/a-box/guest-%i/vsock_3128";
        # Firecracker (SocketUser, per instance) connects; nobody else.
        SocketMode = "0600";
        RemoveOnStop = true;
      };
    };
  };

  systemd.services = perInstance // {
    "a-box-proxy-entry@" = {
      description = "Proxy entry forwarder of guest %i";

      # No proxy, no forwarder: a connection would only be dropped later.
      requires = [ "a-box-proxy@%i.service" ];
      after = [ "a-box-proxy@%i.service" ];

      scriptArgs = "%i";
      script = ''
        exec ${config.systemd.package}/lib/systemd/systemd-socket-proxyd "127.0.0.1:$((${toString basePort} + $1))"
      '';

      serviceConfig = sandbox // {
        User = "a-box-entry-%i";
        Group = "a-box-entry-%i";

        # Reaches the loopback port of the proxy and nothing else.
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
        ];
        IPAddressDeny = "any";
        IPAddressAllow = "127.0.0.1/32";

        MemoryDenyWriteExecute = true;
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
        MemoryMax = "64M";
        TasksMax = 8;
      };
    };

    "a-box-proxy@" = {
      description = "mitmproxy of guest %i";

      # The proxy's guarantees rest on the table: without it, no proxy.
      requires = [
        "a-box-proxy-entry@%i.socket"
        "nftables.service"
      ];
      after = [
        "a-box-proxy-entry@%i.socket"
        "nftables.service"
      ];

      # Instances are 1..max: only those have a policy.
      unitConfig.AssertPathExists = "${policies}/%i.json";

      environment = {
        A_BOX_POLICY = "${policies}/%i.json";
        # The store is read-only; the journal is the log.
        PYTHONDONTWRITEBYTECODE = "1";
        PYTHONUNBUFFERED = "1";
      };

      # mitmproxy reads its CA, key first, from `mitmproxy-ca.pem` in its confdir. The key must
      # belong to the certificate in the guest image, or the proxy would mint certificates the
      # guest rejects: refuse to start instead.
      preStart = ''
        key=$CREDENTIALS_DIRECTORY/proxy-ca.pem
        cert=${guest.proxyCa}
        conf=$RUNTIME_DIRECTORY/conf

        mkdir -p "$conf"

        if [ "$(${lib.getExe pkgs.openssl} pkey -in "$key" -pubout)" != "$(${lib.getExe pkgs.openssl} x509 -in "$cert" -pubkey -noout)" ]; then
          echo "proxy-ca.pem is not the key of the CA certificate in the guest image" >&2
          exit 1
        fi

        { ${lib.getExe pkgs.openssl} pkey -in "$key"; cat "$cert"; } > "$conf/mitmproxy-ca.pem"
      '';

      scriptArgs = "%i";
      script = ''
        exec ${pkgs.mitmproxy}/bin/mitmdump \
          --mode "regular@127.0.0.1:$((${toString basePort} + $1))" \
          --scripts ${addon}/addon.py \
          --set confdir="$RUNTIME_DIRECTORY/conf" \
          --set ssl_verify_upstream_trusted_ca=${config.security.pki.caBundle} \
          --set connection_strategy=lazy \
          --set upstream_cert=false \
          --set rawtcp=false \
          --set http3=false \
          --set onboarding=false \
          --set flow_detail=0 \
          --set termlog_verbosity=warn \
          --set stream_large_bodies=1m \
          --set tcp_timeout=900
      '';

      serviceConfig = sandbox // {
        # The addon sends READY once the listener exists.
        Type = "notify";
        NotifyAccess = "main";

        User = "a-box-proxy-%i";
        Group = "a-box-proxy-%i";

        RuntimeDirectory = "a-box-proxy-%i";
        RuntimeDirectoryMode = "0700";

        # No MemoryDenyWriteExecute: with it the TLS handshake with the guest fails (tested).
        MemoryMax = "1G";
        TasksMax = 256;
        LimitNOFILE = 4096;

        # Outbound: IPv4 only, and not to the host or its networks. The listener's own loopback
        # address is the one exception; nftables keeps the proxy from connecting to it.
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
        ];
        IPAddressAllow = [ "127.0.0.1/32" ];
        IPAddressDeny = deniedRanges;

        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
      };
    };
  };
}
