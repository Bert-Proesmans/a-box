# NixOS module declaring `a-box` options shared by the main system and its embedded updater:
# pointerUrl, substituters, trustedPublicKeys, keepGenerations (default 2) and updaterModules.
# Also defines a read-only `layout` with the ESP/root GPT labels and the updater UKI file name.

{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.a-box = {
    pointerUrl = mkOption {
      type = types.str;
      description = "URL of a text file holding the store path of the system toplevel to run.";
    };

    substituters = mkOption {
      type = types.listOf types.str;
      description = "Binary caches the updater downloads the system from.";
    };

    trustedPublicKeys = mkOption {
      type = types.listOf types.str;
      description = "Keys whose signatures the updater accepts on downloaded paths.";
    };

    keepGenerations = mkOption {
      type = types.ints.positive;
      default = 2;
      description = "System generations kept on disk and in the boot menu; older ones are garbage collected.";
    };

    updaterModules = mkOption {
      type = types.listOf types.deferredModule;
      default = [ ];
      description = "Extra NixOS modules for the updater, e.g. NIC drivers or kernel parameters for the hardware.";
    };

    # Disk layout contract between the install image, the updater and the main system.
    layout = mkOption {
      readOnly = true;
      default = {
        espLabel = "a-box-esp";
        rootLabel = "a-box-root";
        updaterFile = "a-box-updater.efi";
      };
      description = "GPT partition labels and the updater UKI file name on the ESP.";
    };
  };
}
