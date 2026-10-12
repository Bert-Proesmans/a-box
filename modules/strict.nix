# Build-time shellcheck of the scripts this system generates. Upstream units that fail get a
# per-unit opt-out next to the reason, never a weaker global setting.
{
  # Covers `script`, `preStart`, ... of every NixOS-defined unit; initrd units inherit it
  # (no separate initrd option exists in this nixpkgs).
  systemd.enableStrictShellChecks = true;

  disko.checkScripts = true;
}
