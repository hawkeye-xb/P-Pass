//! #881：首启链路跨组件集成测试——空平台目录 → 向导写首启配置 → 拉起 daemon。
//!
//! 之前向导测试把后端全 mock、daemon 测试只测纯函数，两侧之间「先建库目录、
//! 再写配置」→「daemon 只认存在的库（DESK-46）」这条契约没人串起来验。
//! 这里在临时目录里走完整条链路：`PPF_PLATFORM_DIR` 只把 daemon 的 config
//! 指到临时目录（库位置仍来自 config.toml，DESK-46 照查），且 store 传 None——
//! 不读真实钥匙串/正本，identity / 库 ID / 单实例 claim 全落在注入的临时目录里，
//! 不碰本机真实数据。

#![allow(clippy::disallowed_methods)]

use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use daemon::library_location::LibraryLocation;

fn daemon_bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_daemon"))
}

/// 起一个真的前台常驻 daemon（注入平台目录、随机端口、不连 relay），
/// 轮询 stderr，直到出现「IPC:」或「找不到照片库」或超时，然后杀掉，返回收集到的 stderr。
/// 不用固定 sleep——慢速 CI 上可能在固定窗口内还没走到 IPC 日志。
fn run_resident_for(platform_dir: &Path, timeout: Duration) -> String {
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
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    let reader = std::thread::spawn(move || {
        for line in BufReader::new(stderr_pipe).lines() {
            let Ok(line) = line else { break };
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    let mut stderr = String::new();
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        match rx.recv_timeout(Duration::from_millis(200)) {
            Ok(line) => {
                stderr.push_str(&line);
                stderr.push('\n');
                if line.contains("IPC:") || line.contains("找不到照片库") {
                    break;
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    let _ = reader.join();
    stderr
}

#[test]
fn first_run_chain_writes_config_then_the_daemon_reaches_ipc() {
    let root = tempfile::tempdir().unwrap();
    let platform_dir = root.path().join("platform");
    let library_dir = root.path().join("library");

    // 1) 向导写首启配置：走真正的唯一写者 LibraryLocation::set（IPC config.set_library 的本体，
    //    首启 = 建库目录 + 写 config.toml + 建 .ppf + 生成并记库 ID）。
    let cfg_path = LibraryLocation::with(None, platform_dir.clone())
        .set(library_dir.to_str().unwrap())
        .unwrap();
    // 反证：把 init_config 里的 `create_dir_all(library_dir)` 去掉 → 库目录没建 →
    // 下面这条「库目录被建出」变红；daemon 侧也会报「找不到照片库」（DESK-46）。
    assert!(library_dir.is_dir(), "首启写配置必须建出库目录");
    assert_eq!(cfg_path, platform_dir.join("config.toml"));

    // 2) 拉起 daemon（注入平台目录），断言可达：走过了库目录检查、进入了 IPC 搭建。
    //    注：单实例 claim 在本机有真服务时会 StandDown（正确行为，非测试失败），所以
    //    「可达」只以「IPC: 这一行已打印（库目录检查通过）」为判据；bind 失败已用随机端口避开。
    let stderr = run_resident_for(&platform_dir, Duration::from_secs(20));
    assert!(
        stderr.contains("IPC:"),
        "首启写配置后 daemon 应走到 IPC 搭建（库目录检查通过），stderr:\n{stderr}"
    );
    assert!(
        !stderr.contains("找不到照片库"),
        "库目录已建出，daemon 不该报「找不到照片库」，stderr:\n{stderr}"
    );
}
