use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

use nix::sys::socket::{accept, bind, listen, socket, AddressFamily, Backlog, SockFlag, SockType, VsockAddr};

/// Binds to any local CID - the guest doesn't need to know or care about
/// its own host-assigned CID, only the port (see Linux vsock(7):
/// VMADDR_CID_ANY is valid for bind()).
const VMADDR_CID_ANY: u32 = u32::MAX;

/// A bound, listening AF_VSOCK socket. Firecracker gives the guest side a
/// real kernel AF_VSOCK socket (only the host side is a Unix-domain-socket
/// proxy - confirmed against firecracker's own docs/vsock.md).
pub struct VsockListener {
    fd: OwnedFd,
}

impl VsockListener {
    pub fn bind(port: u32) -> io::Result<Self> {
        let fd = socket(AddressFamily::Vsock, SockType::Stream, SockFlag::empty(), None)?;
        let addr = VsockAddr::new(VMADDR_CID_ANY, port);
        bind(fd.as_raw_fd(), &addr)?;
        listen(&fd, Backlog::MAXCONN)?;
        Ok(Self { fd })
    }

    /// Blocks until one peer connects, returning the accepted connection.
    pub fn accept(&self) -> io::Result<OwnedFd> {
        let raw = accept(self.fd.as_raw_fd())?;
        // SAFETY: `accept` just returned a freshly opened fd this call
        // uniquely owns - nothing else has or will touch it.
        Ok(unsafe { OwnedFd::from_raw_fd(raw) })
    }
}
