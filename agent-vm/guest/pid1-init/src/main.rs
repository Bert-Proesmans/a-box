use std::fs::OpenOptions;
use std::thread;
use std::time::Duration;

use pid1_init::mount::{mount_pseudo_filesystems, SyscallMounter};
use pid1_init::write_liveness;

fn main() {
    mount_pseudo_filesystems(&SyscallMounter).expect("failed to mount pseudo filesystems");

    let console = OpenOptions::new()
        .write(true)
        .open("/dev/console")
        .expect("failed to open /dev/console");
    write_liveness(console).expect("failed to write liveness line");

    // Nothing more to do at this stage (chunk C wires up a real agent);
    // park forever rather than exiting, since pid1 exiting panics the
    // kernel.
    loop {
        thread::sleep(Duration::from_secs(3600));
    }
}
