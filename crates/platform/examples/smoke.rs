//! T-040 人工验收剧本 (`just platform-smoke`):
//! 自启注册→查询→注销；防睡眠断言可见→释放后消失。
//! Exits non-zero on any failed step. H-09 runs this on both platforms.

// DESK-33 (#325)：这是开发者手动 / 测试框架跑的冒烟 example，不是产品进程，
// clippy.toml 的「禁止直接 Command::new」不适用。
#![allow(clippy::disallowed_methods)]

#[cfg(not(any(target_os = "macos", windows)))]
fn main() {
    eprintln!("platform smoke is only meaningful on macOS/Windows");
}

#[cfg(any(target_os = "macos", windows))]
use platform::{HostingAdapter, PlatformAdapter};

#[cfg(any(target_os = "macos", windows))]
fn main() {
    let a = platform::adapter();
    let h = platform::hosting();
    let mut failures = 0;

    println!("── service_mode: {:?}", h.service_mode());
    println!("── data_dir: {}", a.data_dir().display());
    // power_hint 只有 macOS 实现（Windows 向导不展示睡眠策略，#1041 起默认 Unknown）。
    #[cfg(target_os = "macos")]
    match a.power_hint() {
        platform::PowerHint::Unknown => {
            println!("✗ power_hint: Unknown（解析失败？）");
            failures += 1;
        }
        hint => println!("✓ power_hint: {hint:?}"),
    }

    // Autostart lifecycle (uses /usr/bin/true as a harmless target).
    let target = if cfg!(windows) {
        std::path::PathBuf::from("C:\\Windows\\System32\\cmd.exe")
    } else {
        std::path::PathBuf::from("/usr/bin/true")
    };
    match h.install_autostart(&target) {
        Ok(()) => match h.autostart_installed() {
            Ok(true) => {
                println!("✓ autostart: 注册并查询到");
                match h.uninstall_autostart() {
                    Ok(()) if !h.autostart_installed().unwrap_or(true) => {
                        println!("✓ autostart: 注销干净")
                    }
                    _ => {
                        println!("✗ autostart: 注销失败或残留");
                        failures += 1;
                    }
                }
            }
            _ => {
                println!("✗ autostart: 注册后查询不到");
                failures += 1;
            }
        },
        Err(e) => {
            println!("✗ autostart 注册失败: {e}");
            failures += 1;
        }
    }

    // Awake guard: assertion count rises while held, falls after drop
    // (count-based — the box may have unrelated caffeinate processes).
    let before = awake_assertion_count();
    match a.assert_awake() {
        Ok(guard) => {
            std::thread::sleep(std::time::Duration::from_millis(600));
            let held = awake_assertion_count();
            drop(guard);
            std::thread::sleep(std::time::Duration::from_millis(600));
            let after = awake_assertion_count();
            // #1056 真机：Windows 没有**免管理员**的「当前断言计数」接口——
            // `powercfg /requests` 要提升权限，旧实现只好返回常量 1，于是
            // `held > before` 永远不成立、这条冒烟在 Windows 上结构性必红。
            // 这里只验 guard 能拿到并释放（`assert_awake` 失败会走 Err 分支）；
            // OS 级断言是否存在由 H-09 在管理员提示符下人工核对。
            if cfg!(windows) {
                println!(
                    "✓ awake guard: 获取/释放成功（计数 {before}→{held}→{after}；Windows 无免管理员计数接口，OS 级断言见 H-09 手工）"
                );
            } else if held > before && after <= before {
                println!("✓ awake guard: 断言计数 {before}→{held}→{after}");
            } else {
                println!("✗ awake guard: 计数 {before}→{held}→{after}");
                failures += 1;
            }
        }
        Err(e) => {
            println!("✗ assert_awake: {e}");
            failures += 1;
        }
    }

    if failures == 0 {
        println!("PLATFORM SMOKE: ALL GREEN");
    } else {
        println!("PLATFORM SMOKE: {failures} FAILURES");
        std::process::exit(1);
    }
}

/// How many of our-style awake assertions the OS reports right now.
#[cfg(any(target_os = "macos", windows))]
fn awake_assertion_count() -> usize {
    if cfg!(target_os = "macos") {
        let out = std::process::Command::new("pmset")
            .args(["-g", "assertions"])
            .output();
        match out {
            Ok(o) => String::from_utf8_lossy(&o.stdout)
                .lines()
                .filter(|l| l.contains("caffeinate"))
                .count(),
            Err(_) => 0,
        }
    } else if cfg!(windows) {
        // powercfg /requests needs admin on some setups; H-09 verifies
        // manually. Keep the script useful with a neutral constant.
        1
    } else {
        0
    }
}
