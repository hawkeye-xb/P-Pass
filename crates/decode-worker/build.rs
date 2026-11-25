// 链接随 `libheif` 一起安装并通过供应链校验的 `libde265`（HEVC 解码器），
// 供 `hevc_mp4` 在无系统 HEVC 解码器的 Windows 服务沙盒/裸机及跨平台单测中软解首帧。
//
// 使用 Cargo 传给构建脚本的 `CARGO_CFG_TARGET_*` 环境变量识别目标平台（与
// `apps/desktop/src-tauri/build.rs` 一致，不写 `#[cfg]` 平台属性，符合 B.2/G5）。
//
// 编译期宿主机脚本探测 pkg-config / brew，不进入运行时产品二进制，clippy.toml 的
// GUI 进程防闪黑窗规则不适用。
#![allow(clippy::disallowed_methods)]

use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=DOCS_RS");
    if std::env::var_os("DOCS_RS").is_some() {
        return;
    }

    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let target_env = std::env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();

    if target_os == "windows" && target_env == "msvc" {
        link_windows_msvc();
    } else {
        link_unix();
    }
}

fn link_windows_msvc() {
    println!("cargo:rerun-if-env-changed=VCPKG_ROOT");
    println!("cargo:rerun-if-env-changed=VCPKGRS_TRIPLET");
    let triplet =
        std::env::var("VCPKGRS_TRIPLET").unwrap_or_else(|_| "x64-windows-static-md".to_string());
    if let Ok(root) = std::env::var("VCPKG_ROOT") {
        let lib_dir = PathBuf::from(root)
            .join("installed")
            .join(&triplet)
            .join("lib");
        if lib_dir.is_dir() {
            println!("cargo:rustc-link-search=native={}", lib_dir.display());
        }
    }
    println!("cargo:rustc-link-lib=static=libde265");
}

fn link_unix() {
    println!("cargo:rerun-if-env-changed=PKG_CONFIG");
    println!("cargo:rerun-if-env-changed=PKG_CONFIG_PATH");
    println!("cargo:rerun-if-env-changed=PKG_CONFIG_LIBDIR");
    println!("cargo:rerun-if-env-changed=PKG_CONFIG_SYSROOT_DIR");

    if emit_from_pkg_config() {
        return;
    }

    if let Some(prefix) = brew_prefix("libde265") {
        let lib_dir = prefix.join("lib");
        if lib_dir.is_dir() {
            println!("cargo:rustc-link-search=native={}", lib_dir.display());
            println!("cargo:rustc-link-lib=de265");
            return;
        }
    }

    // 系统标准路径下已有 libde265（如 Linux /usr/lib/<multiarch>/libde265.so）时直接动态链接。
    println!("cargo:rustc-link-lib=de265");
}

fn emit_from_pkg_config() -> bool {
    let pkg_config = std::env::var("PKG_CONFIG").unwrap_or_else(|_| "pkg-config".to_string());
    let Ok(out) = Command::new(pkg_config)
        .args(["--libs-only-L", "--libs-only-l", "libde265"])
        .output()
    else {
        return false;
    };
    if !out.status.success() {
        return false;
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    let mut linked = false;
    for tok in stdout.split_whitespace() {
        if let Some(dir) = tok.strip_prefix("-L") {
            if !dir.is_empty() {
                println!("cargo:rustc-link-search=native={dir}");
            }
        } else if let Some(lib) = tok.strip_prefix("-l") {
            if !lib.is_empty() {
                println!("cargo:rustc-link-lib={lib}");
                linked = true;
            }
        }
    }
    linked
}

fn brew_prefix(formula: &str) -> Option<PathBuf> {
    let out = Command::new("brew")
        .args(["--prefix", formula])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(PathBuf::from(s))
    }
}
