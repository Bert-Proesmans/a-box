{
  runCommand,
  closureInfo,
  erofs-utils,
  openssl,
  init,
  tools,
  proxyCa,
}:
let
  closure = closureInfo {
    rootPaths = [
      init
      tools
    ];
  };
in
# An uncompressed, reproducible erofs image: the closure of `init` and `tools` under /nix/store,
# empty mountpoints, `/init`, `/bin` and the trust store (the proxy CA alone). The kernel mounts it
# read-only as /; init mounts tmpfs on the paths that must be writable.
runCommand "a-box-guest-rootfs.erofs"
  {
    nativeBuildInputs = [
      erofs-utils
      openssl
    ];
  }
  ''
    root=$PWD/root
    mkdir -p $root/nix/store
    xargs -a ${closure}/store-paths cp -a -t $root/nix/store

    mkdir $root/{dev,proc,sys,run,tmp,var,home,root}
    ln -s ${init} $root/init
    ln -s ${tools}/bin $root/bin

    # The proxy CA is the only trust root, under the names clients look for. A file that is not a CA
    # certificate fails the build instead of a guest that rejects every connection.
    openssl x509 -in ${proxyCa} -noout -text | grep -q 'CA:TRUE'
    mkdir -p $root/etc/ssl/certs
    install -m644 ${proxyCa} $root/etc/ssl/certs/ca-certificates.crt
    ln -s ca-certificates.crt $root/etc/ssl/certs/ca-bundle.crt
    ln -s certs/ca-certificates.crt $root/etc/ssl/cert.pem

    # Fixed block size, timestamp and UUID, no xattrs, root-owned: the same inputs give the same image.
    mkfs.erofs -b4096 -x-1 -T0 -U 00000000-0000-0000-0000-000000000000 -L a-box-guest \
      --all-root $out $root
  ''
