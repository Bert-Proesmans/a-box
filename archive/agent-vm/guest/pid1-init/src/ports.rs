// vsock port assignments shared across every chunk that talks to a
// session's guest over AF_VSOCK. Mirrored on the host side in
// agent-vm/host/src/agentvm/ports.py (chunk C2) - keep both in sync.

/// Interactive stdin/stdout channel (chunk C).
pub const STDIO_PORT: u32 = 10000;

/// HTTP(S) proxy shim, guest -> host (chunk F).
pub const PROXY_PORT: u32 = 10001;

/// eBPF event export, guest -> host (chunk G).
pub const BPF_PORT: u32 = 10002;
