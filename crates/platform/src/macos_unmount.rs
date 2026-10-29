//! #1260：用户推出照片库所在的卷之前先问我们（DiskArbitration 卸载审批回调）。
//!
//! 系统在卸载一个卷之前，按登记顺序问每个审批方；回调返回 NULL = 放行，返回 dissenter = 拒绝。
//! 我们只放行，不拒绝：回调里先让 daemon 收手（取消在途传输、等库盘上的文件关掉，见调用方的
//! `prepare`），再放行——推出就不会因为我们「磁盘正在使用」。Time Machine、Spotlight 同款机制。

use std::ffi::c_void;
use std::path::{Path, PathBuf};
use std::ptr::NonNull;

use objc2_core_foundation::{CFRunLoop, CFURL};
use objc2_disk_arbitration::{
    kDADiskDescriptionVolumePathKey, DADisk, DADissenter, DARegisterDiskUnmountApprovalCallback,
    DASession,
};

struct Approval {
    mount_point: PathBuf,
    prepare: Box<dyn Fn() + Send + Sync>,
}

/// `root` 所在卷的挂载点（`statfs` 的 `f_mntonname`）。
pub(crate) fn mount_point_of(root: &Path) -> Option<PathBuf> {
    use std::ffi::{CStr, CString};
    use std::os::unix::ffi::OsStrExt;
    let c = CString::new(root.as_os_str().as_bytes()).ok()?;
    let mut st: libc::statfs = unsafe { std::mem::zeroed() };
    // SAFETY: c 是合法的 C 字符串，st 是可写的 statfs。
    if unsafe { libc::statfs(c.as_ptr(), &mut st) } != 0 {
        return None;
    }
    // SAFETY: f_mntonname 是以 NUL 结尾的定长字符数组。
    let name = unsafe { CStr::from_ptr(st.f_mntonname.as_ptr()) };
    Some(PathBuf::from(std::ffi::OsStr::from_bytes(name.to_bytes())))
}

fn volume_path(disk: &DADisk) -> Option<PathBuf> {
    // SAFETY: description() 返回带引用计数的字典；键是框架导出的常量。
    let desc = unsafe { disk.description() }?;
    let key: &objc2_core_foundation::CFString = unsafe { kDADiskDescriptionVolumePathKey };
    // SAFETY: 卷路径键对应的值是 CFURL（DiskArbitration 文档约定）；只借用，不转移所有权。
    let value = unsafe { desc.value((key as *const objc2_core_foundation::CFString).cast()) };
    let url = NonNull::new(value as *mut CFURL)?;
    unsafe { url.as_ref() }.to_file_path()
}

unsafe extern "C-unwind" fn on_unmount(
    disk: NonNull<DADisk>,
    context: *mut c_void,
) -> *const DADissenter {
    // SAFETY: context 是 watch() 里 Box::into_raw 出来、永不释放的 Approval。
    let approval = unsafe { &*(context as *const Approval) };
    // SAFETY: 系统保证回调期间 disk 有效。
    if volume_path(unsafe { disk.as_ref() }).as_deref() == Some(approval.mount_point.as_path()) {
        (approval.prepare)();
    }
    std::ptr::null()
}

/// 登记审批回调并在专门的线程上跑 RunLoop。登记不上返回 false。
pub(crate) fn watch(root: &Path, prepare: Box<dyn Fn() + Send + Sync>) -> bool {
    let Some(mount_point) = mount_point_of(root) else {
        return false;
    };
    let (tx, rx) = std::sync::mpsc::channel();
    let spawned = std::thread::Builder::new()
        .name("ppf-unmount-approval".into())
        .spawn(move || {
            // SAFETY: 默认分配器。
            let Some(session) = (unsafe { DASession::new(None) }) else {
                let _ = tx.send(false);
                return;
            };
            let context = Box::into_raw(Box::new(Approval {
                mount_point,
                prepare,
            }));
            // SAFETY: 回调签名与框架一致；context 在进程生命周期内有效。
            unsafe {
                DARegisterDiskUnmountApprovalCallback(
                    &session,
                    None,
                    Some(on_unmount),
                    context.cast(),
                );
            }
            let Some(run_loop) = CFRunLoop::current() else {
                let _ = tx.send(false);
                return;
            };
            // SAFETY: 默认模式常量由框架导出。
            let Some(mode) = (unsafe { objc2_core_foundation::kCFRunLoopDefaultMode }) else {
                let _ = tx.send(false);
                return;
            };
            unsafe { session.schedule_with_run_loop(&run_loop, mode) };
            let _ = tx.send(true);
            CFRunLoop::run();
        });
    spawned.is_ok() && rx.recv().unwrap_or(false)
}
