{
  sources ? (import ../../lon.nix),
  pkgs ? (import sources.nixpkgs { system = "x86_64-linux"; }),
}:
{
  devshell = import ./devshell.nix { inherit pkgs; };
  host-package = import ./host-package.nix { inherit pkgs; };
  guest-init = import ./guest-init.nix { inherit pkgs; };
  bpf = import ./bpf.nix { inherit pkgs; };
}
