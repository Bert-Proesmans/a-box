{
  runCommand,
  writeText,

  uki,
  netboot,

  # URL boot.ipxe chains to. Relative resolves against boot.ipxe's own URL.
  ukiUrl ? "a-box-updater.efi",
}:
runCommand "a-box-updater-netboot"
  {
    # As served by the a-box GitHub release. Absolute: GitHub redirects downloads, and iPXE resolves
    # relative URLs against the redirect target.
    passthru.githubRelease = netboot.override {
      ukiUrl = "https://github.com/Bert-Proesmans/a-box/releases/latest/download/a-box-updater.efi";
    };
  }
  ''
    mkdir $out
    cp ${uki} $out/a-box-updater.efi
    cp ${writeText "boot.ipxe" ''
      #!ipxe
      # UEFI iPXE only.
      chain ${ukiUrl}
    ''} $out/boot.ipxe
  ''
