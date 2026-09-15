{
  sources ? (import ../../lon.nix),
  pkgs ? (import sources.nixpkgs { system = "x86_64-linux"; }),
}:
let
  guest-kernel = import ./guest-kernel.nix { inherit pkgs; };
  device1-v0 = import ./device1-v0.nix { inherit pkgs; };
in
{
  devshell = import ./devshell.nix { inherit pkgs; };
  host-package = import ./host-package.nix { inherit pkgs; };
  guest-init = import ./guest-init.nix { inherit pkgs; };
  bpf = import ./bpf.nix { inherit pkgs; };
  inherit guest-kernel device1-v0;
  guest-kernel-check = import ./guest-kernel-check.nix { inherit pkgs; kernel = guest-kernel; };
  device1-v0-check = import ./device1-v0-check.nix { inherit pkgs device1-v0; };
}
