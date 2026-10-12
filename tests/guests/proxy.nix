{ pkgs, guest }:
let
  # The image whose CA the proxy's key (tests/proxy-ca.sec) belongs to, with an init that also
  # fetches through the proxy (init.sh, shared with units.nix); wget is not in the default applets.
  testGuest =
    (guest.override {
      proxyCa = ../proxy-ca.crt;
      applets = guest.applets ++ [ "wget" ];
    }).overrideScope
      (
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

  # CAs and leaves of the fake internet: `a-box-test-ca` is trusted by the node (and so by the
  # proxy), `a-box-rogue-ca` is not. secure.test's certificate names every https host of the test;
  # rogue.test's is signed by the rogue CA.
  certs =
    pkgs.runCommand "a-box-test-certs" { nativeBuildInputs = [ pkgs.openssl ]; }
      ''
        mkdir $out
        cd $out

        ca() {
          openssl req -x509 -newkey rsa:2048 -nodes -keyout $1.key -out $1.crt -subj "/CN=$1" \
            -days 36500 -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign
        }

        leaf() {
          printf 'subjectAltName=%s\n' "$3" > $1.ext
          openssl req -newkey rsa:2048 -nodes -keyout $1.key -out $1.csr -subj "/CN=$1"
          openssl x509 -req -in $1.csr -CA $2.crt -CAkey $2.key -CAcreateserial -out $1.crt \
            -days 36500 -extfile $1.ext
        }

        ca a-box-test-ca
        ca a-box-rogue-ca
        leaf secure.test a-box-test-ca DNS:secure.test,DNS:port.test
        leaf rogue.test a-box-rogue-ca DNS:rogue.test
        rm *.csr *.ext *.srl
      '';

  upstream = pkgs.writers.writePython3Bin "test-upstream" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./upstream.py);

  client = pkgs.writers.writePython3Bin "proxyclient" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./client.py);
in
pkgs.testers.runNixOSTest {
  name = "a-box-proxy";

  globalTimeout = 900;

  defaults = {
    # Nested virtualisation: TSC-deadline timers never fire.
    virtualisation.qemu.options = [ "-cpu max,-kvmclock" ];
    boot.kernelParams = [ "lapic=notscdeadline" ];
  };

  nodes.machine =
    { config, pkgs, ... }:
    {
      imports = [
        ../../modules/guests.nix
        ../../modules/guest-proxy
      ];

      _module.args.guest = testGuest;

      virtualisation.memorySize = 1536;

      # The guest scenario runs Firecracker, which needs /dev/kvm: nested one level further.
      boot.kernelModules = [ "kvm-intel" ];

      services.resolved.enable = true;

      # The module expects /persistent; the test has a plain directory.
      systemd.tmpfiles.settings."10-persistent"."/persistent".d.mode = "0755";

      security.pki.certificateFiles = [ "${certs}/a-box-test-ca.crt" ];

      environment.systemPackages = [
        client
        pkgs.curl
        pkgs.iproute2
        pkgs.openssl
      ];

      a-box.guests = {
        max = 2;
        memoryMiB = 128;

        policy."1".domains = {
          "ok.test".inject."X-Api-Key" = "key-1";
          "secure.test".inject.Authorization = "token-1";
          "wrong.test" = { };
          "rogue.test" = { };
          "*.wild.test" = { };
          "port.test:8443" = { };
          "ok.test:8080" = { };

          # Allowed by name, but resolving to addresses the proxy must not reach.
          "loop.test" = { };
          "lan.test" = { };
          "meta.test" = { };
          "priv.test" = { };
        };

        policy."2".domains."ok.test".inject."X-Api-Key" = "key-2";
      };

      # The fake internet is a network namespace behind a veth in TEST-NET-3, which the proxy may
      # reach: its address is remote, not one of the host's. priv.test lives in the namespace too,
      # at an RFC 1918 address routed through the veth: remote, but in a denied range.
      systemd.services.test-internet = {
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.iproute2 ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ip netns add internet
          ip link add veth-host type veth peer name veth-net
          ip link set veth-net netns internet

          ip addr add 203.0.113.1/24 dev veth-host
          ip link set veth-host up
          ip route add 10.99.0.10/32 via 203.0.113.10

          ip -n internet addr add 203.0.113.10/24 dev veth-net
          ip -n internet link set veth-net up
          ip -n internet link set lo up
          ip -n internet addr add 10.99.0.10/32 dev lo
          ip -n internet route add default via 203.0.113.1
        '';
      };

      systemd.services.test-upstream = {
        wantedBy = [ "multi-user.target" ];
        after = [ "test-internet.service" ];
        requires = [ "test-internet.service" ];
        serviceConfig = {
          NetworkNamespacePath = "/run/netns/internet";
          ExecStart = "${upstream}/bin/test-upstream --certs ${certs} --log /tmp/upstream.log --http 80 8080 --https 443 8443";
        };
      };

      # Answers on the host's own addresses (loopback, LAN, link-local), which the proxy must not
      # reach: the positive control that these servers are up when it fails.
      systemd.services.test-local = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${upstream}/bin/test-upstream --log /tmp/local.log --http 80";
      };

      networking.hosts = {
        "203.0.113.10" = [
          "ok.test"
          "secure.test"
          "other.test"
          "wrong.test"
          "rogue.test"
          "port.test"
          "sub.wild.test"
          "wild.test"
        ];
        "10.99.0.10" = [ "priv.test" ];
        "127.0.0.1" = [ "loop.test" ];
        "169.254.169.254" = [ "meta.test" ];
        "${config.networking.primaryIPAddress}" = [ "lan.test" ];
      };

      systemd.services.test-link-local = {
        wantedBy = [ "multi-user.target" ];
        before = [ "test-local.service" ];
        path = [ pkgs.iproute2 ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = "ip addr add 169.254.169.254/32 dev lo";
      };

      # a-box-proxy@ stops when nothing needs it, so a started one needs a holder.
      systemd.targets.a-box-test-proxies.wants = [
        "a-box-proxy@1.service"
        "a-box-proxy@2.service"
      ];
    };

  testScript = ''
    TEST_CA_KEY = "${../proxy-ca.sec}"
    TEST_CA = "${../proxy-ca.crt}"
    UPSTREAM_CA = "${certs}/a-box-test-ca.crt"
    ROGUE_CA = "${certs}/a-box-rogue-ca.crt"

    import json
    import shlex

    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("test-upstream.service")
    machine.wait_for_unit("test-local.service")
  ''
  + builtins.readFile ./proxy.py;
}
