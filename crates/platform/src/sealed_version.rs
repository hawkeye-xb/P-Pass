//! #1150：读已签名代码里**被签名封住**的 `CFBundleShortVersionString`。
//!
//! 为什么不用 csreq 的 `info[CFBundleShortVersionString] >= "..."`：csreq 按数字逐段比字符串，
//! `0.10.0-test.10 >= "0.10.0"` 判真（实测），而本项目的版本语义是「预发布 < 正式版」
//! （`version_cmp`）。所以版本在这里读出来，交给 `version_cmp` 比。
//!
//! 读法：`SecCodeCopyStaticCode` + `SecCodeCopySigningInformation(kSecCSSigningInformation)`，
//! 取 `kSecCodeInfoPList`。Security 取这份 Info.plist 时会按 CodeDirectory 里的 Info.plist
//! 特殊槽哈希校验（与 csreq 的 `info[]` 同一条路径），所以改了磁盘上的 Info.plist 读不出来
//! 篡改后的版本——[`tests`] 里有反证。**不**用 `SecCode::path()` 再自己读盘：动态校验
//! 不核对资源，磁盘上被改过的 Info.plist 会被采信。

use core_foundation::base::{CFRelease, CFTypeRef, TCFType};
use core_foundation::dictionary::{CFDictionaryGetValue, CFDictionaryRef};
use core_foundation::string::{CFString, CFStringRef};
use security_framework::os::macos::code_signing::{SecCode, SecStaticCode};
use std::ffi::c_void;

type OSStatus = i32;
/// `kSecCSSigningInformation`（CSCommon.h / SecStaticCode.h）。
const K_SEC_CS_SIGNING_INFORMATION: u32 = 1 << 1;

#[link(name = "Security", kind = "framework")]
extern "C" {
    static kSecCodeInfoPList: CFStringRef;
    fn SecCodeCopyStaticCode(
        code: *const c_void,
        flags: u32,
        static_code: *mut *const c_void,
    ) -> OSStatus;
    fn SecCodeCopySigningInformation(
        code: *const c_void,
        flags: u32,
        information: *mut CFDictionaryRef,
    ) -> OSStatus;
}

const VERSION_KEY: &str = "CFBundleShortVersionString";

/// 对端（运行中的代码）的封存版本号。
pub(crate) fn of_guest(code: &SecCode) -> Result<String, String> {
    let mut sc: *const c_void = std::ptr::null();
    // SAFETY: code 是有效的 SecCodeRef；成功时 sc 由我们持有（create rule），下面包进 SecStaticCode 释放。
    let st = unsafe { SecCodeCopyStaticCode(code.as_CFTypeRef().cast(), 0, &mut sc) };
    if st != 0 || sc.is_null() {
        return Err(format!("取不到对端静态代码（OSStatus {st}）"));
    }
    // SAFETY: sc 非空、来自 Copy 函数（+1 引用），交给包装类型负责 CFRelease。
    let static_code = unsafe { SecStaticCode::wrap_under_create_rule(sc.cast_mut().cast()) };
    of_static(&static_code)
}

/// 磁盘上一个已签名代码（static）的封存版本号。
pub(crate) fn of_static(code: &SecStaticCode) -> Result<String, String> {
    let mut info: CFDictionaryRef = std::ptr::null();
    // SAFETY: code 有效；成功时 info 是 +1 的字典，下面读完释放。
    let st = unsafe {
        SecCodeCopySigningInformation(
            code.as_CFTypeRef().cast(),
            K_SEC_CS_SIGNING_INFORMATION,
            &mut info,
        )
    };
    if st != 0 || info.is_null() {
        return Err(format!("取不到签名信息（OSStatus {st}）"));
    }
    let out = (|| {
        // SAFETY: info 是有效字典；kSecCodeInfoPList 是 Security 导出的常量键。
        let plist = unsafe { CFDictionaryGetValue(info, kSecCodeInfoPList.cast()) };
        if plist.is_null() {
            return Err("签名信息里没有 Info.plist".to_string());
        }
        let key = CFString::new(VERSION_KEY);
        // SAFETY: plist 是 Info.plist 的 CFDictionary（Security 文档：kSecCodeInfoPList 为字典）。
        let v = unsafe { CFDictionaryGetValue(plist.cast(), key.as_concrete_TypeRef().cast()) };
        if v.is_null() {
            return Err(format!("Info.plist 没有 {VERSION_KEY}"));
        }
        // SAFETY: 值是 CFString（Info.plist 的字符串项）；get rule，不接管所有权。
        let s = unsafe { CFString::wrap_under_get_rule(v as CFStringRef) };
        Ok(s.to_string())
    })();
    // SAFETY: info 是上面 Copy 得到的 +1 引用。
    unsafe { CFRelease(info as CFTypeRef) };
    out
}

#[cfg(test)]
#[allow(clippy::disallowed_methods)]
mod tests {
    use super::*;
    use core_foundation::url::CFURL;
    use security_framework::os::macos::code_signing::Flags;
    use std::path::{Path, PathBuf};
    use std::process::Command;

    fn app_with_version(dir: &Path, version: &str) -> PathBuf {
        let app = dir.join("V.app");
        std::fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
        std::fs::copy("/usr/bin/true", app.join("Contents/MacOS/v")).unwrap();
        std::fs::write(
            app.join("Contents/Info.plist"),
            format!(
                r#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.v</string>
<key>CFBundleExecutable</key><string>v</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>{version}</string>
</dict></plist>"#
            ),
        )
        .unwrap();
        let st = Command::new("codesign")
            .args(["--force", "--sign", "-"])
            .arg(&app)
            .status()
            .unwrap();
        assert!(st.success());
        app
    }

    fn read(app: &Path) -> Result<String, String> {
        let url = CFURL::from_path(app, true).unwrap();
        let code = SecStaticCode::from_path(&url, Flags::NONE).unwrap();
        of_static(&code)
    }

    #[test]
    fn reads_the_signed_version() {
        let d = tempfile::tempdir().unwrap();
        let app = app_with_version(d.path(), "0.10.0-test.10");
        assert_eq!(read(&app).unwrap(), "0.10.0-test.10");
    }

    /// 反证：若改成直接读磁盘上的 Info.plist，篡改后的「9.9.9」会被读出，这条红。
    /// 签名后改 Info.plist 的版本号：读出来要么报错、要么仍是签名时的值，绝不是 9.9.9。
    #[test]
    fn a_tampered_info_plist_does_not_change_the_answer() {
        let d = tempfile::tempdir().unwrap();
        let app = app_with_version(d.path(), "0.1.0");
        let plist = app.join("Contents/Info.plist");
        let text = std::fs::read_to_string(&plist).unwrap();
        std::fs::write(&plist, text.replace("0.1.0", "9.9.9")).unwrap();
        if let Ok(v) = read(&app) {
            assert_ne!(v, "9.9.9", "读到了磁盘上被篡改的版本");
        }
    }
}
