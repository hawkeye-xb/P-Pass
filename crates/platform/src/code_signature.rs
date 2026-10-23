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

/// 内置 daemon（嵌套 helper App，#1110）的 bundle id。
pub const DAEMON_APP_ID: &str = "com.hawkeyexb.ppass.desktop.daemon";

/// 「本团队的 **Developer ID Application** 证书签名、且标识为 `identifier`」的代码签名要求
/// （csreq 语法，与 `codesign -d -r-` 给 Developer ID 签名程序生成的 designated requirement 同形）。
///
/// - `anchor apple generic`：证书链终于 Apple 根证书（自签、ad-hoc 都过不了）；
/// - `certificate 1[field.1.2.840.113635.100.6.2.6]`：中间证书是 Developer ID CA；
/// - `certificate leaf[field.1.2.840.113635.100.6.1.13]`：叶证书是 Developer ID Application；
/// - `certificate leaf[subject.OU]`：团队 ID。
///
/// #1115 实测：只写团队 ID 时，同团队的其他 Developer ID 程序与 **Apple Development** 签名
/// （开发证书，同一个 OU）都能通过；两个 OID 与 identifier 缺一不可。
pub fn code_requirement(identifier: &str) -> String {
    format!(
        "identifier \"{identifier}\" and anchor apple generic \
         and certificate 1[field.1.2.840.113635.100.6.2.6] \
         and certificate leaf[field.1.2.840.113635.100.6.1.13] \
         and certificate leaf[subject.OU] = \"{DEVELOPER_TEAM_ID}\""
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
    /// 本平台没有发布者签名可校验，但已经对**同一份字节**做了包内版本判据：
    /// 版本资源严格高于当前版本（防降级）。
    ///
    /// **不等于** [`Self::Verified`]：「包是谁做的」没有证据，只有「不是旧包」这一条。
    VersionOnly,
}

/// 校验 updater 下载下来的更新包（已过 minisign 验签的字节）。
///
/// - macOS：`.app.tar.gz`。解到临时目录，要求恰好一个顶层 `.app`，用 Security 框架
///   按 [`code_requirement`] 做静态校验（含嵌套代码、严格模式、所有架构）；通过后再读包里
///   `Info.plist` 的 `CFBundleShortVersionString`，必须**严格高于** `current_version`（防降级）。
/// - Windows：`setup.exe` 的 PE 版本资源（`StringFileInfo\<lang>\FileVersion`）必须**严格高于**
///   `current_version`，通过后返回 [`UpdatePackageCheck::VersionOnly`]（没有发布者签名，不谎报 Verified）。
/// - 其他平台：[`UpdatePackageCheck::NotChecked`]。
///
/// #1116 P2-2：updater 判断「要不要更新」比的是清单里的版本号，而清单不签名——能写更新源的人
/// 可以把任何一个正式私钥签过的旧包标成「新版」推下来。包里的版本号在代码签名的封装之内
/// （改了即验签失败），所以在这里、对已验签的那份字节比版本，旧包装不上。
pub fn verify_update_package(bytes: &[u8], current_version: &str) -> UpdatePackageCheck {
    imp::verify_update_package(bytes, current_version)
}

/// 防降级判据：`new` 必须严格高于 `current`（semver，含预发布段：`0.10.0-test.8` <
/// `0.10.0-test.9` < `0.10.0`）。不是合法 semver 也拒绝——不猜。
pub fn newer_than_current(new: &str, current: &str) -> Result<(), String> {
    let parse = |v: &str| {
        semver::Version::parse(v.trim()).map_err(|e| format!("版本号「{v}」不是 semver：{e}"))
    };
    let (n, c) = (parse(new)?, parse(current)?);
    if n > c {
        Ok(())
    } else {
        Err(format!("新包版本 {n} 不高于当前 {c}（拒绝降级 / 重装）"))
    }
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
    use super::{code_requirement, newer_than_current, UpdatePackageCheck, DESKTOP_APP_ID};
    use core_foundation::url::CFURL;
    use security_framework::os::macos::code_signing::{Flags, SecRequirement, SecStaticCode};
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Stdio};
    use std::str::FromStr;

    pub(super) fn verify_update_package(bytes: &[u8], current_version: &str) -> UpdatePackageCheck {
        // tempfile：随机名、0700、离开作用域即删。手写的「pid + 纳秒」名字在同一进程
        // 并发校验时会撞名（CI 实测 File exists），且在共享 /tmp 里可被预测。
        let dir = match tempfile::Builder::new()
            .prefix("ppass-update-check-")
            .tempdir()
        {
            Ok(d) => d,
            Err(e) => return UpdatePackageCheck::Rejected(format!("建临时目录失败：{e}")),
        };
        match unpack(bytes, dir.path()) {
            Ok(()) => match single_app(dir.path()) {
                Ok(app) => match verify_app_bundle(&app, DESKTOP_APP_ID) {
                    // 版本号只在验签通过之后读：那时 Info.plist 已被签名封装担保。
                    UpdatePackageCheck::Verified => match bundle_version(&app)
                        .and_then(|v| newer_than_current(&v, current_version))
                    {
                        Ok(()) => UpdatePackageCheck::Verified,
                        Err(e) => UpdatePackageCheck::Rejected(e),
                    },
                    other => other,
                },
                Err(e) => UpdatePackageCheck::Rejected(e),
            },
            Err(e) => UpdatePackageCheck::Rejected(e),
        }
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

    /// 包里 App 的 `CFBundleShortVersionString`。
    fn bundle_version(app: &Path) -> Result<String, String> {
        let info = plist::Value::from_file(app.join("Contents/Info.plist"))
            .map_err(|e| format!("读不到包里的 Info.plist：{e}"))?;
        info.as_dictionary()
            .and_then(|d| d.get("CFBundleShortVersionString"))
            .and_then(|v| v.as_string())
            .map(str::to_string)
            .ok_or_else(|| "包里的 Info.plist 没有 CFBundleShortVersionString".to_string())
    }

    /// 系统自带的 bsdtar 解包：拒绝绝对路径与 `..`（不带 `-P` 时的默认行为）。
    ///
    /// stdin 在单独线程里写：主线程等 tar 退出并收 stderr。同一线程先写完 stdin 再读
    /// stderr，tar 的 stderr 一旦写满管道缓冲就会两边互等。
    fn unpack(bytes: &[u8], dir: &Path) -> Result<(), String> {
        let mut child = Command::new("/usr/bin/tar")
            .args(["-xzf", "-", "-C"])
            .arg(dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("启动 tar 失败：{e}"))?;
        let mut stdin = child.stdin.take().ok_or("tar 没有 stdin")?;
        let data = bytes.to_vec();
        let writer = std::thread::spawn(move || stdin.write_all(&data));
        let out = child
            .wait_with_output()
            .map_err(|e| format!("等待 tar 失败：{e}"))?;
        let write = writer
            .join()
            .map_err(|_| "写入 tar 的线程崩溃".to_string())?;
        if !out.status.success() {
            return Err(format!(
                "解包失败：{}",
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        write.map_err(|e| format!("写入 tar 失败：{e}"))?;
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
}

#[cfg(windows)]
mod imp {
    use super::{newer_than_current, UpdatePackageCheck};

    /// #1155：Windows 没有发布者签名可校验，只做防降级。
    ///
    /// 版本从**传进来的这份字节**里读（不落盘、不再读文件），所以「验签的那份」与
    /// 「判版本的那份」是同一份，中间没有替换窗口。读不到版本资源就拒绝——不拿
    /// `VS_FIXEDFILEINFO` 的 `major.minor.patch.0` 兜底，那会把 `-test.N` 后缀丢掉。
    pub(super) fn verify_update_package(bytes: &[u8], current_version: &str) -> UpdatePackageCheck {
        match crate::pe_version::file_version_from_bytes(bytes) {
            Ok(package_version) => match newer_than_current(&package_version, current_version) {
                Ok(()) => UpdatePackageCheck::VersionOnly,
                Err(e) => UpdatePackageCheck::Rejected(e),
            },
            Err(e) => UpdatePackageCheck::Rejected(format!("读不到安装包的版本资源：{e}")),
        }
    }
}

#[cfg(not(any(target_os = "macos", windows)))]
mod imp {
    use super::UpdatePackageCheck;

    pub(super) fn verify_update_package(
        _bytes: &[u8],
        _current_version: &str,
    ) -> UpdatePackageCheck {
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
        // 与 `codesign -d -r-` 对本机个人 Developer ID 签名的 P-Pass.app 输出的 designated
        // requirement 逐项一致（去掉注释后）。反证：去掉任一个 OID 或 identifier，红。
        assert_eq!(
            r,
            "identifier \"com.hawkeyexb.ppass.desktop\" and anchor apple generic \
             and certificate 1[field.1.2.840.113635.100.6.2.6] \
             and certificate leaf[field.1.2.840.113635.100.6.1.13] \
             and certificate leaf[subject.OU] = \"2WJUWVUJBN\""
        );
    }

    /// #1116 P2-2：防降级判据。反证：把 `n > c` 改成 `n >= c`，「同版本」那条红；
    /// 只比 major.minor.patch，test.8 → test.9 那条红。
    #[test]
    fn only_strictly_newer_versions_pass() {
        assert!(newer_than_current("0.10.0-test.9", "0.10.0-test.8").is_ok());
        assert!(newer_than_current("0.10.0", "0.10.0-test.9").is_ok());
        assert!(newer_than_current("0.10.1", "0.10.0").is_ok());
        assert!(
            newer_than_current("0.10.0-test.8", "0.10.0-test.8").is_err(),
            "同版本"
        );
        assert!(
            newer_than_current("0.10.0-test.7", "0.10.0-test.8").is_err(),
            "旧 test 包"
        );
        assert!(newer_than_current("0.9.12", "0.10.0").is_err(), "旧正式版");
        assert!(
            newer_than_current("garbage", "0.10.0").is_err(),
            "不是 semver"
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

        fn bundle_version_for_test(app: &Path) -> String {
            plist::Value::from_file(app.join("Contents/Info.plist"))
                .unwrap()
                .as_dictionary()
                .unwrap()
                .get("CFBundleShortVersionString")
                .unwrap()
                .as_string()
                .unwrap()
                .to_string()
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
                verify_update_package(&tar_gz(&app), "0.0.1"),
                UpdatePackageCheck::Rejected(_)
            ));
            let _ = std::fs::remove_dir_all(&d);
        }

        /// 反例（#1115 / #1121）：**同团队**的 Apple Development（开发证书）签名、标识也对——
        /// 只写团队 ID 的要求串会放它过去（讨论稿 §2.4 实测），Developer ID 的两个 OID 挡住它。
        /// 要一张本团队的 Apple Development 证书，所以只在 `PPASS_APPLE_DEV_IDENTITY=<证书 SHA-1>`
        /// 时跑（签名会访问钥匙串里的私钥）；没给就打印跳过。
        /// 反证：code_requirement 去掉两个 OID 子句 ⇒ 这里变 Verified，红。
        #[test]
        fn same_team_apple_development_signature_is_rejected() {
            let Some(identity) = std::env::var_os("PPASS_APPLE_DEV_IDENTITY") else {
                eprintln!(
                    "跳过：没给 PPASS_APPLE_DEV_IDENTITY（本团队 Apple Development 证书的 SHA-1）"
                );
                return;
            };
            let d = tmp("appledev");
            let app = adhoc_app(&d);
            let st = Command::new("codesign")
                .args([
                    "--force",
                    "--options",
                    "runtime",
                    "--timestamp=none",
                    "--sign",
                ])
                .arg(&identity)
                .arg(&app)
                .status()
                .unwrap();
            assert!(st.success(), "用 Apple Development 证书签名失败");
            let info = Command::new("codesign")
                .args(["-dvv"])
                .arg(&app)
                .output()
                .unwrap();
            let info = String::from_utf8_lossy(&info.stderr);
            assert!(
                info.contains(&format!("TeamIdentifier={DEVELOPER_TEAM_ID}")),
                "得是本团队的证书：{info}"
            );
            match verify_app_bundle(&app, DESKTOP_APP_ID) {
                UpdatePackageCheck::Rejected(why) => assert!(why.contains("不满足要求"), "{why}"),
                other => panic!("同团队 Apple Development 签名不该通过：{other:?}"),
            }
            assert!(matches!(
                verify_update_package(&tar_gz(&app), "0.0.1"),
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
                verify_update_package(b"not a tarball", "0.0.1"),
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
            match verify_update_package(&out.stdout, "0.0.1") {
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
            assert_eq!(
                verify_update_package(&bytes, "0.0.1"),
                UpdatePackageCheck::Verified
            );
            // #1116 P2-2：签名完好的同一个包，当前版本已不低于它 ⇒ 拒绝（防降级 / 重装）。
            // 反证：去掉 verify_update_package 里的 newer_than_current，这两条变 Verified，红。
            let version = bundle_version_for_test(&app);
            for current in [version.clone(), "999.0.0".to_string()] {
                match verify_update_package(&bytes, &current) {
                    UpdatePackageCheck::Rejected(why) => {
                        assert!(why.contains("不高于当前"), "{why}")
                    }
                    other => panic!("当前 {current}、包 {version}：不该通过：{other:?}"),
                }
            }

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
                verify_update_package(&tar_gz(&copy), "0.0.1"),
                UpdatePackageCheck::Rejected(_)
            ));
            let _ = std::fs::remove_dir_all(&d);
        }
    }
    /// #1155：Windows 的结果必须是「仅防降级」，不能是 `Verified`；旧版本、同版本、
    /// 非 semver 版本串与坏字节都要拒。构造的 PE 与 Tauri NSIS `setup.exe` 的版本串同形
    /// （V8 实测：`StringFileInfo\FileVersion` 就是 `0.4.0-test.5` 这种）。
    #[cfg(windows)]
    #[test]
    fn windows_update_check_is_version_only_and_rejects_downgrade() {
        use crate::pe_version::test_pe::pe_with_version;
        match verify_update_package(&pe_with_version("0.10.1"), "0.10.0") {
            UpdatePackageCheck::VersionOnly => {}
            other => panic!("应当是 VersionOnly（不是 Verified）：{other:?}"),
        }
        match verify_update_package(&pe_with_version("0.10.0-test.9"), "0.10.0-test.8") {
            UpdatePackageCheck::VersionOnly => {}
            other => panic!("预发布段也按 semver 比：{other:?}"),
        }
        for (pkg, cur) in [
            ("0.10.0", "0.10.0"),
            ("0.9.12", "0.10.0"),
            ("0.10.0-test.8", "0.10.0-test.9"),
            ("not-a-version", "0.10.0"),
        ] {
            match verify_update_package(&pe_with_version(pkg), cur) {
                UpdatePackageCheck::Rejected(why) => {
                    assert!(
                        why.contains("不高于") || why.contains("不是 semver"),
                        "{pkg} vs {cur}: {why}"
                    );
                }
                other => panic!("{pkg} vs {cur} 必须拒绝：{other:?}"),
            }
        }
        match verify_update_package(b"PK\x03\x04", "0.10.0") {
            UpdatePackageCheck::Rejected(why) => assert!(why.contains("PE"), "{why}"),
            other => panic!("非 PE 字节必须拒绝：{other:?}"),
        }
        // 真实系统 DLL 的版本串是 `10.0.26100.9711 (WinBuild.160101.0800)`，不是 semver：
        // 解析得出来也必须拒绝——不猜、不截断。
        let path = std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".into())
            + "\\System32\\kernel32.dll";
        if let Ok(bytes) = std::fs::read(&path) {
            match verify_update_package(&bytes, "0.10.0") {
                UpdatePackageCheck::Rejected(why) => assert!(why.contains("不是 semver"), "{why}"),
                other => panic!("非 semver 的系统版本串必须拒绝：{other:?}"),
            }
        }
    }
}
