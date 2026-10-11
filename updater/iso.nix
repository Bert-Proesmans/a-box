{
  runCommand,
  xorriso,
  dosfstools,
  mtools,

  # File name of the image, and its ISO 9660 volume ID.
  name,
  volumeId,
  # UKI the image boots.
  uki,
}:
# UEFI-only hybrid image, bootable as a CD (El Torito) or as a disk (GPT). Its only content is an
# appended ESP holding the UKI at the removable-media path.
runCommand name
  {
    nativeBuildInputs = [
      xorriso
      dosfstools
      mtools
    ];
  }
  ''
    # FAT tables, the directory and cluster rounding fit in 5% plus 2 MiB on top of the UKI.
    kib=$(( $(stat -c %s ${uki}) / 1024 ))
    kib=$(( kib + kib / 20 + 2048 ))

    # Fixed volume ID; mtools and xorriso date entries from SOURCE_DATE_EPOCH. Reproducible.
    mkfs.vfat --invariant -i 12345678 -n EFIBOOT -C esp.img $kib
    mmd -i esp.img ::/EFI ::/EFI/BOOT
    mcopy -i esp.img ${uki} ::/EFI/BOOT/BOOTX64.EFI

    # The El Torito EFI entry and GPT partition 2 both cover the appended ESP.
    mkdir empty
    xorriso -as mkisofs -quiet -o $out -V ${volumeId} \
      -e --interval:appended_partition_2:all:: -no-emul-boot \
      -append_partition 2 0xef esp.img -appended_part_as_gpt \
      empty
  ''
