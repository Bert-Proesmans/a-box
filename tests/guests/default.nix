{ pkgs, guest }:
{
  # Guest units that need Firecracker on nested KVM: console logger, guest lifecycle.
  units = import ./units.nix { inherit pkgs guest; };

  # The mitmproxy side on its own node, no Firecracker: policy, interception, credentials, SSRF guard.
  proxy = import ./proxy.nix { inherit pkgs guest; };
}
