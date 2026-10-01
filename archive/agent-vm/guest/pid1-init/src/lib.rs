// Testable pid1-init logic lands here (mount-option builders, etc.) -
// main.rs itself is hard to unit test since it's meant to run as pid 1.

pub mod mount;
pub mod ports;
pub mod spawn;
pub mod vsock;

use std::io::{self, Write};

/// Fixed liveness line pid1-init writes to /dev/console once boot-time
/// setup is done, so a host-side boot test can poll for it in the
/// captured console log without depending on kernel printk.
pub const LIVENESS_MESSAGE: &str = "pid1-init: alive\n";

/// Writes the liveness line to `writer` (in production, `/dev/console`
/// opened directly - no libc stdio buffering to worry about at this
/// stage). Takes a generic `Write` so it's testable against an in-memory
/// buffer instead of a real console device.
pub fn write_liveness(mut writer: impl Write) -> io::Result<()> {
    writer.write_all(LIVENESS_MESSAGE.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_exact_liveness_line() {
        let mut buf = Vec::new();
        write_liveness(&mut buf).unwrap();
        assert_eq!(buf, LIVENESS_MESSAGE.as_bytes());
    }
}
