# Stands in for the real proxy (modules/guest-proxy.nix) where a test needs only that something
# serves a-box-proxy@n: answers every connection on the guest's vsock 3128 socket with the request
# line it received, over HTTP/1.0.
{ pkgs, ... }:
let
  answer = pkgs.writeShellScript "proxy-stub-answer" ''
    read -r line
    printf 'HTTP/1.0 200 OK\r\n\r\nproxy-stub saw: %s\n' "''${line%$'\r'}"
  '';
in
{
  systemd.services."a-box-proxy@".serviceConfig = {
    User = "a-box-proxy-%i";
    Group = "a-box-guest-%i";
    SuccessExitStatus = 143;
    ExecStart = "${pkgs.socat}/bin/socat UNIX-LISTEN:/run/a-box/guest-%i/vsock_3128,fork,mode=0666 EXEC:${answer}";
  };
}
