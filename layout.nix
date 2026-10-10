# GPT partition names that main system and updater agree on: the ESP (FAT) holding the main
# bootloader, kernels and initrds, and the root (ext4) holding the main system's /nix.
{
  espLabel = "a-box-esp";
  rootLabel = "a-box-root";
}
