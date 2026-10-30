//! #1260：Windows 上盯住照片库所在的卷——用户「安全删除硬件」/ 推出之前先问我们，卷真的
//! 拔掉后告诉我们。
//!
//! 标准做法：对库目录打开一个句柄，`RegisterDeviceNotificationW(DBT_DEVTYP_HANDLE)` 登记到一个
//! 只收消息的隐藏窗口（服务与普通进程都能用窗口句柄接收，见 RegisterDeviceNotification 文档）：
//! - `DBT_DEVICEQUERYREMOVE`：有人要卸载这个卷——先调 `on_query`（收手），再关掉我们自己的句柄
//!   （不然系统会因为它拒绝卸载），返回 TRUE 放行；
//! - `DBT_DEVICEQUERYREMOVEFAILED`：卸载被别人挡住了——重新打开句柄、重新登记，继续盯；
//! - `DBT_DEVICEREMOVECOMPLETE`：卷已经没了——调 `on_gone`。

use std::ffi::c_void;
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::ptr::null_mut;

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
    UnregisterDeviceNotification, DBT_DEVICEQUERYREMOVE, DBT_DEVICEQUERYREMOVEFAILED,
    DBT_DEVICEREMOVECOMPLETE, DBT_DEVTYP_HANDLE, DEVICE_NOTIFY_WINDOW_HANDLE, DEV_BROADCAST_HANDLE,
    GWLP_USERDATA, HDEVNOTIFY, HWND_MESSAGE, MSG, WM_DEVICECHANGE, WNDCLASSW,
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

fn release(state: &mut State) {
    // SAFETY: 两个句柄都由本模块打开 / 登记；关过就置空，不会重复关。
    unsafe {
        if !state.notify.is_null() {
            UnregisterDeviceNotification(state.notify);
            state.notify = null_mut();
        }
        if state.dir != INVALID_HANDLE_VALUE && !state.dir.is_null() {
            CloseHandle(state.dir);
            state.dir = INVALID_HANDLE_VALUE;
        }
    }
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
                    release(state);
                    return 1; // TRUE：放行，从不拒绝用户的推出。
                }
                DBT_DEVICEQUERYREMOVEFAILED => {
                    release(state);
                    state.dir = open_dir(&state.root);
                    if state.dir != INVALID_HANDLE_VALUE {
                        state.notify = register(hwnd, state.dir);
                    }
                }
                DBT_DEVICEREMOVECOMPLETE => {
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
