//! UPD-07 (#617)：**版本一致性的 owner**——谁负责让"运行中的壳"等于"磁盘上的包"。
//!
//! 背景（0.7.4→0.7.5 真机验收）：更新装完磁盘已是新版，但正在跑的壳仍是旧版。
//! 壳自己换自己（`restart_app` / `kickstart`）只在"壳已经是新版"之后才可靠，而
//! 更新这一跳跑的恰恰是**旧壳的代码**。真正每跳都会被换成新版的角色只有 **daemon**
//! （launchd 按磁盘文件拉起、登记由 #604 对账）——所以由它当 owner：对账，并在
//! **更新窗口内**把旧壳换掉。
//!
//! 判据全部是确定性事实，不用时间猜：
//! - 安装包版本：`platform::installed_bundle_version()`（读磁盘上的 `Info.plist`）
//! - 我自己：`daemon_version()`
//! - 运行中的壳：壳启动时自报的 `{version, pid}`（IPC `shell.announce`）
//! - "登记里的实例就是用户现在这一把"：`platform::shell_agent_running_pid() == 自报 pid`
//!
//! ⚠️ **动作窗口**：只有**被更新流程拉起的** daemon（`--post-update`）才开火。
//! 平时绝不碰用户正在用的壳——"用户主动退壳 / 主动停服务"的语义优先于"版本旧"。

use crate::daemon_version;
use platform::PlatformAdapter as _;

/// 壳自报的身份（IPC `shell.announce` 的载荷）。
///
/// 老壳不会自报 ⇒ `None` ⇒ owner **一律不动**（不知道它的版本，猜就是赌）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShellAnnounce {
    pub version: String,
    pub pid: u32,
}

/// 壳最近一次自报的身份（进程内，daemon 单实例；壳每次启动都会重报并覆盖）。
///
/// 用 `static` + `Mutex` 而不是往 `IpcServer` 上加字段：这条记录跟 IPC 的其它状态
/// 没有关系（它只是"壳最近一次自报了什么"），放模块里 `check_and_act` 在任何地方
/// 都能读到，也不必改 `IpcServer` 的构造/装配面。
static ANNOUNCE: std::sync::Mutex<Option<ShellAnnounce>> = std::sync::Mutex::new(None);

/// 记下壳的自报身份。
///
/// 中毒（某个持锁线程 panic 过）**不算失败**：这条记录只是判据输入，拿回内部值继续
/// 就好——生产代码禁 `unwrap`/`expect`，也不值得为一个缓存值 panic。
pub fn record_announce(announce: ShellAnnounce) {
    let mut slot = ANNOUNCE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    *slot = Some(announce);
}

/// 读到壳最近一次的自报身份（`None` = 还没自报过 / 老壳不来这一条）。
pub fn recorded_announce() -> Option<ShellAnnounce> {
    ANNOUNCE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone()
}

/// owner 的动作判定（纯函数，单测覆盖整张矩阵）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OwnerAction {
    /// 什么都不做，附一句人话原因（落日志，排查时第一眼就能看到"为什么没动"）。
    Idle(&'static str),
    /// 换壳：kickstart 壳的 LaunchAgent（由 launchd 杀 + 按磁盘新文件拉）。
    KickstartShell,
}

/// 只比核心三段（忽略 `v` 前缀与 `-test.N` 后缀）——与壳体/前端的 `sameRelease` 同语义。
///
/// 解析不出三段的一律视为"不同"（宁可不动，也不要把读不懂的版本号当成"一致"）。
pub fn same_release(a: &str, b: &str) -> bool {
    fn core(s: &str) -> Option<Vec<u32>> {
        let head = s.trim().trim_start_matches(['v', 'V']).split('-').next()?;
        if head.is_empty() {
            return None;
        }
        let parts: Vec<u32> = head.split('.').map(|x| x.parse().unwrap_or(0)).collect();
        (parts.len() == 3).then_some(parts)
    }
    matches!((core(a), core(b)), (Some(x), Some(y)) if x == y)
}

/// owner 判定。入参全是"已经取到的确定性事实"，没有时间猜测。
///
/// 顺序刻意如此：**先能不动就不动**（fail-safe），把"该动"夹在最后。
pub fn decide(
    window_open: bool,
    installed_version: Option<&str>,
    my_version: &str,
    shell: Option<&ShellAnnounce>,
    agent_pid: Option<u32>,
) -> OwnerAction {
    let Some(shell) = shell else {
        return OwnerAction::Idle("壳没自报身份（老壳或还没连上）——不知道它的版本，不动");
    };
    let Some(installed) = installed_version else {
        return OwnerAction::Idle("读不到安装包版本——不知道，按 fail-safe 不动");
    };
    if !window_open {
        return OwnerAction::Idle("不在更新窗口内——绝不碰用户正在用的壳");
    }
    if !same_release(my_version, installed) {
        return OwnerAction::Idle("我自己不是磁盘上的版本——先让自己对齐（launchd 会重启我）");
    }
    if same_release(&shell.version, installed) {
        return OwnerAction::Idle("壳已经与安装包同版本——无事可做");
    }
    match agent_pid {
        Some(pid) if pid == shell.pid => OwnerAction::KickstartShell,
        Some(_) => OwnerAction::Idle("登记里的实例不是用户现在这一把——kickstart 只会再造一个实例"),
        None => OwnerAction::Idle("壳不在服务管理器手里（用户手动打开的）——kickstart 无效"),
    }
}

/// 取事实 → 判定 → 动作。返回判定结果（调用方落日志；测试可直接断言 `decide`）。
pub fn check_and_act(window_open: bool, shell: Option<ShellAnnounce>) -> OwnerAction {
    let installed = platform::adapter().installed_bundle_version();
    let agent_pid = platform::adapter().shell_agent_running_pid();
    let action = decide(
        window_open,
        installed.as_deref(),
        &daemon_version(),
        shell.as_ref(),
        agent_pid,
    );
    match &action {
        OwnerAction::KickstartShell => match platform::adapter().kickstart_shell_agent() {
            Ok(pid) => tracing::info!("UPD-07: 换壳已交给 launchd，新壳 pid={pid}"),
            Err(e) => tracing::warn!("UPD-07: 换壳失败（壳会自己退到手动重启指引）：{e}"),
        },
        OwnerAction::Idle(why) => tracing::info!("UPD-07: 不动（{why}）"),
    }
    action
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shell(version: &str, pid: u32) -> ShellAnnounce {
        ShellAnnounce {
            version: version.into(),
            pid,
        }
    }

    /// 矩阵：**只有**"窗口开着 + 安装包读得到 + 我自己就是安装包 + 壳确实旧 +
    /// 登记里的实例就是这一把壳"时才动手。
    #[test]
    fn only_fires_when_every_fact_lines_up() {
        let old_shell = shell("0.7.5", 4242);
        assert_eq!(
            decide(true, Some("0.7.6"), "0.7.6", Some(&old_shell), Some(4242)),
            OwnerAction::KickstartShell
        );
    }

    /// 反证面：**任何一条不成立都必须不动**（每一行都是一次真实事故的入口）。
    #[test]
    fn every_missing_fact_keeps_us_idle() {
        let old_shell = shell("0.7.5", 4242);
        let cases = [
            (false, Some("0.7.6"), "0.7.6", Some(&old_shell), Some(4242)), // 窗口外
            (true, None, "0.7.6", Some(&old_shell), Some(4242)),           // 读不到安装包版本
            (true, Some("0.7.6"), "0.7.5", Some(&old_shell), Some(4242)),  // 我自己不是新包
            (true, Some("0.7.6"), "0.7.6", None, Some(4242)),              // 壳没自报
            (true, Some("0.7.6"), "0.7.6", Some(&old_shell), Some(777)),   // 登记的是别人
            (true, Some("0.7.6"), "0.7.6", Some(&old_shell), None),        // 壳不在 launchd 手里
        ];
        for (window, installed, me, sh, pid) in cases {
            let action = decide(window, installed, me, sh, pid);
            assert!(
                matches!(action, OwnerAction::Idle(_)),
                "每种缺失都必须 Idle，实际 {action:?}"
            );
        }
    }

    /// 壳已经和安装包同版本 ⇒ 无事可做（这条挡住"每次开机都白踢一次"）。
    #[test]
    fn matching_versions_are_a_no_op() {
        let fresh = shell("v0.7.6", 1);
        assert!(matches!(
            decide(true, Some("0.7.6"), "0.7.6", Some(&fresh), Some(1)),
            OwnerAction::Idle(_)
        ));
    }

    /// 版本比较只认核心三段：`v` 前缀与 `-test.N` 后缀不参与。
    #[test]
    fn release_comparison_ignores_v_prefix_and_prerelease_suffix() {
        assert!(same_release("0.7.6", "v0.7.6"));
        assert!(same_release("0.7.6-test.1", "0.7.6"));
        assert!(!same_release("0.7.5", "0.7.6"));
        assert!(!same_release("", "0.7.6"));
        assert!(!same_release("0.7", "0.7.6"));
    }
}
