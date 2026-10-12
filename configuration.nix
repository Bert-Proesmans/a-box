{ ... }:
{
  networking.hostName = "a-box";

  networking.useNetworkd = true;
  networking.useDHCP = true;

  # Key-only root login; the root fs is rebuilt every boot, so the keys live in the configuration.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDOs8kDMMm/QFeELt79EG9akdfX7dlfRuTezwVEqbPsM bert@B-PC"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILEeQ/KEIWbUKBc4bhZBUHsBB0yJVZmBuln8oSVrtcA5 bert@B-PC"
  ];

  # Declared users only; the root fs is rebuilt every boot.
  users.mutableUsers = false;

  # Host keys live in /persistent (modules/preservation.nix).
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  system.stateVersion = "26.11";
}
