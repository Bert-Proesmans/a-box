use std::fs::File;
use std::io;
use std::os::fd::OwnedFd;
use std::process::{Child, Command, Stdio};

/// Guest-side path of chunk C1's stub agent. Chunk H5 replaces this exec
/// target with the real Claude Code CLI - `Spawner` is the abstraction
/// boundary that lets that swap happen without touching the wiring below.
pub const ECHO_AGENT_PATH: &str = "/bin/echo_agent";
pub const ECHO_AGENT_ARGS: &[&str] = &[];

/// Indirection over spawning a child process with its stdin/stdout/stderr
/// wired to a vsock connection fd, so the wiring in `main()` is
/// unit-testable without a real vsock connection or process (see
/// `FakeSpawner` in this module's tests) - same pattern as `mount::Mounter`.
pub trait Spawner {
    fn spawn(
        &self,
        program: &'static str,
        args: &'static [&'static str],
        stdio: OwnedFd,
    ) -> io::Result<Child>;
}

pub struct SyscallSpawner;

impl Spawner for SyscallSpawner {
    fn spawn(
        &self,
        program: &'static str,
        args: &'static [&'static str],
        stdio: OwnedFd,
    ) -> io::Result<Child> {
        // One vsock connection carries stdin+stdout+stderr, like a serial
        // console. `Stdio::from` takes ownership, so the fd is dup'd via
        // `File::try_clone` (safe, no pre_exec/unsafe needed) for the
        // first two streams and moved in directly for the third.
        let conn = File::from(stdio);
        let stdin = conn.try_clone()?;
        let stdout = conn.try_clone()?;

        Command::new(program)
            .args(args)
            .stdin(Stdio::from(stdin))
            .stdout(Stdio::from(stdout))
            .stderr(Stdio::from(conn))
            .spawn()
    }
}

/// Spawns chunk C1's stub agent with `stdio` wired to its stdin/stdout/stderr.
pub fn spawn_agent(spawner: &dyn Spawner, stdio: OwnedFd) -> io::Result<Child> {
    spawner.spawn(ECHO_AGENT_PATH, ECHO_AGENT_ARGS, stdio)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::os::fd::AsRawFd;

    #[derive(Default)]
    struct FakeSpawner {
        calls: RefCell<Vec<(&'static str, &'static [&'static str], i32)>>,
    }

    impl Spawner for FakeSpawner {
        fn spawn(
            &self,
            program: &'static str,
            args: &'static [&'static str],
            stdio: OwnedFd,
        ) -> io::Result<Child> {
            self.calls.borrow_mut().push((program, args, stdio.as_raw_fd()));
            // Never actually execs anything - the test only inspects `calls`.
            Err(io::Error::other("FakeSpawner never actually spawns"))
        }
    }

    #[test]
    fn spawn_agent_wires_the_given_fd_to_the_echo_agent_binary() {
        let spawner = FakeSpawner::default();
        let (r, w) = nix::unistd::pipe().expect("pipe");
        let expected_fd = r.as_raw_fd();

        let _ = spawn_agent(&spawner, r);
        drop(w);

        let calls = spawner.calls.borrow();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].0, ECHO_AGENT_PATH);
        assert_eq!(calls[0].1, ECHO_AGENT_ARGS);
        assert_eq!(calls[0].2, expected_fd);
    }
}
