//! DAE-03: daemon CLI 纪律——参数解析 + autostart 决策 + bind 人话报错。
//!
//! 事故背景（2026-08-06）：daemon 无参数解析，`daemon --help` 被当成普通
//! 启动一路走到单实例 claim，触发误接管、常驻停机数分钟（PROGRESS 当日
//! 傍晚记录）。本模块把事故逼出的三个缺口做成**纯函数 + 单测**，main.rs
//! 只负责接线：
//!
//!   1. `--help` / `--version` / `--ephemeral` 的解析——未知参数报错退出，
//!      绝不静默忽略（静默忽略正是事故根因）；
//!   2. autostart 安装决策——只有升级接管（TookOver）才装，纯新启动
//!      （Proceed）/退位（StandDown）绝不碰开机自启配置；
//!   3. 固定端口被异身份实例/其它程序占用时的人话报错（含修复指引），
//!      原始英文底层错误照常留日志。

use crate::Claim;

/// 解析后的 CLI 意图。`--help` / `--version` 必须在任何 daemon 机制
/// （日志/配置/数据库/身份/claim/bind）之前短路退出。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Cli {
    /// 正常启动。`ephemeral` = UX-07 测试/脚本模式（stdin EOF 即退出）。
    Run {
        ephemeral: bool,
        /// UPD-07 (#617)：本实例是**被更新流程拉起的**（桌面壳 `resume_daemon_after_update`
        /// 那次 spawn）。只有带这个标记的实例会开火去换掉旧壳；launchd 常驻拉起、
        /// 崩溃自愈拉起都不带它——平时绝不碰用户正在用的壳。
        post_update: bool,
    },
    Help,
    Version,
    /// #1042：`--version --json`——机读版本（契约见 [`version_json`]）。
    VersionJson,
    /// #1042：`config init --library <dir>`——首启写平台 config.toml。
    ConfigInit {
        library: String,
    },
    /// #1042：`config set-library <dir>`——换库（重启后台服务后生效）。
    ConfigSetLibrary {
        library: String,
    },
}

pub const USAGE: &str = "\
P-Pass 存储端 daemon

用法:
  daemon [选项]

选项:
  --ephemeral  测试/脚本模式：stdin 关闭（写入端 EOF）即整体退出，3 秒内
               （UX-07，杜绝 A 类孤儿）。生产/launchd 不带此 flag。
  --post-update
               标记「我是被更新流程拉起的」：允许 owner 在更新窗口内换掉旧壳
               （UPD-07。桌面壳更新后 resume 时带；launchd/自愈不带）。
  --version    打印版本号并退出（不启动任何 daemon 机制）
               加 --json 输出单行 JSON（product / schema / version 三个键）
  --help       显示本帮助并退出（不启动任何 daemon 机制）

子命令（一次性短进程：不启动服务、不占端口，执行完即退出）:
  config init --library <dir>
               首启：建库目录并写平台 config.toml（整份模板）
  config set-library <dir>
               换库：校验（存在/可写/不嵌套）后只改 data_dir 一行；
               重启后台服务后生效

退出码：0 成功；1 操作失败（stderr 一行错误）；2 用法错误
";

/// 解析命令行。规则：
///  - `--help` / `-h`、`--version` / `-V` 一旦出现即返回对应意图
///    （优先于其它参数，符合 CLI 惯例）；
///  - 未知参数返回 Err——**绝不静默忽略**（静默忽略 = 8/6 事故根因：
///    任何参数都被当成普通启动一路走到 claim）；
///  - 无参数 = 普通启动。
pub fn parse_cli(args: impl IntoIterator<Item = String>) -> Result<Cli, String> {
    let args: Vec<String> = args.into_iter().collect();
    // #1042：首个参数是子命令名 ⇒ 走子命令语法（同样在一切 daemon 机制之前
    // 短路，见 main.rs）。
    if args.first().map(String::as_str) == Some("config") {
        return parse_subcommand(&args);
    }
    let mut ephemeral = false;
    let mut post_update = false;
    let mut json = false;
    for (i, a) in args.iter().enumerate() {
        match a.as_str() {
            "--ephemeral" => ephemeral = true,
            "--post-update" => post_update = true,
            "--json" => json = true,
            "--help" | "-h" => return Ok(Cli::Help),
            // `--json` 前后都认（`--version --json` / `--json --version`）。
            "--version" | "-V" => {
                return Ok(if json || args[i + 1..].iter().any(|x| x == "--json") {
                    Cli::VersionJson
                } else {
                    Cli::Version
                })
            }
            other => return Err(format!("未知参数：{other}")),
        }
    }
    if json {
        return Err("--json 只能与 --version 一起用".to_string());
    }
    Ok(Cli::Run {
        ephemeral,
        post_update,
    })
}

/// #1042：`config …` 的语法。严格匹配，多一个少一个都是用法
/// 错误——与顶层「未知参数绝不静默忽略」同一纪律。`--help` / `-h` 出现在
/// 子命令里同样短路成帮助。
fn parse_subcommand(args: &[String]) -> Result<Cli, String> {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        return Ok(Cli::Help);
    }
    let rest: Vec<&str> = args.iter().map(String::as_str).collect();
    match rest.as_slice() {
        ["config", "init", "--library", dir] => Ok(Cli::ConfigInit {
            library: (*dir).to_string(),
        }),
        ["config", "init", ..] => Err("用法：config init --library <dir>".to_string()),
        ["config", "set-library", dir] => Ok(Cli::ConfigSetLibrary {
            library: (*dir).to_string(),
        }),
        ["config", "set-library", ..] => Err("用法：config set-library <dir>".to_string()),
        [cmd, sub, ..] => Err(format!("未知子命令：{cmd} {sub}")),
        [cmd] => Err(format!("缺少子命令：{cmd} <…>")),
        [] => Err("缺少子命令".to_string()),
    }
}

/// #1042：`--version --json` 的输出（单行 JSON，契约由
/// `tests/cli_flow.rs` 钉住）：
///
/// ```text
/// {"product":"P-Pass daemon","schema":1,"version":"<版本>"}
/// ```
///
/// - `product` 固定为 `P-Pass daemon`：桌面壳据此确认「这确实是我们的
///   daemon」，取代对纯文本 `--version` 前缀的字面量匹配；
/// - `schema` 是本格式的版本，只增不改——加字段不升，改/删字段才升；
/// - `version` 与纯文本 `--version`、IPC `status.version` 同源
///   （[`crate::daemon_version`]）。
pub fn version_json(version: &str) -> String {
    serde_json::json!({
        "product": VERSION_PRODUCT,
        "schema": VERSION_JSON_SCHEMA,
        "version": version,
    })
    .to_string()
}

/// `--version`（纯文本与 JSON）里的产品标识。
pub const VERSION_PRODUCT: &str = "P-Pass daemon";
/// `--version --json` 的格式版本。
pub const VERSION_JSON_SCHEMA: u32 = 1;

/// DAE-03 ②：autostart 只在升级接管（TookOver）时（重）安装——纯新启动
/// （Proceed）与退位（StandDown）绝不写 launchd/注册表。手动/开发构建
/// 启动不得篡改用户的开机自启配置（8/6 --help 事故的第二个缺口）。
/// 真·安装动作在 platform adapter（其路径守卫拒绝 /target/、/tmp/），
/// 本函数只负责「何时该装」的决策，main 按它执行。
pub fn autostart_install_required(claim: &Claim) -> bool {
    matches!(claim, Claim::TookOver)
}

/// 把 transport bind 失败翻译成人话。固定端口（config.toml bind_addr）被
/// 异身份 P-Pass 实例或其它程序占用时，原始报错是英文底层错误（如
/// "Address already in use (os error 98)"），用户看不懂。这里识别地址
/// 占用类错误（unix + Windows 两种文案），给出可操作的修复指引；
/// 其余错误原样透传（不做过度翻译）。
pub fn humanize_bind_error(addr: Option<std::net::SocketAddr>, raw: &str) -> String {
    let lower = raw.to_ascii_lowercase();
    let in_use =
        lower.contains("already in use") || lower.contains("only one usage of each socket");
    if !in_use {
        return raw.to_string();
    }
    match addr {
        Some(a) => format!(
            "UDP 端口 {a} 已被占用——可能是另一个 P-Pass 实例（不同身份/数据目录）或其它程序在使用。\
             请修改 config.toml 的 bind_addr 改用其它端口，或先关闭占用方再重试。\
             （原始错误：{raw}）"
        ),
        None => format!(
            "传输端口已被占用——可能是另一个 P-Pass 实例（不同身份/数据目录）或其它程序在使用。\
             请先关闭占用方再重试。（原始错误：{raw}）"
        ),
    }
}

/// SEC-11 (#496)：启动时 stdout 上关于配对链接的那一行。
///
/// 配对链接带 10 分钟内有效的令牌，**只能给眼前的终端看**。stdout 不是终端
/// 时它几乎一定落进了某个文件——macOS launchd 的 `StandardOutPath`
/// （`~/Library/Logs/p-pass-daemon.log`）、systemd/journald、`nohup … >`、
/// 脚本的 `> daemon.log`——这时只打一句不含链接的提示，告诉人/脚本改走
/// IPC `pairing.start`（桌面端显示二维码走的也是它）。
///
/// 提示里**刻意不出现 `ppf://pair` 字面量**：验收口径就是日志里这个串计数为 0。
pub fn pair_link_stdout_line(qr: &str, stdout_is_terminal: bool) -> String {
    if stdout_is_terminal {
        format!("配对二维码内容（10 分钟内有效）: {qr}")
    } else {
        "配对链接未打印：stdout 不是终端（多半被重定向进了日志文件），\
         链接含令牌不能落盘。请用桌面端显示二维码，或经 IPC `pairing.start` 获取。"
            .to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const QR: &str = "ppf://pair?node=aa&t=0123456789abcdef01234567&r=https://relay.example";

    #[test]
    fn pair_link_printed_only_to_a_terminal() {
        let tty = pair_link_stdout_line(QR, true);
        assert!(tty.contains(QR), "终端下应打印完整链接:\n{tty}");

        let redirected = pair_link_stdout_line(QR, false);
        assert!(
            !redirected.contains("ppf://pair"),
            "非终端时不许出现配对链接字面量:\n{redirected}"
        );
        assert!(
            !redirected.contains("0123456789abcdef01234567"),
            "非终端时不许出现令牌:\n{redirected}"
        );
        assert!(
            redirected.contains("pairing.start"),
            "非终端时应指明替代取法:\n{redirected}"
        );
    }

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn no_args_is_a_normal_run() {
        assert_eq!(
            parse_cli(args(&[])),
            Ok(Cli::Run {
                ephemeral: false,
                post_update: false
            })
        );
    }

    /// UPD-07 (#617)：`--post-update` = "我是被更新流程拉起的"，只有它会开火换壳；
    /// 默认（launchd 常驻 / 自愈拉起的机器）必须是 false。
    #[test]
    fn post_update_flag_parses_and_defaults_to_false() {
        assert_eq!(
            parse_cli(args(&["--post-update"])),
            Ok(Cli::Run {
                ephemeral: false,
                post_update: true
            })
        );
        assert_eq!(
            parse_cli(args(&["--ephemeral", "--post-update"])),
            Ok(Cli::Run {
                ephemeral: true,
                post_update: true
            })
        );
    }

    #[test]
    fn ephemeral_flag_parses() {
        assert_eq!(
            parse_cli(args(&["--ephemeral"])),
            Ok(Cli::Run {
                ephemeral: true,
                post_update: false
            })
        );
        // --ephemeral 与普通启动共存
        assert_eq!(
            parse_cli(args(&["--ephemeral", "--ephemeral"])),
            Ok(Cli::Run {
                ephemeral: true,
                post_update: false
            })
        );
    }

    #[test]
    fn help_short_circuits_everything() {
        assert_eq!(parse_cli(args(&["--help"])), Ok(Cli::Help));
        assert_eq!(parse_cli(args(&["-h"])), Ok(Cli::Help));
        // 事故场景回归：--help 混在其它参数里也必须短路，不能当普通启动
        assert_eq!(parse_cli(args(&["--ephemeral", "--help"])), Ok(Cli::Help));
        assert_eq!(parse_cli(args(&["--help", "--ephemeral"])), Ok(Cli::Help));
    }

    #[test]
    fn version_short_circuits_everything() {
        assert_eq!(parse_cli(args(&["--version"])), Ok(Cli::Version));
        assert_eq!(parse_cli(args(&["-V"])), Ok(Cli::Version));
    }

    /// #1042：`--json` 只改变 `--version` 的输出形状，前后都认；单独出现是
    /// 用法错误（不能被当成普通启动）。
    #[test]
    fn version_json_flag_in_either_order() {
        assert_eq!(
            parse_cli(args(&["--version", "--json"])),
            Ok(Cli::VersionJson)
        );
        assert_eq!(
            parse_cli(args(&["--json", "--version"])),
            Ok(Cli::VersionJson)
        );
        assert_eq!(parse_cli(args(&["-V", "--json"])), Ok(Cli::VersionJson));
        assert!(parse_cli(args(&["--json"])).is_err());
        assert!(parse_cli(args(&["--ephemeral", "--json"])).is_err());
    }

    #[test]
    fn version_json_shape_is_stable() {
        let v: serde_json::Value = serde_json::from_str(&version_json("1.2.3")).unwrap();
        assert_eq!(
            v,
            serde_json::json!({"product": "P-Pass daemon", "schema": 1, "version": "1.2.3"})
        );
        assert!(!version_json("1.2.3").contains('\n'));
    }

    #[test]
    fn config_subcommands_parse_strictly() {
        assert_eq!(
            parse_cli(args(&["config", "init", "--library", "/a b/c"])),
            Ok(Cli::ConfigInit {
                library: "/a b/c".into()
            })
        );
        assert_eq!(
            parse_cli(args(&["config", "set-library", "C:\\Lib"])),
            Ok(Cli::ConfigSetLibrary {
                library: "C:\\Lib".into()
            })
        );
        for bad in [
            &["config"][..],
            &["config", "init"],
            &["config", "init", "--library"],
            &["config", "init", "/x"],
            &["config", "init", "--library", "/x", "extra"],
            &["config", "set-library"],
            &["config", "set-library", "/a", "/b"],
            &["config", "bogus"],
        ] {
            assert!(parse_cli(args(bad)).is_err(), "{bad:?} 应是用法错误");
        }
        assert_eq!(
            parse_cli(args(&["config", "init", "--help"])),
            Ok(Cli::Help)
        );
    }

    /// 子命令名只在首位才是子命令：`--ephemeral config` 仍是未知参数。
    #[test]
    fn subcommand_words_elsewhere_are_unknown_args() {
        assert!(parse_cli(args(&["--ephemeral", "config"])).is_err());
    }

    #[test]
    fn unknown_args_are_rejected_not_ignored() {
        // 事故根因回归：任何未知参数必须报错，绝不静默当普通启动
        let err = parse_cli(args(&["--definitely-not-a-flag"])).unwrap_err();
        assert!(err.contains("未知参数"), "err: {err}");
        // 反证：把未知分支改成静默忽略 → 本测试必红
        assert!(parse_cli(args(&["--bogus"])).is_err());
    }

    #[test]
    fn fresh_start_never_installs_autostart() {
        // DAE-03 ②：只有升级接管装 autostart。
        // 反证：改成恒 true / 恒 false → 本测试必红。
        assert!(!autostart_install_required(&Claim::Proceed));
        assert!(!autostart_install_required(&Claim::StandDown));
        assert!(autostart_install_required(&Claim::TookOver));
    }

    #[test]
    fn addr_in_use_is_humanized() {
        let addr = "127.0.0.1:41145".parse().unwrap();
        let msg = humanize_bind_error(
            Some(addr),
            "bind endpoint: Address already in use (os error 98)",
        );
        assert!(msg.contains("41145"), "msg: {msg}");
        assert!(msg.contains("bind_addr"), "msg: {msg}");
        assert!(msg.contains("另一个 P-Pass 实例"), "msg: {msg}");
        assert!(msg.contains("原始错误"), "msg: {msg}");
        // Windows 风格文案同样识别
        let win = humanize_bind_error(
            Some(addr),
            "Only one usage of each socket address (protocol/network address/port) is normally permitted",
        );
        assert!(win.contains("bind_addr"), "win: {win}");
    }

    #[test]
    fn non_in_use_errors_pass_through() {
        let raw = "bind endpoint: invalid relay url: bad";
        assert_eq!(humanize_bind_error(None, raw), raw);
        // 反证：匹配条件若放宽成宽松子串（如只匹配 "use"），下面这个
        // 合法错误会被误伤成人话化——透传断言必红。
        let tricky = "bind endpoint: use-after-free in relay resolver";
        assert_eq!(humanize_bind_error(None, tricky), tricky);
    }
}
