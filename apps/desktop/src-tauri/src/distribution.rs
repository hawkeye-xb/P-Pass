//! 发行助手（#1046，S-8 / S-11）：mac / Windows 桌面发行层的**托管判据与动作**——
//! 「用户主动停止」标记、自愈判据、向导判据、自动换内核判据、开机自启登记对账。
//!
//! 托管属于发行层，不属于核心（S3）：daemon 不知道自己怎么被拉起、登记在哪；
//! 这些事由壳在启动时幂等对账（停 → 替换 → 重启壳 → 新壳对账）。
//!
//! 纯 Rust，**不依赖 Tauri**：Tauri command 只负责调用这里，判据全部在这里单测。
//! 平台差异只经 `platform::hosting()` / `platform::adapter()`（G1/G5）。

use platform::{HostingAdapter as _, PlatformAdapter as _};
use version_cmp::version_cmp;

/// 首启向导**什么时候接管整个窗口**——判据只在这里（#1045，S-7）。前端只读
/// `wizard_state.show_wizard`，不再自己拿 configured / installed / user_stopped
/// 拼（那份拷贝在 `serviceGate.js`，与这里的 `self_heal_allowed` 各写一遍）。
///
/// - `online`：服务在线（Rust 持有的服务状态 = running）。在线永不显示向导。
/// - `configured`：平台数据目录里有 config.toml。从没配置过 = 完整向导。
/// - 配过、服务没注册（`!installed`）= 向导中途退出，回向导继续走（xixi 实测反馈 3）；
///   但用户自己点了停止（`user_stopped`，DESK-36 #456）不算中途退出——停服会卸
///   autostart，把它当中途退出会让重开 App 被打回完整 onboard，所以留在主界面给
///   「启动服务」。
///
/// 纯函数：文件系统与服务状态由调用点探测后传入，判据本身单测（含反证）。
pub(crate) fn show_wizard(
    configured: bool,
    installed: bool,
    user_stopped: bool,
    online: bool,
) -> bool {
    if online {
        return false;
    }
    if !configured {
        return true;
    }
    !installed && !user_stopped
}

/// 【DESK-42 #604】开机自启登记对账（App 启动时跑一次，独立线程）。
///
/// 缺陷现场：`~/Library/LaunchAgents/com.p-pass.daemon.plist` 被钉在
/// `~/P-Pass-Backups/<日期>/old-app/P-Pass.app/...` 里的旧 App 上，而实际安装
/// 在 `/Applications`——开机/登录/KeepAlive 拉起的是那份旧服务。成因是登记
/// 路径只在「用户主动启动服务」或「daemon 接管」两个时机写入，此后换目录、
/// 更新覆盖、从备份副本启动过，都没有任何东西去校验它。
///
/// 现在每次启动对一次账：登记存在但指向别处 → 用**当前 App 内**的 daemon 路径
/// 重写（幂等）；未登记 → 不动（纯新启动不许顺手装，DAE-03 ②）；一致 → 不动。
///
/// DESK-60 (#877)：例外是「平台声明登记会被系统流程删掉」（Windows 卸载）——
/// 配置在、用户没停过 ⇒ 补登记，见 `restore_missing_autostart_allowed`。
pub(crate) fn reconcile_autostart_registration() {
    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    let Some(dir) = exe.parent() else { return };
    let sidecar = dir.join(platform::hosting().daemon_executable_name());
    // 开发运行（target/ 里没有 sidecar）等情况：没有可对账的目标，直接跳过。
    if !sidecar.is_file() {
        return;
    }
    // DESK-65 (#957)：用户主动停过服务 ⇒ 唯一正确的状态是「没有登记」。对账
    // 只往这个方向收敛：残留的登记（上次停止时没撤掉、或老版本留下的）撤掉，
    // 绝不改写、更不拉起——改写登记在 Windows 上会顺带把服务跑起来。
    if is_user_stopped(&platform::adapter().data_dir()) {
        if platform::hosting().autostart_installed().unwrap_or(false) {
            if let Err(e) = platform::hosting().uninstall_autostart() {
                eprintln!("#957: 用户停过服务，但撤销残留的开机自启登记失败: {e}");
            }
        }
        return;
    }
    match platform::hosting().reconcile_autostart(&sidecar) {
        Ok(platform::AutostartReconcile::Rewritten) => {
            // 走 stderr：与服务管理器接管的 daemon stderr 同一去处，排障时看得到。
            eprintln!(
                "#604: 开机自启登记与当前安装不一致——已重写为 {}",
                sidecar.display()
            );
        }
        Ok(platform::AutostartReconcile::Refreshed) => {
            // #1046（S-11）：指向没变、内容是老版本的（如 launchd 日志落点）——
            // 更新后由新壳按本版本重新登记，原先由 daemon 接管时重装。
            eprintln!(
                "#1046: 开机自启登记内容不是本版本的——已按本版本重写为 {}",
                sidecar.display()
            );
        }
        Ok(platform::AutostartReconcile::Repaired) => {
            eprintln!(
                "#726: 开机自启登记文件读不出（已损坏）——已重写为 {}",
                sidecar.display()
            );
        }
        Ok(platform::AutostartReconcile::NotRegistered)
            if restore_missing_autostart_allowed(
                platform::hosting().autostart_restore_when_missing(),
                &platform::adapter().data_dir(),
            ) =>
        {
            // DESK-60 (#877)：卸载删了登记、配置还在、用户没停过 ⇒ 补回来，
            // 否则下次开机不再自动备份，界面却显示一切正常。闸门（稳定安装
            // 位置）已在 reconcile_autostart 里判过，走到这里的 sidecar 可信。
            match platform::hosting().install_autostart(&sidecar) {
                Ok(()) => eprintln!("#877: 开机自启登记缺失——已补登记为 {}", sidecar.display()),
                Err(e) => eprintln!("#877: 开机自启登记缺失，补登记失败: {e}"),
            }
        }
        Ok(_) => {}
        Err(e) => eprintln!("#604: 开机自启登记对账失败: {e}"),
    }
}

/// DESK-36 (#456)：「用户主动停止了后台服务」的持久标记。
///
/// 自愈（前端 refresh 失败分支 → `self_heal_daemon`）原来分不清「服务崩了」
/// 和「用户点了停止」，冷却窗口一过就把用户刚停掉的服务拉回来。这个标记是
/// 两者唯一的区分依据，前端按钮和托盘菜单共用同一份（都走 `stop_daemon`）。
///
/// 为什么是 data dir 里的独立文件、而不是 config.toml 的一个字段：
/// `write_config` 会整体重写 config.toml（向导每走一次就重写一次），字段放
/// 进去会被冲掉；而且 config.toml 是 daemon 的配置，这是壳自己的状态。
/// 持久化（而不是进程内变量）是因为语义要跨 App 重开：用户停了服务、关掉
/// App 再打开，服务仍应保持停止，直到用户点「启动服务」。
pub(crate) const USER_STOPPED_MARKER: &str = "desktop-user-stopped";

pub(crate) fn user_stopped_marker(data_dir: &std::path::Path) -> std::path::PathBuf {
    data_dir.join(USER_STOPPED_MARKER)
}

pub(crate) fn is_user_stopped(data_dir: &std::path::Path) -> bool {
    user_stopped_marker(data_dir).exists()
}

/// 落标记 / 清标记。失败要报出来：标记没落下 = 自愈照样会把服务拉回来，
/// 用户意图被静默撤销，这正是 #456 本身。
pub(crate) fn set_user_stopped(data_dir: &std::path::Path, stopped: bool) -> Result<(), String> {
    let marker = user_stopped_marker(data_dir);
    if stopped {
        std::fs::create_dir_all(data_dir)
            .map_err(|e| crate::ipc::ui_err("ui.err_stop_mark_write", &[("err", &e)]))?;
        std::fs::write(&marker, b"user stopped the background service\n")
            .map_err(|e| crate::ipc::ui_err("ui.err_stop_mark_write", &[("err", &e)]))
    } else {
        match std::fs::remove_file(&marker) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(crate::ipc::ui_err("ui.err_stop_mark_clear", &[("err", &e)])),
        }
    }
}

/// 自愈判据（纯函数，单测覆盖）：配置过、且不是用户主动停的，才允许自愈。
/// 「没配置过」是首启向导的事；「用户停的」要等用户自己点「启动服务」。
pub(crate) fn self_heal_allowed(data_dir: &std::path::Path) -> bool {
    data_dir.join("config.toml").exists() && !is_user_stopped(data_dir)
}

/// DESK-60 (#877)：登记缺失时要不要补。与自愈同一条判据——配置过（不是首启，
/// DAE-03 ②）、且不是用户主动停的（DESK-36 的停止标记）——再加上平台声明
/// 「登记会被系统流程删掉」。
pub(crate) fn restore_missing_autostart_allowed(
    platform_restores: bool,
    data_dir: &std::path::Path,
) -> bool {
    platform_restores && self_heal_allowed(data_dir)
}

/// #456 后续：更新流程装完（或装失败）之后要不要把 daemon 拉回来。
/// 用户主动停了服务 = 一直停着，直到用户自己点「启动后台服务」；更新不算
/// 用户的启动意图。其余情况（包括向导还没走完的机器）行为和原来一样：
/// pause 杀掉了什么就拉回什么。不复用 `self_heal_allowed`——它多一条
/// config.toml 判断，会改掉「没停过」时的更新行为。
pub(crate) fn update_resume_allowed(data_dir: &std::path::Path) -> bool {
    !is_user_stopped(data_dir)
}

/// 纯函数：在跑的内核（自报 pid）是不是"野生"的——服务管理器手里的 job pid
/// 与它对不上。读不到自报 pid = 不知道 = 不算（fail-safe：不去动它）。
pub(crate) fn daemon_is_unmanaged(running_pid: Option<u32>, resident_pid: Option<u32>) -> bool {
    match running_pid {
        Some(p) => resident_pid != Some(p),
        None => false,
    }
}

/// 对账用的事实（全部现取，不信缓存）。
#[derive(Debug, Clone, Default)]
pub(crate) struct KernelFacts {
    /// 在跑的内核自报（`status.version` / `status.pid`）。
    pub(crate) running_version: Option<String>,
    pub(crate) running_pid: Option<u32>,
    /// 磁盘上 sidecar 的版本（`ppf-daemon --version`）——换完会是它。
    pub(crate) on_disk_version: Option<String>,
    /// 常驻服务登记在吗（launchd 语义），以及 launchd 眼里在跑的 pid。
    pub(crate) resident_registered: bool,
    pub(crate) resident_pid: Option<u32>,
    pub(crate) user_stopped: bool,
    pub(crate) transfer_active: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum KernelVerdict {
    /// 内核 = 磁盘版本，且（有 launchd 时）归 launchd 管：无事可做。
    InSync,
    /// 按规则不动（理由写日志）。
    Skip(&'static str),
    /// 该换，但正在传输 ⇒ 推迟。
    Defer,
    /// 现在就换。
    Converge(&'static str),
}

/// #667 判据（纯函数，单测覆盖每条分支）。
pub(crate) fn kernel_convergence_verdict(f: &KernelFacts) -> KernelVerdict {
    use std::cmp::Ordering;
    if f.user_stopped {
        return KernelVerdict::Skip("用户主动停了服务");
    }
    let (Some(running), Some(on_disk)) =
        (f.running_version.as_deref(), f.on_disk_version.as_deref())
    else {
        // 读不到 = 不知道 = 什么都不做（fail-safe）。
        return KernelVerdict::Skip("读不到内核或磁盘版本");
    };
    let reason = match version_cmp(running, on_disk) {
        // 只在"内核比磁盘旧"时换：dmg 降级安装不许把内核也降下去。
        Ordering::Greater => return KernelVerdict::Skip("内核比磁盘上的新，不降级"),
        Ordering::Less => "内核比磁盘上的旧",
        Ordering::Equal => {
            if f.resident_registered && daemon_is_unmanaged(f.running_pid, f.resident_pid) {
                "内核不归服务管理器管"
            } else {
                return KernelVerdict::InSync;
            }
        }
    };
    if f.transfer_active {
        return KernelVerdict::Defer;
    }
    KernelVerdict::Converge(reason)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── #667 / #732：自动换内核判据 ───────────────────────────────────

    fn facts(running: &str, on_disk: &str) -> KernelFacts {
        KernelFacts {
            running_version: Some(running.into()),
            running_pid: Some(100),
            on_disk_version: Some(on_disk.into()),
            resident_registered: true,
            resident_pid: Some(100),
            user_stopped: false,
            transfer_active: false,
        }
    }

    /// #667 验收 1 的判据：dmg 覆盖安装后内核比磁盘旧 ⇒ 现在就换。
    /// 反证：把 `Ordering::Less` 分支改成 InSync（= 去掉自动收敛），本测试必红。
    #[test]
    fn kernel_older_than_disk_converges() {
        assert!(matches!(
            kernel_convergence_verdict(&facts("0.9.1", "0.9.5")),
            KernelVerdict::Converge(_)
        ));
        assert!(matches!(
            kernel_convergence_verdict(&facts("0.9.5-test.1", "0.9.5")),
            KernelVerdict::Converge(_)
        ));
    }

    #[test]
    fn kernel_in_sync_and_managed_is_left_alone() {
        assert_eq!(
            kernel_convergence_verdict(&facts("0.9.5", "0.9.5")),
            KernelVerdict::InSync
        );
    }

    /// #732 ①：同版本但在跑的不是 launchd 那份（旧壳更新时一次性 spawn 的）⇒ 收编。
    #[test]
    fn kernel_same_version_but_unmanaged_converges() {
        let mut f = facts("0.9.5", "0.9.5");
        f.resident_pid = None; // launchd: not running
        assert!(matches!(
            kernel_convergence_verdict(&f),
            KernelVerdict::Converge(_)
        ));
        f.resident_pid = Some(999); // launchd 手里是另一个 pid
        assert!(matches!(
            kernel_convergence_verdict(&f),
            KernelVerdict::Converge(_)
        ));
        // 没有常驻登记（Windows Run key / 未登记）：没有"归谁管"可言 ⇒ 不动。
        f.resident_registered = false;
        assert_eq!(kernel_convergence_verdict(&f), KernelVerdict::InSync);
    }

    /// dmg 降级安装：内核比磁盘新 ⇒ 绝不把内核也降下去。
    #[test]
    fn kernel_newer_than_disk_is_never_downgraded() {
        assert!(matches!(
            kernel_convergence_verdict(&facts("0.9.5", "0.9.4")),
            KernelVerdict::Skip(_)
        ));
        let mut f = facts("0.9.5", "0.9.4");
        f.resident_pid = None; // 即使不归 launchd 管
        assert!(matches!(
            kernel_convergence_verdict(&f),
            KernelVerdict::Skip(_)
        ));
    }

    /// #667 验收 2 ①：用户主动停过服务 ⇒ 一律不动（哪怕内核旧）。
    #[test]
    fn user_stop_beats_kernel_convergence() {
        let mut f = facts("0.9.1", "0.9.5");
        f.user_stopped = true;
        assert!(matches!(
            kernel_convergence_verdict(&f),
            KernelVerdict::Skip(_)
        ));
    }

    /// #667 验收 2 ②：正在传输 ⇒ 推迟（不是失败、也不是放弃）。
    #[test]
    fn transfer_in_progress_defers_kernel_convergence() {
        let mut f = facts("0.9.1", "0.9.5");
        f.transfer_active = true;
        assert_eq!(kernel_convergence_verdict(&f), KernelVerdict::Defer);
        // 一致时传输与否都不动
        let mut g = facts("0.9.5", "0.9.5");
        g.transfer_active = true;
        assert_eq!(kernel_convergence_verdict(&g), KernelVerdict::InSync);
    }

    /// 读不到 = 不知道 = 不动（fail-safe）。
    #[test]
    fn unknown_versions_never_trigger_a_restart() {
        let mut f = facts("0.9.1", "0.9.5");
        f.on_disk_version = None;
        assert!(matches!(
            kernel_convergence_verdict(&f),
            KernelVerdict::Skip(_)
        ));
        let mut g = facts("0.9.1", "0.9.5");
        g.running_version = None;
        assert!(matches!(
            kernel_convergence_verdict(&g),
            KernelVerdict::Skip(_)
        ));
    }

    #[test]
    fn unmanaged_needs_a_known_running_pid() {
        assert!(daemon_is_unmanaged(Some(1), None));
        assert!(daemon_is_unmanaged(Some(1), Some(2)));
        assert!(!daemon_is_unmanaged(Some(1), Some(1)));
        assert!(
            !daemon_is_unmanaged(None, None),
            "读不到自报 pid 不许当野生实例去请它退位"
        );
    }

    // ── DESK-36 (#456)：「用户主动停止」标记 + 自愈判据 ───────────────────
    //
    // 全部用 tempdir 注入 data dir——绝不调 stop_daemon / start_daemon 本体，
    // 它们会走真实 adapter（pkill ppf-daemon、launchctl bootout 真 agent）。

    /// 一个「向导走完了」的 data dir：config.toml 在。
    fn configured_data_dir() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("config.toml"), "library_dir = \"x\"\n").unwrap();
        dir
    }

    #[test]
    fn self_heal_revives_a_configured_daemon_that_was_not_stopped_by_the_user() {
        // 崩了 / 被更新流程停了又没拉回来（W1 那个 NSIS 场景）——自愈的本职。
        let dir = configured_data_dir();
        assert!(self_heal_allowed(dir.path()));
    }

    #[test]
    fn self_heal_never_revives_a_daemon_the_user_stopped() {
        // #456 本体：用户点了停止 → 自愈不许在冷却窗口过后把它拉回来。
        let dir = configured_data_dir();
        set_user_stopped(dir.path(), true).unwrap();
        assert!(
            !self_heal_allowed(dir.path()),
            "用户主动停止了服务，自愈却仍然判定要拉起它（#456）"
        );
    }

    /// DESK-60 (#877)：登记缺失时补不补——#877 卡面要求的三种状态 + 平台开关。
    /// 反证：判据去掉停止标记那条 → 第二条断言红；去掉配置那条 → 第三条红。
    #[test]
    fn a_missing_autostart_is_restored_only_for_a_configured_unstopped_install() {
        let dir = configured_data_dir();
        assert!(
            restore_missing_autostart_allowed(true, dir.path()),
            "配置在、没停过、登记丢了：应补登记（#877 现场）"
        );
        assert!(
            !restore_missing_autostart_allowed(false, dir.path()),
            "平台没声明会被系统删登记：保持「未登记 → 不动」"
        );
        set_user_stopped(dir.path(), true).unwrap();
        assert!(
            !restore_missing_autostart_allowed(true, dir.path()),
            "用户主动停过服务：重装后也不许补（尊重停止）"
        );
        let fresh = tempfile::tempdir().unwrap();
        assert!(
            !restore_missing_autostart_allowed(true, fresh.path()),
            "没配置过（首启）：不许顺手登记（DAE-03 ②）"
        );
    }
    #[test]
    fn user_stop_survives_an_app_restart() {
        // 持久化语义：标记在盘上，换一个「进程」（重新读同一目录）仍然在。
        let dir = configured_data_dir();
        set_user_stopped(dir.path(), true).unwrap();
        let reopened = dir.path().to_path_buf();
        assert!(is_user_stopped(&reopened));
        assert!(!self_heal_allowed(&reopened));
    }

    #[test]
    fn starting_the_service_clears_the_user_stop() {
        let dir = configured_data_dir();
        set_user_stopped(dir.path(), true).unwrap();
        set_user_stopped(dir.path(), false).unwrap();
        assert!(!is_user_stopped(dir.path()));
        assert!(self_heal_allowed(dir.path()), "点了启动之后自愈应当恢复");
        // 没停过也能清（首启向导调 start_daemon 时就是这种情况）。
        set_user_stopped(dir.path(), false).unwrap();
    }

    #[test]
    fn self_heal_stays_out_of_an_unconfigured_machine() {
        // 向导没走完不自愈——这条是原有语义，本卡不许改掉。
        let dir = tempfile::tempdir().unwrap();
        assert!(!self_heal_allowed(dir.path()));
    }

    /// 向导门的判据（DESK-36 #456 的矩阵，#1045 起在 Rust）。反证：去掉
    /// `show_wizard` 里的 `&& !user_stopped`，「用户停了服务」那条必须红；去掉
    /// 开头的 `online` 判断，「在线永不显示」那条必须红。
    #[test]
    fn the_wizard_gate_separates_user_stop_from_an_abandoned_wizard() {
        // 从没配置过 → 完整向导；残留的停止标记也不能让新机器跳过向导。
        assert!(show_wizard(false, false, false, false));
        assert!(show_wizard(false, false, true, false));
        // 配过、服务没注册、不是用户停的 → 向导中途退出，回向导。
        assert!(show_wizard(true, false, false, false));
        // 用户停了服务（autostart 被卸）→ 不回向导。
        assert!(!show_wizard(true, false, true, false));
        // 正常常驻、只是暂时离线 → 不显示（走自愈 / 启动按钮）。
        assert!(!show_wizard(true, true, false, false));
        // 服务在线 → 任何配置状态都不显示。
        for configured in [false, true] {
            for installed in [false, true] {
                for user_stopped in [false, true] {
                    assert!(
                        !show_wizard(configured, installed, user_stopped, true),
                        "online 时不许显示向导：{configured} {installed} {user_stopped}"
                    );
                }
            }
        }
    }

    // ── #456 后续：更新流程也尊重「用户主动停止」 ─────────────────────────

    #[test]
    fn update_brings_back_a_daemon_the_user_did_not_stop() {
        // 没停过：pause 杀了什么，装完就拉回什么（W1 原语义不变）。
        let dir = configured_data_dir();
        assert!(update_resume_allowed(dir.path()));
    }

    #[test]
    fn update_never_revives_a_daemon_the_user_stopped() {
        // 规则：用户点了停止 → 一直停着，只有用户点「启动后台服务」才恢复。
        let dir = configured_data_dir();
        set_user_stopped(dir.path(), true).unwrap();
        assert!(
            !update_resume_allowed(dir.path()),
            "用户主动停止了服务，更新装完却仍然判定要拉起它（#456 后续）"
        );
        // 标记原样保留：更新之后界面仍是「启动后台服务」。
        assert!(is_user_stopped(dir.path()));
    }

    #[test]
    fn update_resume_does_not_require_a_finished_wizard() {
        // 「没停过时行为不变」：原来更新后恢复不看 config.toml，这里也不许加。
        let dir = tempfile::tempdir().unwrap();
        assert!(update_resume_allowed(dir.path()));
    }

    /// DESK-65 (#957)：启动对账先看停止标记，停过就只撤不写。
    /// `reconcile_autostart_registration` 本体走真实 adapter，测试里不能调；钉接线。
    #[test]
    fn autostart_reconcile_checks_the_user_stop_before_rewriting() {
        let src = include_str!("distribution.rs").replace("\r\n", "\n");
        let product = src.split("#[cfg(test)]").next().unwrap_or(&src);
        let start = product
            .find("fn reconcile_autostart_registration(")
            .expect("对账函数");
        let rest = &product[start..];
        let reconcile = &rest[..rest.find("\n}\n").expect("函数结尾")];
        let guard = reconcile
            .find("is_user_stopped(")
            .expect("对账必须先看停止标记");
        let rewrite = reconcile
            .find("reconcile_autostart(&sidecar)")
            .expect("对账");
        assert!(guard < rewrite, "停止标记必须在改写登记之前判定");
    }
}
