use std::fs::OpenOptions;
use std::thread;
use std::time::Duration;

use pid1_init::mount::{mount_pseudo_filesystems, SyscallMounter};
use pid1_init::ports::STDIO_PORT;
use pid1_init::spawn::{spawn_agent, SyscallSpawner};
use pid1_init::vsock::VsockListener;
use pid1_init::write_liveness;

fn main() {
    mount_pseudo_filesystems(&SyscallMounter).expect("failed to mount pseudo filesystems");

    let console = OpenOptions::new()
        .write(true)
        .open("/dev/console")
        .expect("failed to open /dev/console");
    write_liveness(console).expect("failed to write liveness line");

    // Bound/accepted after the liveness write (not before): B4's boot
    // test only watches the console for that string and never connects
    // over vsock, so it must not depend on a host peer showing up.
    let listener = VsockListener::bind(STDIO_PORT).expect("failed to bind stdio vsock listener");
    let conn = listener.accept().expect("failed to accept stdio vsock connection");
    spawn_agent(&SyscallSpawner, conn).expect("failed to spawn agent");

    // The agent runs as a child, not an exec target (chunk H5 changes
    // that); pid1 parks rather than exiting, since pid1 exiting panics
    // the kernel.
    loop {
        thread::sleep(Duration::from_secs(3600));
    }
}
