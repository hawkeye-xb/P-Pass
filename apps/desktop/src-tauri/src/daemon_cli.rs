//! #1045：壳调内置 daemon 的**一次性子命令**（`config init` / `config set-library`
//! / `diag export` / `--version --json`）。
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

/// config 子命令的上限：建目录 + 写一个小文件，慢盘 / 网络盘留足余量。
const CONFIG_TIMEOUT: Duration = Duration::from_secs(30);

/// 诊断包的上限：daemon 在线时它要等 IPC（单次 10s 保险丝）再打包。
const DIAG_TIMEOUT: Duration = Duration::from_secs(60);

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
            Err(e) => return Err(ui_err("ui.err_sidecar_wait", &[("err", &e)])),
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

/// 壳传参错了（exit 2）、被信号杀掉、超时——都不是用户能处理的错，也没有
/// 面向用户的专用文案，如实带上现象交给 `ui.err_sidecar_wait` 渲染。
fn unexpected(what: &str, stderr: &str) -> String {
    let last = stderr.lines().rev().find(|l| !l.trim().is_empty());
    let detail = match last {
        Some(l) => format!("{what}: {}", l.trim()),
        None => what.to_string(),
    };
    ui_err("ui.err_sidecar_wait", &[("err", &detail)])
}

/// exit 1 的 stderr 一行 = 失败原因，**原样**交出（校验类本身就是 keyed JSON，
/// 建库失败是 `"<库目录>: <io 错误>"`，与壳改调前返回的字符串一致）。
/// exit 1 以外一律是 [`unexpected`]。
fn failure(reply: Option<&Reply>) -> String {
    match reply {
        None => unexpected("timeout", ""),
        Some(r) => match r.code {
            Some(1) => {
                let line = r.stderr.trim();
                if line.is_empty() {
                    unexpected("exit 1 without a reason", "")
                } else {
                    line.to_string()
                }
            }
            Some(code) => unexpected(&format!("exit {code}"), &r.stderr),
            None => unexpected("killed by signal", &r.stderr),
        },
    }
}

/// `config init` / `config set-library` 的结局：成功 = exit 0 且 stdout 是
/// `{"config":"<path>"}`。
pub(crate) fn config_reply(reply: Option<&Reply>) -> Result<(), String> {
    let r = match reply {
        Some(r) if r.code == Some(0) => r,
        other => return Err(failure(other)),
    };
    let v: Value = serde_json::from_str(r.stdout.trim())
        .map_err(|e| unexpected(&format!("bad config reply ({e})"), &r.stdout))?;
    match v["config"].as_str() {
        Some(_) => Ok(()),
        None => Err(unexpected("config reply has no path", &r.stdout)),
    }
}

/// `diag export` 的结局：成功 = exit 0 且 stdout 是 `{"zip":…,"daemon_reachable":bool}`，
/// 原样交给前端（形状与改调前壳自己返回的一致）。
pub(crate) fn diag_reply(reply: Option<&Reply>) -> Result<Value, String> {
    let r = match reply {
        Some(r) if r.code == Some(0) => r,
        other => return Err(failure(other)),
    };
    let v: Value = serde_json::from_str(r.stdout.trim())
        .map_err(|e| unexpected(&format!("bad diag reply ({e})"), &r.stdout))?;
    if v["zip"].is_string() && v["daemon_reachable"].is_boolean() {
        Ok(v)
    } else {
        Err(unexpected(
            "diag reply is missing zip/daemon_reachable",
            &r.stdout,
        ))
    }
}

/// `--version --json` 的结局 → 版本号。
///
/// 判据（DESK-29 #268 的探活判据，换成机读契约）：exit 0、stdout 是 JSON、
/// `product` 是 [`DAEMON_PRODUCT`]、`version` 非空。只看退出码会把「别的程序」
/// 当成 daemon；**不**比对版本号本身（版本还会被 `PPF_DAEMON_VERSION` 覆盖）。
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

/// `config init --library <dir>`：首启建库目录并写平台 config.toml。
pub(crate) fn config_init(sidecar: &Path, library_dir: &str) -> Result<(), String> {
    let mut cmd = platform::command(sidecar);
    cmd.args(["config", "init", "--library", library_dir]);
    config_reply(run(cmd, CONFIG_TIMEOUT)?.as_ref())
}

/// `config set-library <dir>`：换库（重启后台服务后生效）。
pub(crate) fn config_set_library(sidecar: &Path, library_dir: &str) -> Result<(), String> {
    let mut cmd = platform::command(sidecar);
    cmd.args(["config", "set-library", library_dir]);
    config_reply(run(cmd, CONFIG_TIMEOUT)?.as_ref())
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
    fn config_success_needs_exit_zero_and_a_path() {
        assert_eq!(
            config_reply(reply(Some(0), "{\"config\":\"/x/config.toml\"}\n", "").as_ref()),
            Ok(())
        );
        for bad in [
            reply(Some(0), "", ""),
            reply(Some(0), "not json", ""),
            reply(Some(0), "{\"zip\":\"/x\"}", ""),
        ] {
            assert!(config_reply(bad.as_ref()).is_err(), "{bad:?}");
        }
    }

    /// exit 1 的 stderr 一行原样交出：keyed JSON 能被前端 errText 直接渲染。
    #[test]
    fn exit_one_hands_the_daemons_error_through_verbatim() {
        let keyed = ui_err("ui.err_library_nested", &[]);
        assert_eq!(
            config_reply(reply(Some(1), "", &format!("{keyed}\n")).as_ref()),
            Err(keyed)
        );
        assert_eq!(
            config_reply(reply(Some(1), "", "/lib: Permission denied (os error 13)\n").as_ref()),
            Err("/lib: Permission denied (os error 13)".to_string())
        );
    }

    /// 用法错误 / 被信号杀 / 超时是壳的 bug 或环境问题，不能被当成用户的校验
    /// 失败；它们统一落成 keyed 错误并带上现象。
    #[test]
    fn usage_errors_signals_and_timeouts_are_not_user_errors() {
        for bad in [
            reply(Some(2), "", "未知参数：--x\n"),
            reply(None, "", ""),
            reply(Some(1), "", ""),
            None,
        ] {
            let e = config_reply(bad.as_ref()).unwrap_err();
            let v: Value = serde_json::from_str(&e).expect("keyed JSON");
            assert_eq!(v["key"], "ui.err_sidecar_wait", "{bad:?}");
        }
        let e = config_reply(reply(Some(2), "", "未知参数：--x\n").as_ref()).unwrap_err();
        assert!(e.contains("exit 2") && e.contains("未知参数"), "{e}");
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

    /// 首启 → 换库两条真链路，对着真 daemon 跑一遍：写出的 config 能被壳读回，
    /// 校验失败的错误是 keyed JSON 且原样可渲染。
    #[test]
    fn real_daemon_writes_config_and_validates_the_library_switch() {
        let Some(d) = real_or_skip("real_daemon_writes_config_and_validates_the_library_switch")
        else {
            return;
        };
        let home = tempfile::tempdir().unwrap();
        let lib = home.path().join("Lib A");
        let run_cli = |args: &[&str]| {
            let mut c = sandboxed(&d, home.path());
            c.args(args);
            run(c, CONFIG_TIMEOUT).unwrap().expect("不该超时")
        };

        let init = run_cli(&["config", "init", "--library", lib.to_str().unwrap()]);
        assert_eq!(config_reply(Some(&init)), Ok(()), "{init:?}");
        assert!(lib.is_dir(), "首启要把库目录建出来");
        let cfg_path = serde_json::from_str::<Value>(init.stdout.trim()).unwrap()["config"]
            .as_str()
            .unwrap()
            .to_string();
        let cfg_text = std::fs::read_to_string(&cfg_path).unwrap();
        assert!(
            cfg_text.contains("bind_addr = \"0.0.0.0:41145\""),
            "{cfg_text}"
        );
        assert_eq!(
            crate::ipc::read_config_data_dir(Path::new(&cfg_path).parent().unwrap()),
            Some(lib.display().to_string()),
            "壳读回的 data_dir 必须就是传进去的库目录"
        );

        // 换到不存在的目录 ⇒ keyed 校验错误（原样可渲染）。
        let missing = home.path().join("nope");
        let r = run_cli(&["config", "set-library", missing.to_str().unwrap()]);
        let e = config_reply(Some(&r)).unwrap_err();
        let v: Value = serde_json::from_str(&e).unwrap();
        assert_eq!(v["key"], "ui.err_library_target_missing", "{e}");

        // 换到嵌套目录 ⇒ nested。
        let nested = lib.join("sub");
        std::fs::create_dir_all(&nested).unwrap();
        let r = run_cli(&["config", "set-library", nested.to_str().unwrap()]);
        let e = config_reply(Some(&r)).unwrap_err();
        assert!(e.contains("ui.err_library_nested"), "{e}");
        assert_eq!(
            std::fs::read_to_string(&cfg_path).unwrap(),
            cfg_text,
            "校验失败不许动 config"
        );

        // 合法换库：只改 data_dir。
        let lib_b = home.path().join("Lib B");
        std::fs::create_dir_all(&lib_b).unwrap();
        let r = run_cli(&["config", "set-library", lib_b.to_str().unwrap()]);
        assert_eq!(config_reply(Some(&r)), Ok(()), "{r:?}");
        assert_eq!(
            crate::ipc::read_config_data_dir(Path::new(&cfg_path).parent().unwrap()),
            Some(lib_b.display().to_string())
        );
        let after = std::fs::read_to_string(&cfg_path).unwrap();
        assert!(after.contains("bind_addr = \"0.0.0.0:41145\""), "{after}");
    }

    /// 诊断包：daemon 不在线也出包，且结果形状就是前端读的那两个字段。
    #[test]
    fn real_daemon_exports_a_diag_bundle_when_the_service_is_offline() {
        let Some(d) = real_or_skip("real_daemon_exports_a_diag_bundle_when_the_service_is_offline")
        else {
            return;
        };
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
