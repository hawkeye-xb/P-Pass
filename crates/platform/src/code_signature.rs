//! #1121：代码签名要求——安装更新前确认新包出自我们的团队。
//!
//! updater 的 minisign 验签证明「这份字节是我们的更新密钥签的」；这里再加一道与之
//! 独立的检查：解出来的 App 必须是 Apple 签发给团队 [`DEVELOPER_TEAM_ID`] 的证书签的，
//! 标识是桌面主 App。对齐 Sparkle 的做法（安装前用 Security 框架校验新包的代码签名
//! 与旧包同一团队）。更新密钥泄露也装不进一个不是我们团队签名的包。
//!
//! 签名要求串由 [`code_requirement`] 统一构造（#1115 的 IPC 对端校验用同一形状）。

#[cfg(target_os = "macos")]
use std::path::Path;

/// 个人开发者团队（Developer ID 证书的 OU）。签名、授权文件、钥匙串访问组都是它。
pub const DEVELOPER_TEAM_ID: &str = "2WJUWVUJBN";

/// 桌面主 App 的 bundle id（#1112）。
pub const DESKTOP_APP_ID: &str = "com.hawkeyexb.ppass.desktop";

/// 「由 Apple 签发给本团队的证书签名、且标识为 `identifier`」的代码签名要求（csreq 语法）。
///
/// `anchor apple generic` 要求证书链终于 Apple 根证书；`certificate leaf[subject.OU]` 是
/// 签名证书的团队 ID——自签证书、ad-hoc 签名、别的团队都满足不了。
pub fn code_requirement(identifier: &str) -> String {
    format!(
        "identifier \"{identifier}\" and anchor apple generic and certificate leaf[subject.OU] = \"{DEVELOPER_TEAM_ID}\""
    )
}

/// 更新包的代码签名检查结果。
///
/// 不是 `Result<()>`：「检查过并通过」与「这个平台还不检查」是两回事，调用方要分开
/// 记录——后者不能被说成通过。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UpdatePackageCheck {
    /// 包里的 App 满足 [`code_requirement`]`(`[`DESKTOP_APP_ID`]`)`。
    Verified,
    /// 不满足或无法检查（解包失败、形状不对、签名无效、团队不符）——不许安装。
    Rejected(String),
    /// 本平台还没有可校验的发布者签名（Windows 待取得代码签名证书）。
    NotChecked(&'static str),
}

/// 校验 updater 下载下来的更新包（已过 minisign 验签的字节）。
///
/// - macOS：`.app.tar.gz`。解到临时目录，要求恰好一个顶层 `.app`，用 Security 框架
///   按 [`code_requirement`] 做静态校验（含嵌套代码、严格模式、所有架构）。
/// - 其他平台：[`UpdatePackageCheck::NotChecked`]。
pub fn verify_update_package(bytes: &[u8]) -> UpdatePackageCheck {
    imp::verify_update_package(bytes)
}

/// 静态校验磁盘上一个 `.app`（macOS）。拆出来给测试和 [`verify_update_package`] 共用。
#[cfg(target_os = "macos")]
pub fn verify_app_bundle(app: &Path, identifier: &str) -> UpdatePackageCheck {
    imp::verify_app_bundle(app, identifier)
}

// clippy.toml 禁 `Command::new` 只为 Windows 的「GUI 进程拉 console 程序闪黑窗」；
// 这里只在 macOS 上编译（同 macos.rs 的整文件放行）。
#[cfg(target_os = "macos")]
#[allow(clippy::disallowed_methods)]
mod imp {
    use super::{code_requirement, UpdatePackageCheck, DESKTOP_APP_ID};
    use core_foundation::url::CFURL;
    use security_framework::os::macos::code_signing::{Flags, SecRequirement, SecStaticCode};
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Stdio};
    use std::str::FromStr;

    pub(super) fn verify_update_package(bytes: &[u8]) -> UpdatePackageCheck {
        let dir = match tempdir() {
            Ok(d) => d,
            Err(e) => return UpdatePackageCheck::Rejected(format!("建临时目录失败：{e}")),
        };
        let result = match unpack(bytes, &dir) {
            Ok(()) => match single_app(&dir) {
                Ok(app) => verify_app_bundle(&app, DESKTOP_APP_ID),
                Err(e) => UpdatePackageCheck::Rejected(e),
            },
            Err(e) => UpdatePackageCheck::Rejected(e),
        };
        let _ = std::fs::remove_dir_all(&dir);
        result
    }

    pub(super) fn verify_app_bundle(app: &Path, identifier: &str) -> UpdatePackageCheck {
        let Some(url) = CFURL::from_path(app, true) else {
            return UpdatePackageCheck::Rejected(format!("路径无法转换：{}", app.display()));
        };
        let requirement = match SecRequirement::from_str(&code_requirement(identifier)) {
            Ok(r) => r,
            Err(e) => return UpdatePackageCheck::Rejected(format!("签名要求无效：{e}")),
        };
        let code = match SecStaticCode::from_path(&url, Flags::NONE) {
            Ok(c) => c,
            Err(e) => return UpdatePackageCheck::Rejected(format!("读不到代码签名：{e}")),
        };
        // 不加吊销 / 有效期检查：离线也要能装，证书过期前签的包仍然有效（与 Gatekeeper 一致）。
        let flags =
            Flags::CHECK_ALL_ARCHITECTURES | Flags::CHECK_NESTED_CODE | Flags::STRICT_VALIDATE;
        match code.check_validity(flags, &requirement) {
            Ok(()) => UpdatePackageCheck::Verified,
            Err(e) => UpdatePackageCheck::Rejected(format!(
                "代码签名不满足要求（{identifier} / 团队）：{e}"
            )),
        }
    }

    /// 系统自带的 bsdtar 解包：拒绝绝对路径与 `..`（不带 `-P` 时的默认行为）。
    fn unpack(bytes: &[u8], dir: &Path) -> Result<(), String> {
        let mut child = Command::new("/usr/bin/tar")
            .args(["-xzf", "-", "-C"])
            .arg(dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("启动 tar 失败：{e}"))?;
        let write = child.stdin.take().ok_or("tar 没有 stdin")?.write_all(bytes);
        let out = child
            .wait_with_output()
            .map_err(|e| format!("等待 tar 失败：{e}"))?;
        write.map_err(|e| format!("写入 tar 失败：{e}"))?;
        if !out.status.success() {
            return Err(format!(
                "解包失败：{}",
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        Ok(())
    }

    /// 更新包里必须恰好一个顶层 `.app`，没有别的东西。
    fn single_app(dir: &Path) -> Result<PathBuf, String> {
        let entries: Vec<PathBuf> = std::fs::read_dir(dir)
            .map_err(|e| format!("读解包目录失败：{e}"))?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .collect();
        match entries.as_slice() {
            [one] if one.extension().is_some_and(|x| x == "app") && one.is_dir() => Ok(one.clone()),
            _ => Err(format!("更新包应恰好含一个 .app，实际：{entries:?}")),
        }
    }

    fn tempdir() -> std::io::Result<PathBuf> {
        let dir = std::env::temp_dir().join(format!(
            "ppass-update-check-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        std::fs::create_dir(&dir)?;
        Ok(dir)
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use super::UpdatePackageCheck;

    pub(super) fn verify_update_package(_bytes: &[u8]) -> UpdatePackageCheck {
        UpdatePackageCheck::NotChecked(
            "本平台尚未取得代码签名证书，安装前不校验发布者（仅 minisign 验签）",
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requirement_pins_identifier_apple_anchor_and_team() {
        let r = code_requirement(DESKTOP_APP_ID);
        assert_eq!(
            r,
            "identifier \"com.hawkeyexb.ppass.desktop\" and anchor apple generic and certificate leaf[subject.OU] = \"2WJUWVUJBN\""
        );
    }

    #[cfg(target_os = "macos")]
    #[allow(clippy::disallowed_methods)]
    mod macos {
        use super::super::*;
        use std::path::{Path, PathBuf};
        use std::process::Command;

        fn tmp(name: &str) -> PathBuf {
            let d = std::env::temp_dir().join(format!("ppass-cs-{name}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&d);
            std::fs::create_dir_all(&d).unwrap();
            d
        }

        /// 造一个最小 `.app`（拷一个系统可执行文件进去）并 ad-hoc 签名。
        fn adhoc_app(dir: &Path) -> PathBuf {
            let app = dir.join("P-Pass.app");
            std::fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
            std::fs::copy("/usr/bin/true", app.join("Contents/MacOS/p-pass-desktop")).unwrap();
            std::fs::write(
                app.join("Contents/Info.plist"),
                format!(
                    r#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>{DESKTOP_APP_ID}</string>
<key>CFBundleExecutable</key><string>p-pass-desktop</string>
<key>CFBundlePackageType</key><string>APPL</string>
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

        fn tar_gz(app: &Path) -> Vec<u8> {
            let out = Command::new("/usr/bin/tar")
                .env("COPYFILE_DISABLE", "1")
                .args(["-czf", "-", "-C"])
                .arg(app.parent().unwrap())
                .arg(app.file_name().unwrap())
                .output()
                .unwrap();
            assert!(out.status.success());
            out.stdout
        }

        /// 反例：标识对、签名完整，但只是 ad-hoc 签名（没有 Apple 证书链、没有团队）。
        /// 反证：要求串去掉 `anchor apple generic` 与团队那两段 ⇒ 这里变 Verified，红。
        #[test]
        fn adhoc_signed_app_is_rejected() {
            let d = tmp("adhoc");
            let app = adhoc_app(&d);
            assert!(matches!(
                verify_app_bundle(&app, DESKTOP_APP_ID),
                UpdatePackageCheck::Rejected(_)
            ));
            assert!(matches!(
                verify_update_package(&tar_gz(&app)),
                UpdatePackageCheck::Rejected(_)
            ));
            let _ = std::fs::remove_dir_all(&d);
        }

        /// 反例：Apple 自己签名的 App——证书链没问题，团队与标识都不是我们。
        #[test]
        fn apple_signed_app_of_another_identity_is_rejected() {
            let calc = Path::new("/System/Applications/Calculator.app");
            assert!(calc.exists(), "测试机应有系统计算器");
            match verify_app_bundle(calc, DESKTOP_APP_ID) {
                UpdatePackageCheck::Rejected(why) => assert!(why.contains("不满足要求"), "{why}"),
                other => panic!("Calculator.app 不该通过：{other:?}"),
            }
        }

        /// 反例：不是 tar.gz、或包里不止一个 .app ⇒ 拒绝，不去猜哪个是主 App。
        #[test]
        fn malformed_packages_are_rejected() {
            assert!(matches!(
                verify_update_package(b"not a tarball"),
                UpdatePackageCheck::Rejected(_)
            ));
            let d = tmp("two");
            let app = adhoc_app(&d);
            std::fs::create_dir_all(d.join("Other.app")).unwrap();
            let out = Command::new("/usr/bin/tar")
                .env("COPYFILE_DISABLE", "1")
                .args(["-czf", "-", "-C"])
                .arg(&d)
                .args(["P-Pass.app", "Other.app"])
                .output()
                .unwrap();
            match verify_update_package(&out.stdout) {
                UpdatePackageCheck::Rejected(why) => {
                    assert!(why.contains("恰好含一个 .app"), "{why}")
                }
                other => panic!("{other:?}"),
            }
            drop(app);
            let _ = std::fs::remove_dir_all(&d);
        }

        /// 正例 + 篡改：本机装着个人 Developer ID 签名的 P-Pass 时才跑（测试机状态，CI 上没有）。
        /// `PPASS_SIGNED_APP` 可指定别的路径。改掉包里一个文件后必须拒绝。
        #[test]
        fn developer_id_app_passes_and_tampering_is_caught() {
            let app = std::env::var_os("PPASS_SIGNED_APP")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    PathBuf::from(std::env::var("HOME").unwrap()).join("Applications/P-Pass.app")
                });
            if !app.join("Contents/_CodeSignature").exists() {
                eprintln!("跳过：{} 不是已签名的 App（本机没装测试包）", app.display());
                return;
            }
            let bytes = tar_gz(&app);
            assert_eq!(verify_update_package(&bytes), UpdatePackageCheck::Verified);

            // 解出来改一个资源文件再打包：封装被破坏，必须拒绝。
            let d = tmp("tamper");
            let st = Command::new("/usr/bin/tar")
                .args(["-xzf", "-", "-C"])
                .arg(&d)
                .stdin(std::process::Stdio::piped())
                .spawn()
                .and_then(|mut c| {
                    use std::io::Write;
                    c.stdin.take().unwrap().write_all(&bytes)?;
                    c.wait()
                })
                .unwrap();
            assert!(st.success());
            let copy = d.join(app.file_name().unwrap());
            std::fs::write(copy.join("Contents/Info.plist"), b"tampered").unwrap();
            assert!(matches!(
                verify_update_package(&tar_gz(&copy)),
                UpdatePackageCheck::Rejected(_)
            ));
            let _ = std::fs::remove_dir_all(&d);
        }
    }
}
