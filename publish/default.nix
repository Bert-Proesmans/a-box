{
  writeShellApplication,
  coreutils,
  curl,
  findutils,
  rclone,
}:
{
  stage = writeShellApplication {
    name = "a-box-stage";
    # nix comes from the host, so it talks to the host's daemon and store.
    runtimeInputs = [
      coreutils
      curl
      findutils
    ];
    text = builtins.readFile ./stage.sh;
  };

  upload = writeShellApplication {
    name = "a-box-upload";
    runtimeInputs = [
      coreutils
      rclone
    ];
    text = builtins.readFile ./upload.sh;
  };
}
