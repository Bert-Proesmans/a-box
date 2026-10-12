# tests

| File | Description |
| --- | --- |
| `update/` | NixOS VM tests of the updater and the volatile host it installs, one per scenario (network condition, fault, persistence); see [update/README.md](update/README.md) |
| `guests/` | NixOS VM tests of the guest units, one per attribute: console logger and a Firecracker guest on nested KVM; see [guests/README.md](guests/README.md) |
| `cache-key.pub` | Nix binary cache public signing key `a-box-test-1` |
| `cache-key.sec` | Nix binary cache secret signing key `a-box-test-1` |
| `proxy-ca.crt` | Test proxy CA certificate for the guests' proxy tests |
| `proxy-ca.sec` | Test proxy CA private key |
