//! #881：首启链路跨组件集成测试——空平台目录 → 向导写首启配置 → 拉起 daemon。
//!
//! 之前向导测试把后端全 mock、daemon 测试只测纯函数，两侧之间「先建库目录、
//! 再写配置」→「daemon 只认存在的库（DESK-46）」这条契约没人串起来验。
//! 这里在临时目录里走完整条链路：`PPF_PLATFORM_DIR` 只把 daemon 的 config
//! 指到临时目录（库位置仍来自 config.toml，DESK-46 照查），其余都用本机默认。
//! 三平台通用：identity / 库 ID / 单实例 claim 全落在注入的临时目录里，不碰本机
//! 真实数据。

#![allow(clippy::disallowed_methods)]

use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

fn daemon_bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_daemon"))
}

/// 起一个真的前台常驻 daemon（注入平台目录、随机端口、不连 relay），
/// 跑 `dur` 后杀掉，返回这期间收集到的 stderr。
fn run_resident_for(platform_dir: &Path, dur: Duration) -> String {
    let mut child = daemon_bin()
        .env("PPF_PLATFORM_DIR", platform_dir)
        .env("PPF_BIND_ADDR", "127.0.0.1:0")
        .env("PPF_RELAY_URLS", "")
        .env_remove("PPF_DATA_DIR")
        .env_remove("PPF_LOG_FILE")
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn daemon");
    let stderr_pipe = child.stderr.take().expect("stderr piped");
    let reader = std::thread::spawn(move || {
        let mut s = String::new();
        for line in BufReader::new(stderr_pipe).lines() {
            let Ok(line) = line else { break };
            s.push_str(&line);
            s.push('\n');
        }
        s
    });
    std::thread::sleep(dur);
    let _ = child.kill();
    let _ = child.wait();
    reader.join().expect("stderr reader")
}

#[test]
fn first_run_chain_writes_config_then_the_daemon_reaches_ipc() {
    let root = tempfile::tempdir().unwrap();
    let platform_dir = root.path().join("platform");
    let library_dir = root.path().join("library");

    // 1) 向导写首启配置：先建库目录、再写 config.toml（config 的唯一写者）。
    let cfg_path =
        daemon::config::init_config(&platform_dir, library_dir.to_str().unwrap()).unwrap();
    // 反证：把 init_config 里的 `create_dir_all(library_dir)` 去掉 → 库目录没建 →
    // 下面这条「库目录被建出」变红；daemon 侧也会报「找不到照片库」（DESK-46）。
    assert!(library_dir.is_dir(), "首启写配置必须建出库目录");
    assert_eq!(cfg_path, platform_dir.join("config.toml"));

    // 2) 补齐库标记与库 ID（LibraryLocation::set 的其余两步；启动「库在不在」只认 .ppf）。
    let id = daemon::layout::ensure_library_id(&library_dir).unwrap();
    daemon::layout::record_library_id(&platform_dir, &id).unwrap();

    // 3) 拉起 daemon（注入平台目录），断言可达：走过了库目录检查、进入了 IPC 搭建。
    let stderr = run_resident_for(&platform_dir, Duration::from_secs(8));
    assert!(
        stderr.contains("IPC:"),
        "首启写配置后 daemon 应走到 IPC 搭建（库目录检查通过），stderr:\n{stderr}"
    );
    assert!(
        !stderr.contains("找不到照片库"),
        "库目录已建出，daemon 不该报「找不到照片库」，stderr:\n{stderr}"
    );
}
