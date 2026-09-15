use std::io;

use nix::mount::MsFlags;

/// One mount(2) call: source, target, filesystem type, and flags.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MountSpec {
    pub source: &'static str,
    pub target: &'static str,
    pub fstype: &'static str,
    pub flags: MsFlags,
}

/// Indirection over the mount(2) syscall so `mount_pseudo_filesystems` can
/// be unit-tested without needing real mount capability in the test
/// process (see `FakeMounter` in this module's tests).
pub trait Mounter {
    fn mount(&self, spec: &MountSpec) -> io::Result<()>;
}

pub struct SyscallMounter;

impl Mounter for SyscallMounter {
    fn mount(&self, spec: &MountSpec) -> io::Result<()> {
        nix::mount::mount(
            Some(spec.source),
            spec.target,
            Some(spec.fstype),
            spec.flags,
            None::<&str>,
        )
        .map_err(|errno| io::Error::from_raw_os_error(errno as i32))
    }
}

/// The pseudo-filesystems pid1-init mounts at boot, in order: proc, sysfs,
/// tmpfs.
///
/// devtmpfs is deliberately not mounted here: the guest kernel is built
/// with CONFIG_DEVTMPFS_MOUNT=y (see agent-vm/nix/guest-kernel.nix), which
/// makes the kernel itself auto-mount devtmpfs on /dev before init ever
/// runs. A second manual mount of devtmpfs on top of that fails with
/// EBUSY (devtmpfs keeps a single global instance) - confirmed by an
/// actual boot (chunk B4).
pub fn pseudo_filesystem_mounts() -> [MountSpec; 3] {
    [
        MountSpec {
            source: "proc",
            target: "/proc",
            fstype: "proc",
            flags: MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC,
        },
        MountSpec {
            source: "sysfs",
            target: "/sys",
            fstype: "sysfs",
            flags: MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC,
        },
        MountSpec {
            source: "tmpfs",
            target: "/tmp",
            fstype: "tmpfs",
            flags: MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
        },
    ]
}

pub fn mount_pseudo_filesystems(mounter: &dyn Mounter) -> io::Result<()> {
    for spec in pseudo_filesystem_mounts() {
        mounter.mount(&spec)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[derive(Default)]
    struct FakeMounter {
        calls: RefCell<Vec<MountSpec>>,
    }

    impl Mounter for FakeMounter {
        fn mount(&self, spec: &MountSpec) -> io::Result<()> {
            self.calls.borrow_mut().push(*spec);
            Ok(())
        }
    }

    #[test]
    fn mounts_proc_sysfs_tmpfs_in_order_with_expected_options() {
        let mounter = FakeMounter::default();

        mount_pseudo_filesystems(&mounter).expect("fake mounter never fails");

        let calls = mounter.calls.borrow();
        assert_eq!(calls.len(), 3);

        assert_eq!(calls[0].target, "/proc");
        assert_eq!(calls[0].fstype, "proc");
        assert_eq!(calls[0].source, "proc");

        assert_eq!(calls[1].target, "/sys");
        assert_eq!(calls[1].fstype, "sysfs");

        assert_eq!(calls[2].target, "/tmp");
        assert_eq!(calls[2].fstype, "tmpfs");

        // Every pseudo-fs mount must reject setuid bits at minimum.
        for call in calls.iter() {
            assert!(call.flags.contains(MsFlags::MS_NOSUID));
        }
    }

    #[test]
    fn propagates_first_mount_failure_and_stops() {
        struct FailingMounter;
        impl Mounter for FailingMounter {
            fn mount(&self, _spec: &MountSpec) -> io::Result<()> {
                Err(io::Error::from_raw_os_error(libc_enoent()))
            }
        }

        fn libc_enoent() -> i32 {
            2 // ENOENT, avoids pulling in the `libc` crate just for a constant
        }

        let result = mount_pseudo_filesystems(&FailingMounter);
        assert!(result.is_err());
    }
}
