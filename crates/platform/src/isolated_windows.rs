//! `isolated` 的 Windows 实现：AppContainer + Job（见 `isolated.rs`）。
//!
//! - AppContainer：`CreateAppContainerProfile`（已存在则 Derive SID），不授任何
//!   capability，进程无网络、读不到用户文件 / ProgramData / 私钥。profile 在本进程
//!   内只建一次并缓存 SID。
//! - Job：关闭即杀、只许这一个进程、单进程内存上限、UI 限制全开。
//! - 进程创建属性：禁子进程、win32k lockdown、`HANDLE_LIST` 只放三个标准句柄。

use std::ffi::{c_void, OsStr};
use std::io::{self, Read, Write};
use std::os::windows::ffi::OsStrExt as _;
use std::path::Path;
use std::ptr::{null, null_mut};
use std::sync::{Arc, OnceLock};

use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Security::Isolation::*;
use windows_sys::Win32::Security::*;
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, ReadFile, WriteFile, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ, FILE_SHARE_WRITE,
    OPEN_EXISTING,
};
use windows_sys::Win32::System::JobObjects::*;
use windows_sys::Win32::System::Pipes::CreatePipe;
use windows_sys::Win32::System::Threading::*;

use crate::isolated::{IsolatedChild, Isolation, Killer, Limits};

const APP_CONTAINER_NAME: &str = "ppass.decoder";
const ERROR_ALREADY_EXISTS_HR: u32 = 0x8007_00B7;

// 进程创建属性常量（winbase.h 的 ProcThreadAttribute* 宏展开值）。
const ATTR_MITIGATION_POLICY: usize = 0x0002_0007;
const ATTR_SECURITY_CAPABILITIES: usize = 0x0002_0009;
const ATTR_HANDLE_LIST: usize = 0x0002_0002;
const ATTR_CHILD_PROCESS_POLICY: usize = 0x0002_000E;
const CHILD_PROCESS_RESTRICTED: u32 = 1;
const MITIGATION_WIN32K_DISABLE: u64 = 1 << 28;

fn wide(s: &OsStr) -> Vec<u16> {
    s.encode_wide().chain(std::iter::once(0)).collect()
}

fn last(what: &str) -> io::Error {
    let e = io::Error::last_os_error();
    io::Error::new(e.kind(), format!("{what}: {e}"))
}

/// 一端管道。
struct Pipe(HANDLE);
// SAFETY: HANDLE 是进程内的内核对象句柄，可跨线程使用。
unsafe impl Send for Pipe {}
impl Drop for Pipe {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: 本结构独占该句柄。
            unsafe { CloseHandle(self.0) };
        }
    }
}
impl Read for Pipe {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let mut n = 0u32;
        let len = buf.len().min(1 << 20) as u32;
        // SAFETY: buf 有效且 len 不超过其长度。
        let ok = unsafe { ReadFile(self.0, buf.as_mut_ptr().cast(), len, &mut n, null_mut()) };
        if ok == 0 {
            let e = io::Error::last_os_error();
            // 对端关闭写端 = EOF。
            if e.raw_os_error() == Some(ERROR_BROKEN_PIPE as i32) {
                return Ok(0);
            }
            return Err(e);
        }
        Ok(n as usize)
    }
}
impl Write for Pipe {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let mut n = 0u32;
        let len = buf.len().min(1 << 20) as u32;
        // SAFETY: buf 有效且 len 不超过其长度。
        let ok = unsafe { WriteFile(self.0, buf.as_ptr().cast(), len, &mut n, null_mut()) };
        if ok == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(n as usize)
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Job + 进程句柄；丢弃时关闭 Job，「关闭即杀」兜底。
struct Proc {
    job: HANDLE,
    process: HANDLE,
}
// SAFETY: 同 Pipe。
unsafe impl Send for Proc {}
unsafe impl Sync for Proc {}
impl Drop for Proc {
    fn drop(&mut self) {
        // SAFETY: 独占；先显式终止，再关 Job。
        unsafe {
            TerminateJobObject(self.job, 1);
            CloseHandle(self.process);
            CloseHandle(self.job);
        }
    }
}

pub(crate) struct Inner {
    proc: Arc<Proc>,
}

impl Inner {
    pub(crate) fn isolation(&self) -> Isolation {
        Isolation::AppContainer
    }
    pub(crate) fn killer(&self) -> Killer {
        let p = Arc::clone(&self.proc);
        Killer::new(move || {
            // SAFETY: Arc 保证句柄有效。
            unsafe { TerminateJobObject(p.job, 1) };
        })
    }
    pub(crate) fn wait(&mut self) -> io::Result<bool> {
        // SAFETY: 进程句柄有效。
        unsafe {
            if WaitForSingleObject(self.proc.process, INFINITE) != WAIT_OBJECT_0 {
                return Err(last("WaitForSingleObject"));
            }
            let mut code = 1u32;
            if GetExitCodeProcess(self.proc.process, &mut code) == 0 {
                return Err(last("GetExitCodeProcess"));
            }
            Ok(code == 0)
        }
    }
}

/// 缓存的 AppContainer SID（地址存成 usize 以便放进 `OnceLock`）；
/// 进程生命周期内不释放。
static AC_SID: OnceLock<Result<usize, String>> = OnceLock::new();

fn app_container_sid() -> io::Result<PSID> {
    let r = AC_SID.get_or_init(|| {
        let name = wide(OsStr::new(APP_CONTAINER_NAME));
        let mut sid: PSID = null_mut();
        // SAFETY: 参数指针均有效。
        unsafe {
            let hr = CreateAppContainerProfile(
                name.as_ptr(),
                name.as_ptr(),
                name.as_ptr(),
                null(),
                0,
                &mut sid,
            );
            if hr == 0 {
                return Ok(sid as usize);
            }
            if hr as u32 != ERROR_ALREADY_EXISTS_HR {
                return Err(format!(
                    "CreateAppContainerProfile HRESULT=0x{:08X}",
                    hr as u32
                ));
            }
            let hr = DeriveAppContainerSidFromAppContainerName(name.as_ptr(), &mut sid);
            if hr != 0 {
                return Err(format!(
                    "DeriveAppContainerSidFromAppContainerName HRESULT=0x{:08X}",
                    hr as u32
                ));
            }
        }
        Ok(sid as usize)
    });
    match r {
        Ok(p) => Ok(*p as PSID),
        Err(e) => Err(io::Error::new(io::ErrorKind::Unsupported, e.clone())),
    }
}

pub(crate) fn spawn(exe: &Path, limits: &Limits) -> io::Result<IsolatedChild> {
    let sid = app_container_sid()?;
    // SAFETY: 全部是 Win32 调用；每个失败分支都在返回前释放已创建的句柄。
    unsafe {
        let sa = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: null_mut(),
            bInheritHandle: 1,
        };
        // stdin：子端读（可继承）、父端写（不可继承）；stdout 反之。
        let (mut in_r, mut in_w, mut out_r, mut out_w) =
            (null_mut(), null_mut(), null_mut(), null_mut());
        if CreatePipe(&mut in_r, &mut in_w, &sa, 0) == 0 {
            return Err(last("CreatePipe(stdin)"));
        }
        let (in_r, in_w) = (Pipe(in_r), Pipe(in_w));
        if CreatePipe(&mut out_r, &mut out_w, &sa, 0) == 0 {
            return Err(last("CreatePipe(stdout)"));
        }
        let (out_r, out_w) = (Pipe(out_r), Pipe(out_w));
        SetHandleInformation(in_w.0, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(out_r.0, HANDLE_FLAG_INHERIT, 0);
        // stderr → NUL：panic 文本不进协议管道，也没有无人读的管道可写满。
        let nul = wide(OsStr::new("NUL"));
        let err_h = CreateFileW(
            nul.as_ptr(),
            GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            &sa,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            null_mut(),
        );
        if err_h == INVALID_HANDLE_VALUE {
            return Err(last("open NUL"));
        }
        let err_h = Pipe(err_h);

        // Job：关闭即杀、仅一个进程、单进程内存上限、UI 限制全开。
        let job = CreateJobObjectW(null(), null());
        if job.is_null() {
            return Err(last("CreateJobObject"));
        }
        let mut ex: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
        ex.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            | JOB_OBJECT_LIMIT_ACTIVE_PROCESS
            | JOB_OBJECT_LIMIT_PROCESS_MEMORY;
        ex.BasicLimitInformation.ActiveProcessLimit = 1;
        ex.ProcessMemoryLimit = limits.memory_bytes as usize;
        let ui = JOBOBJECT_BASIC_UI_RESTRICTIONS {
            UIRestrictionsClass: 0xFF,
        };
        if SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            (&ex as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
            std::mem::size_of_val(&ex) as u32,
        ) == 0
            || SetInformationJobObject(
                job,
                JobObjectBasicUIRestrictions,
                (&ui as *const JOBOBJECT_BASIC_UI_RESTRICTIONS).cast(),
                std::mem::size_of_val(&ui) as u32,
            ) == 0
        {
            let e = last("SetInformationJobObject");
            CloseHandle(job);
            return Err(e);
        }

        // 进程创建属性。
        let mut handles = [in_r.0, out_w.0, err_h.0];
        let mut caps = SECURITY_CAPABILITIES {
            AppContainerSid: sid,
            Capabilities: null_mut(),
            CapabilityCount: 0,
            Reserved: 0,
        };
        let mut child_policy = CHILD_PROCESS_RESTRICTED;
        let mut mitigation = MITIGATION_WIN32K_DISABLE;
        let mut size = 0usize;
        InitializeProcThreadAttributeList(null_mut(), 4, 0, &mut size);
        let mut abuf = vec![0u8; size];
        let al = abuf.as_mut_ptr() as LPPROC_THREAD_ATTRIBUTE_LIST;
        if InitializeProcThreadAttributeList(al, 4, 0, &mut size) == 0 {
            let e = last("InitializeProcThreadAttributeList");
            CloseHandle(job);
            return Err(e);
        }
        let set = |id: usize, p: *mut c_void, n: usize, what: &str| -> io::Result<()> {
            if UpdateProcThreadAttribute(al, 0, id, p, n, null_mut(), null()) == 0 {
                Err(last(what))
            } else {
                Ok(())
            }
        };
        let attrs = (|| {
            set(
                ATTR_HANDLE_LIST,
                handles.as_mut_ptr().cast(),
                std::mem::size_of_val(&handles),
                "attr HANDLE_LIST",
            )?;
            set(
                ATTR_CHILD_PROCESS_POLICY,
                (&mut child_policy as *mut u32).cast(),
                4,
                "attr CHILD_PROCESS_POLICY",
            )?;
            set(
                ATTR_MITIGATION_POLICY,
                (&mut mitigation as *mut u64).cast(),
                8,
                "attr MITIGATION_POLICY",
            )?;
            set(
                ATTR_SECURITY_CAPABILITIES,
                (&mut caps as *mut SECURITY_CAPABILITIES).cast(),
                std::mem::size_of::<SECURITY_CAPABILITIES>(),
                "attr SECURITY_CAPABILITIES",
            )
        })();
        if let Err(e) = attrs {
            DeleteProcThreadAttributeList(al);
            CloseHandle(job);
            return Err(e);
        }

        let mut si: STARTUPINFOEXW = std::mem::zeroed();
        si.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXW>() as u32;
        si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        si.StartupInfo.hStdInput = in_r.0;
        si.StartupInfo.hStdOutput = out_w.0;
        si.StartupInfo.hStdError = err_h.0;
        si.lpAttributeList = al;
        let mut pi: PROCESS_INFORMATION = std::mem::zeroed();
        let mut cmd = wide(OsStr::new(&format!("\"{}\"", exe.display())));
        // 工作目录 = exe 所在目录（AppContainer 对它有读权限；继承 daemon 的未必有）。
        let cwd = exe.parent().map(|d| wide(d.as_os_str()));
        // 不能用 CREATE_NO_WINDOW：console 程序仍会被拉起一个隐藏的 conhost.exe 子进程，
        // 而 Job 的 ActiveProcessLimit=1 + 子进程限制会挡住它，kernel32 控制台初始化失败，
        // 进程在 main 之前以 0xC0000142 退出。DETACHED_PROCESS 不分配控制台；
        // 标准输入输出走 STARTF_USESTDHANDLES 的管道 / NUL，不受影响。
        let created = CreateProcessW(
            null(),
            cmd.as_mut_ptr(),
            null(),
            null(),
            1,
            EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | DETACHED_PROCESS,
            null(),
            cwd.as_ref().map_or(null(), |c| c.as_ptr()),
            &si.StartupInfo,
            &mut pi,
        );
        let create_err = (created == 0).then(|| last("CreateProcessW"));
        DeleteProcThreadAttributeList(al);
        if let Some(e) = create_err {
            CloseHandle(job);
            return Err(e);
        }
        // 先入 Job 再放行：进程在任何一条指令执行前就已受限。
        if AssignProcessToJobObject(job, pi.hProcess) == 0 {
            let e = last("AssignProcessToJobObject");
            TerminateProcess(pi.hProcess, 1);
            CloseHandle(pi.hProcess);
            CloseHandle(pi.hThread);
            CloseHandle(job);
            return Err(e);
        }
        let proc = Proc {
            job,
            process: pi.hProcess,
        };
        ResumeThread(pi.hThread);
        CloseHandle(pi.hThread);
        // 子端句柄已被子进程继承，父端关掉，否则读不到 EOF。
        drop((in_r, out_w, err_h));
        Ok(IsolatedChild {
            stdin: Some(Box::new(in_w)),
            stdout: Some(Box::new(out_r)),
            inner: Inner {
                proc: Arc::new(proc),
            },
        })
    }
}
