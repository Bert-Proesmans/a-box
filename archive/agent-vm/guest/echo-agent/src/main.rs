// Chunk C1 stub agent: echoes bytes read on stdin back to stdout
// byte-for-byte, unchanged. Gives chunk C2/C3's host-side tests something
// deterministic to assert against before the real Claude Code CLI lands
// (chunk H5).
//
// Raw read/write, not line-buffered: a line-based echo strips and
// reinserts newlines, which isn't byte-exact for CRLF or partial-line
// input. Flushing per read keeps this usable over a live connection
// instead of only echoing at EOF.
use std::io::{self, Read, Write};

fn main() -> io::Result<()> {
    let mut stdin = io::stdin();
    let mut stdout = io::stdout();
    let mut buf = [0u8; 4096];

    loop {
        let n = stdin.read(&mut buf)?;
        if n == 0 {
            break;
        }
        stdout.write_all(&buf[..n])?;
        stdout.flush()?;
    }

    Ok(())
}
