//! #881：首启链路跨组件集成测试——空平台目录 → 向导写首启配置 → 拉起 daemon。
//!
//! 之前向导测试把后端全 mock、daemon 测试只测纯函数，两侧之间「先建库目录、
//! 再写配置」→「daemon 只认存在的库（DESK-46）」这条契约没人串起来验。
//! 这里在临时目录里走完整条链路：`PPF_PLATFORM_DIR` 只把 daemon 的 config
//! 指到临时目录（库位置仍来自 config.toml，DESK-46 照查），且 store 传 None——
//! 不读真实钥匙串/正本，identity / 库 ID / 单实例 claim 全落在注入的临时目录里，
//! 不碰本机真实数据。
//!
//! macOS 上这条测试跳过（见测试上的 `#[cfg_attr(target_os = "macos", ignore = …)]`）：
//! cargo 构建的 daemon 是 ad-hoc 签名，读真钥匙串必 -34018，resident_ipc 用本机真实
//! 数据目录里的 socket、identity 也走真目录，无法无头走通首启；平台行为由 CI 的
//! `-p platform` 测试覆盖（先例 #1523/#1295）。Windows / Linux 照跑。

#![allow(clippy::disallowed_methods)]

use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

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

// macOS 上跳过：cargo 构建的 daemon 是 ad-hoc 签名、读真钥匙串必 -34018，resident_ipc
// 用本机真实数据目录里的 socket，identity 也走真目录，无法无头走通首启；平台行为由
// CI 的 `-p platform` 测试覆盖（先例 #1523/#1295）。Windows / Linux 照跑。
#[cfg_attr(
    target_os = "macos",
    ignore = "ad-hoc 签名读真钥匙串必 -34018，resident_ipc 用真数据目录，无头走不通；macOS 由 CI -p platform 覆盖"
)]
#[test]
fn first_run_chain_writes_config_then_the_daemon_reaches_ipc() {
    let root = tempfile::tempdir().unwrap();
    let platform_dir = root.path().join("platform");
    let library_dir = root.path().join("library");

    // 1) 向导写首启配置第一步：init_config（建库目录 + 写 config.toml）——与
    //    LibraryLocation::set 的首启分支同源（IPC config.set_library 的本体）。
    let cfg_path =
        daemon::config::init_config(&platform_dir, library_dir.to_str().unwrap()).unwrap();
    // 反证：把 init_config 里的 `create_dir_all(library_dir)` 去掉 → 库目录没建 →
    // 下面这条「库目录被建出」立即变红（在 ensure_library_id 写库标记/库 ID、顺带
    // create_dir_all(.ppf) 补建库目录之前就断言，不会被补建掩盖）。
    assert!(library_dir.is_dir(), "首启写配置必须建出库目录");
    assert_eq!(cfg_path, platform_dir.join("config.toml"));

    // 2) 首启其余两步（= LibraryLocation::set 在 init_config 之后做的）：写库标记 .ppf
    //    + 生成并记库 ID（ensure_library_id 写 .ppf/library-id 会顺带建出 .ppf 标记）。
    let id = daemon::layout::ensure_library_id(&library_dir).unwrap();
    daemon::layout::record_library_id(&platform_dir, &id).unwrap();

    // 3) 拉起 daemon（注入平台目录），断言可达：走过了库目录检查、进入了 IPC 搭建。
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
