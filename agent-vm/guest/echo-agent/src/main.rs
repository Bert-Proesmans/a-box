// Chunk C1 stub agent: echoes each line read on stdin back to stdout
// prefixed "echo: ". Gives chunk C2/C3's host-side tests something
// deterministic to assert against before the real Claude Code CLI lands
// (chunk H5).
use std::io::{self, BufRead, Write};

fn main() -> io::Result<()> {
    let stdin = io::stdin();
    let mut stdout = io::stdout();

    for line in stdin.lock().lines() {
        let line = line?;
        writeln!(stdout, "echo: {line}")?;
        stdout.flush()?;
    }

    Ok(())
}
