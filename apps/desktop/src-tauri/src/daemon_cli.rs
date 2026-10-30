//! #1045：壳调内置 daemon 的**一次性子命令**（`diag export` / `--version --json`），
//! 以及 #1115 首启时一次性拉起内置 daemon 接 IPC `config.set_library`（[`with_oneshot_daemon`]）。
//!
//! 依赖倒置（里程碑 #9）：config.toml 与诊断包的写者只有 daemon（#1042），壳只做
//! 「选好参数 → 起一个短进程 → 把结果原样交给前端」。壳里不再有 config 模板、换库
//! 校验、脱敏规则这些业务——它们改一处就是 daemon 一处，不会再有两份拷贝漂移
//! （DESK-27 / DESK-40 / DESK-46 都是两份拷贝漂移出的事故）。
//!
//! 契约（daemon `--help` 与 `crates/daemon/tests/{config_cli,diag_cli,cli_flow}.rs`
//! 钉住）：
//! - 成功 exit 0，stdout 一行 JSON；
//! - 操作失败 exit 1，stderr 一行错误——校验类就是 [`crate::ipc::ui_err`] 同款
//!   keyed JSON，可原样交给前端 `errText`；
//! - 用法错误 exit 2（壳传参写错了，属于壳的 bug，不是用户能处理的错）。
//!
//! 结构沿用壳一贯的做法：**起进程**（[`run`]）与**判据**（`*_reply`）分开，判据是
//! 纯函数，不起真 daemon 也能单测；CI 上 `binaries/` 里是 0 字节 stub，起真进程的
//! 测试只在有真产物的机器上跑。

use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::ipc::ui_err;

/// `--version --json` 里的产品标识，与 daemon `cli::VERSION_PRODUCT` 同值。
/// 壳据此确认「这确实是我们的 daemon」，取代旧的纯文本前缀字面量匹配。
pub(crate) const DAEMON_PRODUCT: &str = "P-Pass daemon";

/// 版本探活的上限。`--version` 在任何机器上都是毫秒级的事；给到 5 秒是为了
/// 「坏掉但仍能被 CreateProcess 接受」的文件——那种可能直接挂住，而向导不能跟着
/// 一起卡死。
pub(crate) const PROBE_TIMEOUT: Duration = Duration::from_secs(5);

/// #1115：首启时没有 daemon 在跑，壳一次性拉起内置 daemon 来接 `config.set_library`。
/// 这是「起进程 + 答上 IPC」的上限；写库本身走 IPC 自己的读超时。
pub(crate) const ONESHOT_START_TIMEOUT: Duration = Duration::from_secs(10);

/// 诊断包的上限：daemon 在线时它要等 IPC（单次 10s 保险丝）再打包。
pub(crate) const DIAG_TIMEOUT: Duration = Duration::from_secs(60);

/// 子进程的结局。`code` 为 `None` = 被信号杀掉。
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Reply {
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

/// 起子进程、等它退出（带上限）、收 stdout / stderr。
///
/// 起不来 / 等不到是 `Err`（keyed）；退出码不是 0 **不是** `Err`——那是判据
/// （`*_reply`）的事，调用方才知道哪个退出码是什么意思。
/// 超时返回 `Ok(None)`：「没有结局」与「有结局但是失败」是两件事。
pub(crate) fn run(mut cmd: Command, timeout: Duration) -> Result<Option<Reply>, String> {
    let program = cmd.get_program().to_string_lossy().into_owned();
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        // 0 字节文件就死在这一步：CreateProcess 直接拒绝（Windows 错误 193）。
        .map_err(|e| ui_err("ui.err_sidecar_spawn", &[("err", &e), ("path", &program)]))?;
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Ok(None);
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(e) => return Err(unexpected(Unexpected::Wait, &e.to_string(), "")),
        }
    }
    // 已经退出，立即返回。子命令的输出都是一行，塞不满管道。
    let out = child
        .wait_with_output()
        .map_err(|e| ui_err("ui.err_sidecar_read", &[("err", &e)]))?;
    Ok(Some(Reply {
        code: out.status.code(),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    }))
}

/// 子进程没按契约收场的几种情形（10-30 偏离 3）。每种对用户的出路不同，各有一条文案；
/// 原始现象（退出码、stderr 末行、status）放进 `err` 参数——界面不渲染它，前端
/// `errMessage` 把整条 keyed 错误写进 console，对照「错误代码」查日志。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Unexpected {
    /// 等待 / 收子进程时系统调用出错：偶发，再试一次。
    Wait,
    /// 退出码 2（用法错误）或回答不合契约：壳与 daemon 版本不一致，重新安装。
    Args,
    /// 0 / 1 / 2 以外的退出码（如 panic 的 101）：程序跑起来就带错退出，同 `--version` 的
    /// `ui.err_sidecar_exit_code`，重新安装。
    ExitCode,
    /// 被信号杀掉：多半是安全软件或系统资源，再试一次。
    Killed,
    /// 一次性 daemon 还没答上 IPC 就退出了：再试一次。
    ExitedEarly,
    /// 一次性 daemon 在 [`ONESHOT_START_TIMEOUT`] 内没答上 IPC：再试一次。
    NoAnswer,
}

impl Unexpected {
    fn key(self) -> &'static str {
        match self {
            Unexpected::Wait => "ui.err_sidecar_wait",
            Unexpected::Args => "ui.err_sidecar_args",
            Unexpected::ExitCode => "ui.err_sidecar_exit_code",
            Unexpected::Killed => "ui.err_sidecar_killed",
            Unexpected::ExitedEarly => "ui.err_sidecar_exited_early",
            Unexpected::NoAnswer => "ui.err_sidecar_no_answer",
        }
    }
}

fn unexpected(cause: Unexpected, what: &str, stderr: &str) -> String {
    let last = stderr.lines().rev().find(|l| !l.trim().is_empty());
    let detail = match last {
        Some(l) => format!("{what}: {}", l.trim()),
        None => what.to_string(),
    };
    ui_err(cause.key(), &[("err", &detail)])
}

/// exit 1 的 stderr 一行 = 失败原因，**原样**交出（校验类本身就是 keyed JSON，
/// 建库失败是 `"<库目录>: <io 错误>"`，与壳改调前返回的字符串一致）。
/// exit 1 以外一律是 [`unexpected`]。
fn failure(reply: Option<&Reply>) -> String {
    match reply {
        // 诊断包在上限内没打完：没有更具体的出路，按「等待时出错」请用户再试。
        None => unexpected(Unexpected::Wait, "timeout", ""),
        Some(r) => match r.code {
            Some(1) => {
                let line = r.stderr.trim();
                if line.is_empty() {
                    unexpected(Unexpected::Args, "exit 1 without a reason", "")
                } else {
                    line.to_string()
                }
            }
            Some(2) => unexpected(Unexpected::Args, "exit 2", &r.stderr),
            Some(code) => unexpected(Unexpected::ExitCode, &format!("exit {code}"), &r.stderr),
            None => unexpected(Unexpected::Killed, "killed by signal", &r.stderr),
        },
    }
}

/// `diag export` 的结局：成功 = exit 0 且 stdout 是 `{"zip":…,"daemon_reachable":bool}`，
/// 原样交给前端（形状与改调前壳自己返回的一致）。
pub(crate) fn diag_reply(reply: Option<&Reply>) -> Result<Value, String> {
    let r = match reply {
        Some(r) if r.code == Some(0) => r,
        other => return Err(failure(other)),
    };
    let v: Value = serde_json::from_str(r.stdout.trim()).map_err(|e| {
        unexpected(
            Unexpected::Args,
            &format!("bad diag reply ({e})"),
            &r.stdout,
        )
    })?;
    if v["zip"].is_string() && v["daemon_reachable"].is_boolean() {
        Ok(v)
    } else {
        Err(unexpected(
            Unexpected::Args,
            "diag reply is missing zip/daemon_reachable",
            &r.stdout,
        ))
    }
}

/// `--version --json` 的结局 → 版本号。
///
/// 判据（DESK-29 #268 的探活判据，换成机读契约）：exit 0、stdout 是 JSON、
/// `product` 是 [`DAEMON_PRODUCT`]、`version` 非空。只看退出码会把「别的程序」
/// 当成 daemon；**不**比对版本号本身（它随编译期的 `PPF_BUILD_VERSION` 变）。
pub(crate) fn version_reply(reply: Option<&Reply>) -> Result<String, String> {
    let Some(r) = reply else {
        return Err(ui_err("ui.err_sidecar_version_timeout", &[]));
    };
    let Some(code) = r.code else {
        return Err(ui_err("ui.err_sidecar_version_timeout", &[]));
    };
    if code != 0 {
        return Err(ui_err("ui.err_sidecar_exit_code", &[("code", &code)]));
    }
    let parsed: Option<Value> = serde_json::from_str(r.stdout.trim()).ok();
    let version = parsed
        .as_ref()
        .filter(|v| v["product"] == DAEMON_PRODUCT)
        .and_then(|v| v["version"].as_str())
        .filter(|v| !v.trim().is_empty());
    match version {
        Some(v) => Ok(v.trim().to_string()),
        None => Err(ui_err(
            "ui.err_sidecar_not_daemon",
            &[(
                "output",
                &r.stdout.trim().chars().take(120).collect::<String>(),
            )],
        )),
    }
}

// ── 对外入口 ──────────────────────────────────────────────────────────

/// 壳旁边那个内置 daemon 的路径；文件不存在报 `ui.err_sidecar_missing`。
pub(crate) fn bundled_sidecar() -> Result<std::path::PathBuf, String> {
    let sidecar = crate::bundled_daemon_path()?;
    if !sidecar.is_file() {
        return Err(ui_err(
            "ui.err_sidecar_missing",
            &[("path", &sidecar.display())],
        ));
    }
    Ok(sidecar)
}

/// #1115：一次性拉起内置 daemon（不经开机自启），等它在 IPC 上答话后把连接交给 `f`，
/// 做完收掉。未配置状态的 daemon 写好库位置后自己以 75 退出；仍在跑（已配置的平台）就请它
/// 交班（`daemon.step_down`），再不走才结束进程。
pub(crate) fn with_oneshot_daemon<T>(
    sidecar: &Path,
    f: impl FnOnce(&crate::ipc::DaemonHandle) -> Result<T, String>,
) -> Result<T, String> {
    let program = sidecar.display().to_string();
    let mut child = platform::command(sidecar)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| ui_err("ui.err_sidecar_spawn", &[("err", &e), ("path", &program)]))?;
    let deadline = Instant::now() + ONESHOT_START_TIMEOUT;
    let handle = loop {
        if let Ok(h) = crate::ipc::DaemonHandle::discover() {
            break Ok(h);
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                break Err(unexpected(
                    Unexpected::ExitedEarly,
                    &format!("daemon exited early ({status})"),
                    "",
                ));
            }
            Ok(None) if Instant::now() >= deadline => {
                break Err(unexpected(
                    Unexpected::NoAnswer,
                    "daemon did not answer on IPC in time",
                    "",
                ));
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(100)),
            Err(e) => break Err(unexpected(Unexpected::Wait, &e.to_string(), "")),
        }
    };
    let out = handle.and_then(|h| {
        let out = f(&h);
        if !exited_within(&mut child, Duration::from_secs(2)) {
            let _ = h.call("daemon.step_down", serde_json::json!({}));
        }
        out
    });
    if !exited_within(&mut child, Duration::from_secs(3)) {
        let _ = child.kill();
        let _ = child.wait();
    }
    out
}

fn exited_within(child: &mut std::process::Child, limit: Duration) -> bool {
    let deadline = Instant::now() + limit;
    loop {
        match child.try_wait() {
            Ok(Some(_)) | Err(_) => return true,
            Ok(None) if Instant::now() >= deadline => return false,
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
        }
    }
}

/// `diag export --out <zip> --app-version <v>`：组装并脱敏诊断包。
pub(crate) fn diag_export(sidecar: &Path, zip: &Path, app_version: &str) -> Result<Value, String> {
    let mut cmd = platform::command(sidecar);
    cmd.arg("diag")
        .arg("export")
        .arg("--out")
        .arg(zip)
        .args(["--app-version", app_version]);
    diag_reply(run(cmd, DIAG_TIMEOUT)?.as_ref())
}

/// `--version --json`：内置 daemon 自报的版本号，同时是「这确实能跑、确实是
/// 我们的 daemon」的探活。
pub(crate) fn probe_version(sidecar: &Path) -> Result<String, String> {
    let mut cmd = platform::command(sidecar);
    cmd.args(["--version", "--json"]);
    version_reply(run(cmd, PROBE_TIMEOUT)?.as_ref())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reply(code: Option<i32>, stdout: &str, stderr: &str) -> Option<Reply> {
        Some(Reply {
            code,
            stdout: stdout.into(),
            stderr: stderr.into(),
        })
    }

    #[test]
    fn diag_reply_is_forwarded_unchanged_and_checked() {
        let ok = "{\"zip\":\"/lib/ppf-logs.zip\",\"daemon_reachable\":false}\n";
        let v = diag_reply(reply(Some(0), ok, "").as_ref()).unwrap();
        assert_eq!(v["zip"], "/lib/ppf-logs.zip");
        assert_eq!(v["daemon_reachable"], false);
        for bad in [
            reply(Some(0), "{\"zip\":\"/x\"}", ""),
            reply(Some(0), "", ""),
            reply(Some(1), "", "写不出 zip\n"),
        ] {
            assert!(diag_reply(bad.as_ref()).is_err(), "{bad:?}");
        }
        assert_eq!(
            diag_reply(reply(Some(1), "", "写不出 zip\n").as_ref()),
            Err("写不出 zip".to_string())
        );
    }

    fn key_of(e: &str) -> String {
        serde_json::from_str::<Value>(e).unwrap()["key"]
            .as_str()
            .unwrap()
            .to_string()
    }

    /// 偏离 3（10-30）：没按契约收场的每种情形各走一条文案，出路不同（重新安装 /
    /// 再试一次）；原始现象只在 `err` 参数里（界面不渲染，前端写进 console）。
    /// 反证：把任一分支并回 `ui.err_sidecar_wait` ⇒ 红。
    #[test]
    fn unexpected_endings_each_get_their_own_key() {
        let cases = [
            (None, "ui.err_sidecar_wait"),
            (
                reply(Some(2), "", "error: unexpected argument\n"),
                "ui.err_sidecar_args",
            ),
            (reply(Some(1), "", ""), "ui.err_sidecar_args"),
            (reply(Some(0), "not json", ""), "ui.err_sidecar_args"),
            (
                reply(Some(0), "{\"zip\":\"/x\"}", ""),
                "ui.err_sidecar_args",
            ),
            (
                reply(Some(101), "", "panicked\n"),
                "ui.err_sidecar_exit_code",
            ),
            (reply(None, "", "SIGKILL\n"), "ui.err_sidecar_killed"),
        ];
        for (r, key) in cases {
            let e = diag_reply(r.as_ref()).unwrap_err();
            assert_eq!(key_of(&e), key, "{r:?} -> {e}");
        }
        let e =
            diag_reply(reply(Some(2), "", "error: unexpected argument\n").as_ref()).unwrap_err();
        let v: Value = serde_json::from_str(&e).unwrap();
        assert_eq!(v["params"]["err"], "exit 2: error: unexpected argument");

        // 一次性 daemon 的两种结局（起真进程才走得到，这里钉住映射）。
        assert_eq!(
            key_of(&unexpected(
                Unexpected::ExitedEarly,
                "daemon exited early (exit status: 75)",
                ""
            )),
            "ui.err_sidecar_exited_early"
        );
        assert_eq!(
            key_of(&unexpected(
                Unexpected::NoAnswer,
                "daemon did not answer on IPC in time",
                ""
            )),
            "ui.err_sidecar_no_answer"
        );
    }

    /// DESK-29 的探活判据（换成 `--version --json`）：什么才算通过。判据一松
    /// （比如只看退出码）这几条必须红。
    #[test]
    fn version_probe_passes_only_on_exit_zero_with_our_product() {
        let ok = "{\"product\":\"P-Pass daemon\",\"schema\":1,\"version\":\"0.9.7\"}\n";
        assert_eq!(
            version_reply(reply(Some(0), ok, "").as_ref()),
            Ok("0.9.7".to_string())
        );
        // 别的程序：退出 0 但不是我们的 daemon。
        for other in [
            "hello\n",
            "",
            "{\"product\":\"other\",\"version\":\"1\"}",
            "{\"product\":\"P-Pass daemon\"}",
            "{\"product\":\"P-Pass daemon\",\"version\":\"\"}",
            "P-Pass daemon 0.9.7\n", // 旧的纯文本形状不再是契约
        ] {
            let e = version_reply(reply(Some(0), other, "").as_ref()).unwrap_err();
            assert!(e.contains("ui.err_sidecar_not_daemon"), "{other:?} -> {e}");
        }
        assert!(version_reply(reply(Some(2), ok, "").as_ref())
            .unwrap_err()
            .contains("ui.err_sidecar_exit_code"));
        for none in [reply(None, "", ""), None] {
            assert!(version_reply(none.as_ref())
                .unwrap_err()
                .contains("ui.err_sidecar_version_timeout"));
        }
    }

    // ── 真 daemon（只在本机有非空产物时跑；CI 的 binaries/ 是 0 字节 stub）──

    fn real_daemon() -> Option<std::path::PathBuf> {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"));
        [
            "binaries/ppf-daemon-x86_64-pc-windows-msvc.exe",
            "binaries/ppf-daemon-x86_64-unknown-linux-gnu",
            "binaries/ppf-daemon-aarch64-apple-darwin",
            "target/debug/ppf-daemon.exe",
            "target/debug/ppf-daemon",
            "target/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon",
        ]
        .iter()
        .map(|p| root.join(p))
        .find(|p| {
            std::fs::metadata(p)
                .map(|m| m.is_file() && m.len() > 0)
                .unwrap_or(false)
        })
    }

    /// 把所有平台的数据目录来源都指进 `home`——绝不碰本机真实的 P-Pass 数据。
    fn sandboxed(sidecar: &Path, home: &Path) -> Command {
        let mut c = platform::command(sidecar);
        c.env("HOME", home)
            .env("USERPROFILE", home)
            .env("XDG_DATA_HOME", home.join("xdg"))
            .env("APPDATA", home.join("roaming"))
            .env("LOCALAPPDATA", home.join("local"))
            .env_remove("PPF_DATA_DIR")
            .env_remove("PPF_LOG_FILE");
        c
    }

    /// 取不到真产物时绝不静默变绿：把原因打出来。
    fn real_or_skip(test: &str) -> Option<std::path::PathBuf> {
        let r = real_daemon();
        if r.is_none() {
            eprintln!("⚠️ 跳过 {test}：本机找不到非空 daemon 产物（CI 上是 0 字节 stub）");
        }
        r
    }

    #[test]
    fn real_daemon_reports_its_version_as_json() {
        let Some(d) = real_or_skip("real_daemon_reports_its_version_as_json") else {
            return;
        };
        let v = probe_version(&d).unwrap_or_else(|e| panic!("真 daemon 被判成坏的：{e}"));
        assert!(!v.is_empty());
    }

    /// #1115 反证：daemon 的 config CLI 写入口已删——真 daemon 拒绝它，且什么都不写。
    /// 库位置唯一的写法是 IPC `config.set_library`（只对签名窗口程序开放）。
    #[test]
    fn real_daemon_rejects_the_removed_config_cli() {
        let Some(d) = real_or_skip("real_daemon_rejects_the_removed_config_cli") else {
            return;
        };
        let home = tempfile::tempdir().unwrap();
        let lib = home.path().join("Lib A");
        for args in [
            vec!["config", "init", "--library", lib.to_str().unwrap()],
            vec!["config", "set-library", lib.to_str().unwrap()],
        ] {
            let mut c = sandboxed(&d, home.path());
            c.args(&args);
            let r = run(c, PROBE_TIMEOUT).unwrap().expect("不该超时");
            assert_eq!(r.code, Some(2), "{args:?} → {r:?}");
            assert!(r.stderr.contains("config 子命令已删除"), "{r:?}");
        }
        assert!(!lib.exists(), "被拒的命令不许建库目录");
        let written: Vec<_> = walk(home.path());
        assert!(written.is_empty(), "被拒的命令不许写任何文件：{written:?}");
    }

    fn walk(dir: &Path) -> Vec<std::path::PathBuf> {
        let mut out = Vec::new();
        for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
            let p = e.path();
            if p.is_dir() {
                out.extend(walk(&p));
            } else {
                out.push(p);
            }
        }
        out
    }

    /// 诊断包：daemon 不在线也出包，且结果形状就是前端读的那两个字段。
    #[test]
    fn real_daemon_exports_a_diag_bundle_when_the_service_is_offline() {
        let Some(d) = real_or_skip("real_daemon_exports_a_diag_bundle_when_the_service_is_offline")
        else {
            return;
        };
        // #1167：服务形态的管道整台机器一份，沙箱隔离不掉；机器上真有服务在线就不是离线场景。
        if crate::ipc::DaemonHandle::discover().is_ok() {
            eprintln!("跳过：这台机器上真有常驻 P-Pass 服务在线，不是本测试的离线场景");
            return;
        }
        let home = tempfile::tempdir().unwrap();
        let zip = home.path().join("out").join("ppf-logs.zip");
        let mut c = sandboxed(&d, home.path());
        c.arg("diag")
            .arg("export")
            .arg("--out")
            .arg(&zip)
            .args(["--app-version", "9.9.9-test"]);
        let r = run(c, DIAG_TIMEOUT).unwrap().expect("不该超时");
        let v = diag_reply(Some(&r)).unwrap_or_else(|e| panic!("{e}\n{r:?}"));
        assert_eq!(v["daemon_reachable"], false, "沙箱里没有在线服务");
        assert!(zip.is_file(), "zip 必须落在 --out 指定的位置");
    }
}
