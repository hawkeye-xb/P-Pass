//! 视频 decoder 子进程的生命周期：超时强杀与内存上限（证明视频路径受同一
//! watchdog / Job 约束，不是静态图测试冒充）。
//!
//! 子进程就是本测试二进制自己（`PPF_VIDEO_LIMITS_CHILD` 环境变量分流），所以
//! `harness = false`。受控假 worker：child 读掉请求后要么挂住（超时用例）、要么
//! 尝试分配 128MB——分配被 Job 上限拒绝时回一个合法 `Failed` 应答（msg 里带
//! `alloc rejected`），证明它确实走到了分配那一步、而非启动期就死掉。
//!
//! 本文件不写 `#[cfg]`（B.2）：非 Windows 端经 `platform::video_decode::
//! video_decode_available()` 运行时跳过。

#![allow(clippy::disallowed_methods)]

use std::io::Read;
use std::time::{Duration, Instant};

use decode_worker::proto::{self, Response, STATUS_DECODE_FAILED};
use media_codec::{decode_video_with_limits, decode_video_within, CodecError};

const CHILD_ENV: &str = "PPF_VIDEO_LIMITS_CHILD";

fn child() {
    // 读掉请求（header + payload），等 daemon 关写端拿到 EOF。
    let mut buf = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut buf);
    match std::env::var(CHILD_ENV).as_deref() {
        // 内存用例：分配 128MB。Job 上限更小时这里失败，回合法 Failed 应答后退出
        // （证明走到了分配这一步）；成功则挂住等 watchdog。
        Ok("alloc") => {
            let mut v: Vec<u8> = Vec::new();
            match v.try_reserve_exact(128 << 20) {
                Ok(()) => {
                    v.resize(128 << 20, 1);
                    std::thread::sleep(Duration::from_secs(60));
                }
                Err(_) => {
                    let mut so = std::io::stdout().lock();
                    let _ = proto::write_response(
                        &mut so,
                        &Response::Failed {
                            status: STATUS_DECODE_FAILED,
                            msg: "alloc rejected".into(),
                        },
                    );
                    std::process::exit(3);
                }
            }
        }
        _ => {
            // 超时用例：挂住，等 watchdog 强杀。睡 2s——比测试时限（500ms）长、比
            // 反证的时限（放大后 >2s）短：反证时 worker 自己退出，报「没应答」而不是
            // 「timed out」，测试红。
            std::thread::sleep(Duration::from_secs(2));
        }
    }
}

fn fixture() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join("tiny.mp4")
}

fn with_worker<T>(mode: &str, f: impl FnOnce() -> T) -> T {
    std::env::set_var(CHILD_ENV, mode);
    std::env::set_var("PPF_VIDEO_DECODE_WORKER", std::env::current_exe().unwrap());
    let out = f();
    std::env::remove_var(CHILD_ENV);
    std::env::remove_var("PPF_VIDEO_DECODE_WORKER");
    out
}

fn parent() {
    // 前置：AppContainer（0 capability）默认读不到 deps/ 里的测试二进制，授读+执行。
    let exe = std::env::current_exe().unwrap();
    let dir = exe.parent().unwrap();
    let ok = std::process::Command::new("icacls")
        .arg(dir)
        .args(["/grant", "*S-1-15-2-1:(OI)(CI)(RX)", "/T", "/C", "/Q"])
        .status()
        .unwrap()
        .success();
    assert!(ok, "icacls 授权失败");

    // 超时：挂住的 worker 在 500ms 时限内被 watchdog 强杀。
    let t = Instant::now();
    let err = with_worker("hang", || {
        decode_video_within(&fixture(), Duration::from_millis(500)).unwrap_err()
    });
    assert!(t.elapsed() < Duration::from_secs(10), "没有按时强杀");
    assert!(err.to_string().contains("timed out"), "{err}");

    // 内存：worker 想分配 128MB，但 Job 上限只有 64MB → 分配被拒，回带
    // `alloc rejected` 的应答（证明走到了分配那一步，而非启动期死亡）。
    let err = with_worker("alloc", || {
        decode_video_with_limits(&fixture(), Duration::from_secs(10), 64 << 20).unwrap_err()
    });
    assert!(
        err.to_string().contains("alloc rejected"),
        "内存上限没生效（子进程没走到分配即死、或分配被放行）: {err}"
    );
    assert!(matches!(err, CodecError::Decode { .. }), "{err:?}");

    println!("video_limits: timeout kill + memory limit ok");
}

fn main() {
    // 自定义 harness 也要会答 libtest 的 `--list`（nextest 建测试清单时调用）。
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--list") {
        if !args.iter().any(|a| a == "--ignored") {
            println!("video_limits: test");
        }
        return;
    }
    if std::env::var_os(CHILD_ENV).is_some() {
        child();
    } else if platform::video_decode::video_decode_available() {
        parent();
    } else {
        eprintln!("本平台无视频解码能力，跳过");
    }
}
