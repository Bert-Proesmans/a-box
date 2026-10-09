# Packages ./publish.sh as the `a-box-publish` shell application via writeShellApplication.
# Runtime inputs are coreutils, curl, findutils, gnused and rclone; nix comes from the host.

{
  writeShellApplication,
  coreutils,
  curl,
  findutils,
  gnused,
  rclone,
}:
writeShellApplication {
  name = "a-box-publish";
  # nix comes from the host, so it talks to the host's daemon and store.
  runtimeInputs = [
    coreutils
    curl
    findutils
    gnused
    rclone
  ];
  text = builtins.readFile ./publish.sh;
}
