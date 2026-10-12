{
  # Covers `script`, `preStart`, ... of every NixOS-defined unit; initrd units inherit it
  # (no separate initrd option exists in this nixpkgs).
  systemd.enableStrictShellChecks = true;

  disko.checkScripts = true;
}
