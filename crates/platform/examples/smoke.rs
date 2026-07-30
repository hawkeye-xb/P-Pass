//! T-040 人工验收剧本 (`just platform-smoke`):
//! 自启注册→查询→注销；防睡眠断言可见→释放后消失；Keychain/DPAPI 往返。
//! Exits non-zero on any failed step. H-09 runs this on both platforms.

use platform::{PlatformAdapter, PowerHint};

fn main() {
    let a = platform::adapter();
    let mut failures = 0;

    println!("── service_mode: {:?}", a.service_mode());
    println!("── data_dir: {}", a.data_dir().display());
    match a.power_hint() {
        PowerHint::Unknown => {
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
    match a.install_autostart(&target) {
        Ok(()) => match a.autostart_installed() {
            Ok(true) => {
                println!("✓ autostart: 注册并查询到");
                match a.uninstall_autostart() {
                    Ok(()) if !a.autostart_installed().unwrap_or(true) => {
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
            if held > before && after <= before {
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

    // Key store round-trip.
    let ks = a.key_store();
    let secret = b"smoke-secret-42".to_vec();
    match ks
        .store("smoke-test", &secret)
        .and_then(|()| ks.load("smoke-test"))
    {
        Ok(Some(loaded)) if loaded == secret => {
            let _ = ks.delete("smoke-test");
            match ks.load("smoke-test") {
                Ok(None) => println!("✓ key store: 存取删全通"),
                _ => {
                    println!("✗ key store: 删除后仍可读");
                    failures += 1;
                }
            }
        }
        other => {
            println!("✗ key store 往返失败: {other:?}");
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
