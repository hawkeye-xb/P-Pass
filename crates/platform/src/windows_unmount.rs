//! #1260：Windows 上盯住照片库所在的卷——用户「安全删除硬件」/ 推出之前先问我们，卷真的
//! 拔掉后告诉我们。
//!
//! 标准做法：对库目录打开一个句柄，`RegisterDeviceNotificationW(DBT_DEVTYP_HANDLE)` 登记到一个
//! 只收消息的隐藏窗口（服务与普通进程都能用窗口句柄接收，见 RegisterDeviceNotification 文档）：
//! - `DBT_DEVICEQUERYREMOVE`：有人要卸载这个卷——先调 `on_query`（收手），再**只关**我们自己的句柄
//!   （不然系统会因为它拒绝卸载；登记保留，等 REMOVECOMPLETE 再注销——微软标准做法），返回 TRUE 放行；
//! - `DBT_DEVICEQUERYREMOVEFAILED`：卸载被别人挡住了——重新打开句柄、重新登记，继续盯；
//! - `DBT_DEVICEREMOVECOMPLETE`：卷已经没了——注销登记，调 `on_gone`。
//!
//! #1260：资源管理器「弹出」外接盘（含 VHD）**不走 PnP 的 query-remove**，实测顺序是
//! `DBT_CUSTOMEVENT`：`GUID_IO_VOLUME_LOCK` → `LOCK_FAILED` → `MOUNT` → `UNLOCK`，随后
//! `DBT_DEVICEREMOVECOMPLETE`。所以 LOCK 当作「要卸载」处理（同样先 `on_query` 再只关句柄），
//! `LOCK_FAILED` / `UNLOCK` 时卷还在就重新打开句柄并重新登记。

use std::ffi::c_void;
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::ptr::null_mut;

use windows_sys::core::GUID;
use windows_sys::Win32::Foundation::{
    CloseHandle, HANDLE, HWND, INVALID_HANDLE_VALUE, LPARAM, LRESULT, WPARAM,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_FLAG_BACKUP_SEMANTICS, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
    OPEN_EXISTING,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, GetMessageW, GetWindowLongPtrW,
    RegisterClassW, RegisterDeviceNotificationW, SetWindowLongPtrW, TranslateMessage,
    UnregisterDeviceNotification, DBT_CUSTOMEVENT, DBT_DEVICEQUERYREMOVE,
    DBT_DEVICEQUERYREMOVEFAILED, DBT_DEVICEREMOVECOMPLETE, DBT_DEVTYP_HANDLE,
    DEVICE_NOTIFY_WINDOW_HANDLE, DEV_BROADCAST_HANDLE, GUID_IO_VOLUME_LOCK,
    GUID_IO_VOLUME_LOCK_FAILED, GUID_IO_VOLUME_UNLOCK, GWLP_USERDATA, HDEVNOTIFY, HWND_MESSAGE,
    MSG, WM_DEVICECHANGE, WNDCLASSW,
};

/// 收到「要卸载」与「已拔掉」时各做什么。
pub(crate) struct Hooks {
    pub on_query: Option<Box<dyn Fn() + Send + Sync>>,
    pub on_gone: Option<Box<dyn Fn() + Send + Sync>>,
}

struct State {
    root: PathBuf,
    dir: HANDLE,
    notify: HDEVNOTIFY,
    hooks: Hooks,
}

fn wide(p: &Path) -> Vec<u16> {
    p.as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

fn open_dir(root: &Path) -> HANDLE {
    let w = wide(root);
    // SAFETY: w 以 0 结尾；只为收设备通知打开目录（不读写内容）。
    unsafe {
        CreateFileW(
            w.as_ptr(),
            0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            null_mut(),
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS,
            null_mut(),
        )
    }
}

fn register(hwnd: HWND, dir: HANDLE) -> HDEVNOTIFY {
    let mut filter: DEV_BROADCAST_HANDLE = unsafe { std::mem::zeroed() };
    filter.dbch_size = std::mem::size_of::<DEV_BROADCAST_HANDLE>() as u32;
    filter.dbch_devicetype = DBT_DEVTYP_HANDLE;
    filter.dbch_handle = dir;
    // SAFETY: filter 是按文档填好的 DEV_BROADCAST_HANDLE；hwnd 是本线程的消息窗口。
    unsafe {
        RegisterDeviceNotificationW(
            hwnd,
            (&filter as *const DEV_BROADCAST_HANDLE).cast::<c_void>(),
            DEVICE_NOTIFY_WINDOW_HANDLE,
        )
    }
}

/// 只关目录句柄（登记保留）：LOCK / QUERYREMOVE 时给系统让路。
fn close_dir(state: &mut State) {
    // SAFETY: 句柄由本模块打开；关过就置空，不会重复关。
    unsafe {
        if state.dir != INVALID_HANDLE_VALUE && !state.dir.is_null() {
            CloseHandle(state.dir);
        }
    }
    state.dir = INVALID_HANDLE_VALUE;
}

/// 注销登记（REMOVECOMPLETE 或重新登记之前）。
fn unregister(state: &mut State) {
    // SAFETY: 登记由本模块做；注销过就置空。
    unsafe {
        if !state.notify.is_null() {
            UnregisterDeviceNotification(state.notify);
        }
    }
    state.notify = null_mut();
}

fn release(state: &mut State) {
    unregister(state);
    close_dir(state);
}

/// 卷还在就重新打开句柄、重新登记，返回是否重新盯上了。已经盯着（句柄在）就什么也不做。
fn reopen(hwnd: HWND, state: &mut State) -> bool {
    if state.dir != INVALID_HANDLE_VALUE && !state.dir.is_null() {
        return false;
    }
    let dir = open_dir(&state.root);
    if dir == INVALID_HANDLE_VALUE {
        return false; // 卷已经没了：保留原登记，等 REMOVECOMPLETE。
    }
    let notify = register(hwnd, dir);
    if notify.is_null() {
        // SAFETY: dir 刚打开、没有别处持有。
        unsafe { CloseHandle(dir) };
        return false;
    }
    unregister(state);
    state.dir = dir;
    state.notify = notify;
    true
}

/// `DBT_CUSTOMEVENT` 里我们关心的卷事件。
#[derive(Debug, PartialEq, Eq)]
enum VolumeEvent {
    Lock,
    LockFailed,
    Unlock,
    Other,
}

fn same(a: &GUID, b: &GUID) -> bool {
    (a.data1, a.data2, a.data3, a.data4) == (b.data1, b.data2, b.data3, b.data4)
}

fn classify_guid(g: &GUID) -> VolumeEvent {
    if same(g, &GUID_IO_VOLUME_LOCK) {
        VolumeEvent::Lock
    } else if same(g, &GUID_IO_VOLUME_LOCK_FAILED) {
        VolumeEvent::LockFailed
    } else if same(g, &GUID_IO_VOLUME_UNLOCK) {
        VolumeEvent::Unlock
    } else {
        VolumeEvent::Other
    }
}

/// 从 `DEV_BROADCAST_HANDLE` 读 `dbch_eventguid`。偏移用 `offset_of!`（x64 上句柄是 8 字节对齐，
/// 手算 `4+4+4+8+8` 会读歪）；先核对大小与设备类型，不是句柄类型的广播一律当 Other。
///
/// # Safety
/// `lparam` 必须是系统随 `WM_DEVICECHANGE` 给的广播指针（或 0）。
unsafe fn read_event(lparam: LPARAM) -> VolumeEvent {
    let p = lparam as *const u8;
    if p.is_null() {
        return VolumeEvent::Other;
    }
    // SAFETY: 头三个 u32（size / devicetype / reserved）所有 DEV_BROADCAST_* 都有。
    let (size, devtype) = unsafe {
        (
            std::ptr::read_unaligned(p.cast::<u32>()),
            std::ptr::read_unaligned(p.add(4).cast::<u32>()),
        )
    };
    let guid_end =
        std::mem::offset_of!(DEV_BROADCAST_HANDLE, dbch_eventguid) + std::mem::size_of::<GUID>();
    if devtype != DBT_DEVTYP_HANDLE || (size as usize) < guid_end {
        return VolumeEvent::Other;
    }
    // SAFETY: size 已核对覆盖 dbch_eventguid。
    let g = unsafe {
        std::ptr::read_unaligned(
            p.add(std::mem::offset_of!(DEV_BROADCAST_HANDLE, dbch_eventguid))
                .cast::<GUID>(),
        )
    };
    classify_guid(&g)
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if msg == WM_DEVICECHANGE {
        // SAFETY: GWLP_USERDATA 里是 watch() 放进去、与窗口同寿命的 State。
        let state = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) } as *mut State;
        if let Some(state) = unsafe { state.as_mut() } {
            match wparam as u32 {
                DBT_DEVICEQUERYREMOVE => {
                    if let Some(f) = &state.hooks.on_query {
                        f();
                    }
                    // 只关句柄：登记留着，REMOVECOMPLETE 才收得到（根目录监听靠它）。
                    close_dir(state);
                    return 1; // TRUE：放行，从不拒绝用户的推出。
                }
                DBT_DEVICEQUERYREMOVEFAILED => {
                    reopen(hwnd, state);
                }
                DBT_CUSTOMEVENT => {
                    // SAFETY: lparam 是系统给的广播指针。
                    match unsafe { read_event(lparam) } {
                        VolumeEvent::Lock => {
                            tracing::info!(
                                "#1260: 卷被锁定（资源管理器推出 / 格式化等）——先松开照片库的句柄"
                            );
                            if let Some(f) = &state.hooks.on_query {
                                f();
                            }
                            close_dir(state);
                        }
                        VolumeEvent::LockFailed | VolumeEvent::Unlock => {
                            if reopen(hwnd, state) {
                                tracing::info!(
                                    "#1260: 卷锁定没成（卷还在）——重新打开照片库的句柄继续盯"
                                );
                            }
                        }
                        VolumeEvent::Other => {}
                    }
                }
                DBT_DEVICEREMOVECOMPLETE => {
                    tracing::info!("#1260: 照片库所在的卷已移除");
                    release(state);
                    if let Some(f) = &state.hooks.on_gone {
                        f();
                    }
                }
                _ => {}
            }
        }
        return 1;
    }
    // SAFETY: 其余消息交给系统默认处理。
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}

/// 在专门的线程上建消息窗口、登记通知并跑消息循环。登记不上返回 false。
pub(crate) fn watch(root: &Path, hooks: Hooks) -> bool {
    let root = root.to_path_buf();
    let (tx, rx) = std::sync::mpsc::channel();
    let spawned = std::thread::Builder::new()
        .name("ppf-volume-notify".into())
        .spawn(move || {
            let dir = open_dir(&root);
            if dir == INVALID_HANDLE_VALUE {
                let _ = tx.send(false);
                return;
            }
            let class: Vec<u16> = "PPassVolumeNotify"
                .encode_utf16()
                .chain(std::iter::once(0))
                .collect();
            let wc = WNDCLASSW {
                style: 0,
                lpfnWndProc: Some(wndproc),
                cbClsExtra: 0,
                cbWndExtra: 0,
                hInstance: null_mut(),
                hIcon: null_mut(),
                hCursor: null_mut(),
                hbrBackground: null_mut(),
                lpszMenuName: std::ptr::null(),
                lpszClassName: class.as_ptr(),
            };
            // SAFETY: wc 填好了窗口过程与类名；重复登记同名类会失败但不影响已登记的类。
            unsafe { RegisterClassW(&wc) };
            // SAFETY: HWND_MESSAGE = 只收消息、不显示的窗口。
            let hwnd = unsafe {
                CreateWindowExW(
                    0,
                    class.as_ptr(),
                    class.as_ptr(),
                    0,
                    0,
                    0,
                    0,
                    0,
                    HWND_MESSAGE,
                    null_mut(),
                    null_mut(),
                    std::ptr::null(),
                )
            };
            if hwnd.is_null() {
                unsafe { CloseHandle(dir) };
                let _ = tx.send(false);
                return;
            }
            let notify = register(hwnd, dir);
            if notify.is_null() {
                unsafe { CloseHandle(dir) };
                let _ = tx.send(false);
                return;
            }
            let state = Box::into_raw(Box::new(State {
                root,
                dir,
                notify,
                hooks,
            }));
            // SAFETY: State 与窗口同寿命（线程跑到进程结束）。
            unsafe { SetWindowLongPtrW(hwnd, GWLP_USERDATA, state as isize) };
            let _ = tx.send(true);
            let mut msg: MSG = unsafe { std::mem::zeroed() };
            // SAFETY: 标准消息循环。
            while unsafe { GetMessageW(&mut msg, null_mut(), 0, 0) } > 0 {
                unsafe {
                    TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            }
        });
    spawned.is_ok() && rx.recv().unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn broadcast(devtype: u32, guid: GUID) -> DEV_BROADCAST_HANDLE {
        let mut b: DEV_BROADCAST_HANDLE = unsafe { std::mem::zeroed() };
        b.dbch_size = std::mem::size_of::<DEV_BROADCAST_HANDLE>() as u32;
        b.dbch_devicetype = devtype;
        b.dbch_eventguid = guid;
        b
    }

    fn read(b: &DEV_BROADCAST_HANDLE) -> VolumeEvent {
        unsafe { read_event(b as *const _ as LPARAM) }
    }

    #[test]
    fn x64_上_eventguid_在_32_字节处() {
        // 4+4+4 填充到 16，句柄 8、hdevnotify 8 → 32；算成 28（忽略对齐）就会读歪。
        #[cfg(target_pointer_width = "64")]
        assert_eq!(
            std::mem::offset_of!(DEV_BROADCAST_HANDLE, dbch_eventguid),
            32
        );
    }

    #[test]
    fn 认得三种卷事件() {
        assert_eq!(
            read(&broadcast(DBT_DEVTYP_HANDLE, GUID_IO_VOLUME_LOCK)),
            VolumeEvent::Lock
        );
        assert_eq!(
            read(&broadcast(DBT_DEVTYP_HANDLE, GUID_IO_VOLUME_LOCK_FAILED)),
            VolumeEvent::LockFailed
        );
        assert_eq!(
            read(&broadcast(DBT_DEVTYP_HANDLE, GUID_IO_VOLUME_UNLOCK)),
            VolumeEvent::Unlock
        );
    }

    #[test]
    fn 别的事件_类型不对_广播太短_空指针都当_other() {
        use windows_sys::Win32::UI::WindowsAndMessaging::GUID_IO_VOLUME_MOUNT;
        assert_eq!(
            read(&broadcast(DBT_DEVTYP_HANDLE, GUID_IO_VOLUME_MOUNT)),
            VolumeEvent::Other
        );
        // 设备类型不是 HANDLE：就算偏移处碰巧是 LOCK 的 GUID 也不认。
        assert_eq!(read(&broadcast(0, GUID_IO_VOLUME_LOCK)), VolumeEvent::Other);
        let mut short = broadcast(DBT_DEVTYP_HANDLE, GUID_IO_VOLUME_LOCK);
        short.dbch_size = 16;
        assert_eq!(read(&short), VolumeEvent::Other);
        assert_eq!(unsafe { read_event(0) }, VolumeEvent::Other);
    }
}
