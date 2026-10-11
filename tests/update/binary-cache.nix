# Generations 1 and 2 published with the real `a-box-stage` and `a-box-upload`: signed with the
# test key, zstd-compressed. pointer-N is what publishing generation N writes to the pointer file.
{
  lib,
  callPackage,
  runCommand,
  closureInfo,
  nix,
  generations,
}:
let
  publish = callPackage ../../publish { };
  toplevels = map (n: generations.${n}) [
    "1"
    "2"
  ];
in
runCommand "a-box-test-cache"
  {
    nativeBuildInputs = [
      nix
      publish.stage
      publish.upload
    ];
    closure = closureInfo { rootPaths = toplevels; };
  }
  ''
    # a-box-stage reads closures from the nix database. The sandbox has none: register the
    # generations' closures in a private one.
    export HOME=$TMPDIR NIX_STATE_DIR=$TMPDIR/nix
    nix-store --load-db < $closure/registration

    ${lib.concatImapStrings (n: toplevel: ''
      A_BOX_SIGNING_KEY=${../cache-key.sec} \
      A_BOX_UPSTREAM= \
        a-box-stage ${toplevel} stage-${toString n}

      A_BOX_CACHE_DEST=$out/nix-cache \
      A_BOX_POINTER_DEST=$out/pointer-${toString n} \
        a-box-upload stage-${toString n}

    '') toplevels}
  ''
