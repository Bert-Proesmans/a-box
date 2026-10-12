# tests/guests

| File | Description |
| --- | --- |
| `default.nix` | Attrset of the guest VM tests, one attribute per test (`units`); `pkgs` and `guest` are threaded in from the repo root |
| `proxy.nix` | The `a-box-proxy` VM test: a node with the guests and proxy modules, a fake internet in a network namespace (http and https servers, a trusted and a rogue CA), the test proxy CA and its key, and the policy of two instances, running `proxy.py` |
| `proxy.py` | Test script: allowlisted https is intercepted with the proxy CA's certificate and plain http forwarded, everything else is blocked and logged, injected headers replace the guest's and stay out of the journal, upstream certificates are verified, event streams are not buffered, loopback and private destinations are refused, instances cannot reach each other's socket or port, bad CA keys and credentials stop the start, and instances beyond `max` do not start |
| `upstream.py` | Test helper run on the fake internet: echoes each request on http and https (certificate picked by SNI), streams `/sse`, logs every request it receives |
| `client.py` | Test helper run as the guest's user: one request through the proxy's unix socket, absolute-URI for http or `CONNECT` plus TLS verified against one CA for https, printed as JSON |
| `units.nix` | The `a-box-guests-units` VM test: a node with the guests module and a stand-in proxy, a stub console feeder and a test guest image, running `logger.py` then `guest.py` |
| `logger.py` | Test script: the console logger timestamps, sanitises and rotates the stream into files only it can reach, and flushes the last line when the console ends |
| `guest.py` | Test script: a Firecracker guest boots on nested KVM, its console is recorded, it reaches the proxy over vsock, and stopping it tears down proxy, logger and sockets |
| `proxy-stub.nix` | Test-node module standing in for the real proxy: answers each connection on the guest's vsock 3128 socket with the request line it received |
| `init.sh` | PID 1 of the test guest: the stub image init plus a background job that fetches through the host proxy over vsock |
