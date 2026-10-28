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
/// - `configured`：[`configured_verdict`] 的结论。没配置过 = 完整向导；**不知道**（常驻
///   服务登记着但还没连上）不进向导——等服务、连不上走错误页（#1246）。
/// - 配过、服务没注册（`!installed`）= 向导中途退出，回向导继续走（xixi 实测反馈 3）；
///   但用户自己点了停止（`user_stopped`，DESK-36 #456）不算中途退出——停服会卸
///   autostart，把它当中途退出会让重开 App 被打回完整 onboard，所以留在主界面给
///   「启动服务」。
///
/// 纯函数：daemon 与服务状态由调用点探测后传入，判据本身单测（含反证）。
pub(crate) fn show_wizard(
    configured: Configured,
    installed: bool,
    user_stopped: bool,
    online: bool,
) -> bool {
    if online {
        return false;
    }
    match configured {
        Configured::No => true,
        Configured::Unknown => false,
        Configured::Yes => !installed && !user_stopped,
    }
}

/// #1246：常驻 daemon 对「配过没有」的回答。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DaemonAnswer {
    /// 答了 `status`，没说未配置。
    Configured,
    /// 答了 `status.unconfigured = true`：在等首启向导（#1115 / #1167）。
    Unconfigured,
    /// 连不上 / 不答。
    Unreachable,
}

/// #1246：壳对「配过没有」的结论。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Configured {
    Yes,
    No,
    /// 常驻服务登记着、但此刻问不到 daemon：等它（显示「正在连接服务」，连不上走错误页），
    /// 绝不当成没配置——那会把已配置的机器打回向导，而向导对已配置的 daemon 是死路
    /// （「新位置不能与当前照片库相同」）。
    Unknown,
}

/// #1246：「配过没有」的真相在 daemon——它是 config 的唯一写者（#1115）。壳不再看
/// config.toml 在不在：服务形态下那个文件对壳是否可读，取决于 ACL 有没有被外部操作冲掉
/// （安装器升级时的 `icacls /reset`），读不到就把已配置的机器当成全新安装。
///
/// daemon 答了就听它的。问不到时：
/// - 用户停过服务 ⇒ 配过（停止只在主界面里能点）；
/// - 常驻服务登记着（Windows 服务由安装器预装，被禁用也算登记）⇒ 不知道，等它；
/// - 都不是 ⇒ 没配置（macOS 首启：向导第 3 步才登记 LaunchAgent，此前没有常驻 daemon 可问）。
///
/// 纯函数，单测覆盖每条分支（含反证）。
pub(crate) fn configured_verdict(
    answer: DaemonAnswer,
    installed: bool,
    user_stopped: bool,
) -> Configured {
    match answer {
        DaemonAnswer::Configured => Configured::Yes,
        DaemonAnswer::Unconfigured => Configured::No,
        DaemonAnswer::Unreachable if user_stopped => Configured::Yes,
        DaemonAnswer::Unreachable if installed => Configured::Unknown,
        DaemonAnswer::Unreachable => Configured::No,
    }
}

/// 【DESK-42 #604】开机自启登记对账（App 启动时跑一次，独立线程）。
///
/// 缺陷现场：`~/Library/LaunchAgents/com.hawkeyexb.ppass.desktop.daemon.plist` 被钉在
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
    let Some(sidecar) = platform::hosting().bundled_daemon_path(&exe) else {
        return;
    };
    // 开发运行（target/ 里没有 sidecar）等情况：没有可对账的目标，直接跳过。
    if !sidecar.is_file() {
        return;
    }
    // DESK-65 (#957)：用户主动停过服务 ⇒ 唯一正确的状态是「没有登记」。对账
    // 只往这个方向收敛：残留的登记（上次停止时没撤掉、或老版本留下的）撤掉，
    // 绝不改写、更不拉起——改写登记在 Windows 上会顺带把服务跑起来。
    let home = ShellHome::current();
    if home.user_stopped() {
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
                &home,
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

/// #1238：壳判断「配过没有」「用户停过没有」时读的东西各在哪。只有这一个入口——
/// 读的位置必须和写的位置是同一处，否则就是 #1238：Windows 服务形态的配置在
/// `%ProgramData%\P-Pass`，壳却去读用户目录，服务一停就把已配置的机器打回首启向导。
///
/// - `config_dir`：daemon 的 config.toml 所在目录（[`platform::HostingAdapter::daemon_config_dir`]），
///   只用来**显示**库位置；「配过没有」问 daemon（#1246）。
/// - `stop_switch`：服务形态「要不要运行」的开关文件（daemon 开机自检、安装器都读它）；
///   有它就只认它，壳不再另记一份。
/// - `state_dir`：壳自己的数据目录，没有开关文件的形态（macOS 等）在这里落停止标记。
/// - `ask_daemon` / `installed`：「配过没有」的两样事实（[`configured_verdict`]），测试注入。
#[derive(Debug, Clone)]
pub(crate) struct ShellHome {
    pub config_dir: std::path::PathBuf,
    pub stop_switch: Option<std::path::PathBuf>,
    pub state_dir: std::path::PathBuf,
    pub ask_daemon: fn() -> DaemonAnswer,
    pub installed: fn() -> bool,
}

impl ShellHome {
    /// 本机当前形态。
    pub(crate) fn current() -> Self {
        let hosting = platform::hosting();
        Self {
            config_dir: hosting.daemon_config_dir(),
            stop_switch: hosting.service_stop_switch(),
            state_dir: platform::adapter().data_dir(),
            ask_daemon: crate::ask_daemon,
            installed: || platform::hosting().autostart_installed().unwrap_or(false),
        }
    }

    /// 壳与 daemon 同一用户、同一目录（macOS、测试）。daemon 不在线、没有常驻登记 = 首启。
    #[cfg(test)]
    pub(crate) fn shared(dir: &std::path::Path) -> Self {
        Self {
            config_dir: dir.to_path_buf(),
            stop_switch: None,
            state_dir: dir.to_path_buf(),
            ask_daemon: || DaemonAnswer::Unreachable,
            installed: || false,
        }
    }

    /// 配过没有（#1246：问 daemon，见 [`configured_verdict`]）。
    pub(crate) fn configured(&self) -> Configured {
        configured_verdict((self.ask_daemon)(), (self.installed)(), self.user_stopped())
    }

    /// config.toml 里给人看的库位置（`data_dir`）。
    pub(crate) fn configured_library_dir(&self) -> Option<String> {
        crate::ipc::read_config_data_dir(&self.config_dir)
    }

    /// 用户主动停过服务。开关文件读到 `stopped` 才算；读不出 / 坏内容按「要运行」，
    /// 与 daemon 开机自检同一口径（[`platform::stop_switch::read_at`]）。
    pub(crate) fn user_stopped(&self) -> bool {
        match &self.stop_switch {
            Some(switch) => platform::stop_switch::read_at(switch) == Some(false),
            None => user_stopped_marker(&self.state_dir).exists(),
        }
    }

    /// 落 / 清「用户主动停止」。失败要报出来：没落下 = 自愈照样会把服务拉回来，
    /// 用户意图被静默撤销，这正是 #456 本身。
    pub(crate) fn set_user_stopped(&self, stopped: bool) -> Result<(), String> {
        let key = if stopped {
            "ui.err_stop_mark_write"
        } else {
            "ui.err_stop_mark_clear"
        };
        if let Some(switch) = &self.stop_switch {
            return platform::stop_switch::write_at(switch, !stopped)
                .map_err(|e| crate::ipc::ui_err(key, &[("err", &e)]));
        }
        let marker = user_stopped_marker(&self.state_dir);
        if stopped {
            std::fs::create_dir_all(&self.state_dir)
                .map_err(|e| crate::ipc::ui_err(key, &[("err", &e)]))?;
            std::fs::write(&marker, b"user stopped the background service\n")
                .map_err(|e| crate::ipc::ui_err(key, &[("err", &e)]))
        } else {
            match std::fs::remove_file(&marker) {
                Ok(()) => Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(crate::ipc::ui_err(key, &[("err", &e)])),
            }
        }
    }
}

/// 自愈判据（纯函数，单测覆盖）：不是「没配置过」、且不是用户主动停的，才允许自愈。
/// 「没配置过」是首启向导的事；「用户停的」要等用户自己点「启动服务」。**不知道**
/// （服务登记着但连不上，#1246）要拉：常驻服务自己决定进不进未配置状态。
pub(crate) fn self_heal_allowed(home: &ShellHome) -> bool {
    home.configured() != Configured::No && !home.user_stopped()
}

/// #1060：更新前要不要「为更新暂停」常驻服务。用户自己停过就**不动**：
/// 它本来就停着，更新前后都保持停止（暂停本身不碰停止记录，所以也不会改写这份意图）。
pub(crate) fn should_pause_for_update(home: &ShellHome) -> bool {
    !home.user_stopped()
}

/// #1060：新壳启动时要不要把服务拉回来（「更新后恢复」）。三个条件缺一不可：
/// 自愈判据过（配置过、且用户没停——停过的更新前后都保持停止）、服务管理器里
/// 有登记（`resident_service_available`）、此刻内核不在线（在线 = 无事可做；
/// 登录时 launchd 并发拉起的那份也落在这条，随后 `restart_resident_daemon(false)`
/// 会报 AlreadyRunning，不会二次重启）。
pub(crate) fn update_resume_needed(home: &ShellHome, registered: bool, online: bool) -> bool {
    registered && !online && self_heal_allowed(home)
}

/// DESK-60 (#877)：登记缺失时要不要补。与自愈同一条判据——配置过（不是首启，
/// DAE-03 ②）、且不是用户主动停的（DESK-36）——再加上平台声明
/// 「登记会被系统流程删掉」。
pub(crate) fn restore_missing_autostart_allowed(platform_restores: bool, home: &ShellHome) -> bool {
    platform_restores && self_heal_allowed(home)
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

    // ── #1060：为更新暂停 / 更新后恢复的判据 ───────────────────────────

    /// 用户停过服务：更新前后都保持停止——不暂停、不恢复。
    /// 反证：把 `should_pause_for_update` 改成恒 true / `update_resume_needed` 去掉
    /// `self_heal_allowed` → 对应断言红。
    #[test]
    fn user_stopped_service_is_neither_paused_nor_resumed() {
        let dir = tempfile::tempdir().unwrap();
        assert!(should_pause_for_update(&configured_home(dir.path())));
        assert!(update_resume_needed(
            &configured_home(dir.path()),
            true,
            false
        ));
        configured_home(dir.path()).set_user_stopped(true).unwrap();
        assert!(!should_pause_for_update(&configured_home(dir.path())));
        assert!(!update_resume_needed(
            &configured_home(dir.path()),
            true,
            false
        ));
    }

    /// 已登记、没停过、内核不在线 ⇒ 拉；在线 / 没登记 / 没配置过 ⇒ 不拉。
    #[test]
    fn resume_only_when_registered_configured_and_offline() {
        let dir = tempfile::tempdir().unwrap();
        assert!(
            !update_resume_needed(&ShellHome::shared(dir.path()), true, false),
            "没配置过（首启向导的事）"
        );
        assert!(update_resume_needed(
            &configured_home(dir.path()),
            true,
            false
        ));
        assert!(
            !update_resume_needed(&configured_home(dir.path()), true, true),
            "已在线"
        );
        assert!(
            !update_resume_needed(&configured_home(dir.path()), false, false),
            "没登记"
        );
    }

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
        // 没有常驻登记（UserAutostart 兜底实现 / 未登记）：没有"归谁管"可言 ⇒ 不动。
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

    /// 一个「向导走完了」的家：daemon 答「配过」（#1246：真相在 daemon，不看 config.toml）。
    fn configured_home(dir: &std::path::Path) -> ShellHome {
        ShellHome {
            ask_daemon: || DaemonAnswer::Configured,
            ..ShellHome::shared(dir)
        }
    }

    #[test]
    fn self_heal_revives_a_configured_daemon_that_was_not_stopped_by_the_user() {
        // 崩了 / 被更新流程停了又没拉回来（W1 那个 NSIS 场景）——自愈的本职。
        let dir = tempfile::tempdir().unwrap();
        assert!(self_heal_allowed(&configured_home(dir.path())));
    }

    #[test]
    fn self_heal_never_revives_a_daemon_the_user_stopped() {
        // #456 本体：用户点了停止 → 自愈不许在冷却窗口过后把它拉回来。
        let dir = tempfile::tempdir().unwrap();
        configured_home(dir.path()).set_user_stopped(true).unwrap();
        assert!(
            !self_heal_allowed(&configured_home(dir.path())),
            "用户主动停止了服务，自愈却仍然判定要拉起它（#456）"
        );
    }

    /// DESK-60 (#877)：登记缺失时补不补——#877 卡面要求的三种状态 + 平台开关。
    /// 反证：判据去掉停止标记那条 → 第二条断言红；去掉配置那条 → 第三条红。
    #[test]
    fn a_missing_autostart_is_restored_only_for_a_configured_unstopped_install() {
        let dir = tempfile::tempdir().unwrap();
        assert!(
            restore_missing_autostart_allowed(true, &configured_home(dir.path())),
            "配置在、没停过、登记丢了：应补登记（#877 现场）"
        );
        assert!(
            !restore_missing_autostart_allowed(false, &configured_home(dir.path())),
            "平台没声明会被系统删登记：保持「未登记 → 不动」"
        );
        configured_home(dir.path()).set_user_stopped(true).unwrap();
        assert!(
            !restore_missing_autostart_allowed(true, &configured_home(dir.path())),
            "用户主动停过服务：重装后也不许补（尊重停止）"
        );
        let fresh = tempfile::tempdir().unwrap();
        assert!(
            !restore_missing_autostart_allowed(true, &ShellHome::shared(fresh.path())),
            "没配置过（首启）：不许顺手登记（DAE-03 ②）"
        );
    }
    #[test]
    fn user_stop_survives_an_app_restart() {
        // 持久化语义：标记在盘上，换一个「进程」（重新读同一目录）仍然在。
        let dir = tempfile::tempdir().unwrap();
        configured_home(dir.path()).set_user_stopped(true).unwrap();
        let reopened = dir.path().to_path_buf();
        assert!(configured_home(&reopened).user_stopped());
        assert!(!self_heal_allowed(&configured_home(&reopened)));
    }

    #[test]
    fn starting_the_service_clears_the_user_stop() {
        let dir = tempfile::tempdir().unwrap();
        configured_home(dir.path()).set_user_stopped(true).unwrap();
        configured_home(dir.path()).set_user_stopped(false).unwrap();
        assert!(!configured_home(dir.path()).user_stopped());
        assert!(
            self_heal_allowed(&configured_home(dir.path())),
            "点了启动之后自愈应当恢复"
        );
        // 没停过也能清（首启向导调 start_daemon 时就是这种情况）。
        ShellHome::shared(dir.path())
            .set_user_stopped(false)
            .unwrap();
    }

    #[test]
    fn self_heal_stays_out_of_an_unconfigured_machine() {
        // 向导没走完不自愈——这条是原有语义，本卡不许改掉。
        let dir = tempfile::tempdir().unwrap();
        assert!(!self_heal_allowed(&ShellHome::shared(dir.path())));
    }

    // ── #1238：Windows 服务形态——配置在 ProgramData、停止只认开关文件 ──────────

    /// 服务形态的家：config.toml 在「ProgramData」（与壳的数据目录不是同一处），
    /// 停止记录是安装器建好的开关文件，服务由安装器预装（登记着）。
    fn service_home(
        ask_daemon: fn() -> DaemonAnswer,
    ) -> (tempfile::TempDir, tempfile::TempDir, ShellHome) {
        let programdata = tempfile::tempdir().unwrap();
        let user = tempfile::tempdir().unwrap();
        let switch = programdata.path().join("wanted-state");
        std::fs::write(&switch, "running").unwrap();
        let home = ShellHome {
            config_dir: programdata.path().to_path_buf(),
            stop_switch: Some(switch),
            state_dir: user.path().to_path_buf(),
            ask_daemon,
            installed: || true,
        };
        (programdata, user, home)
    }

    /// #1238 回归现场：向导走完、用户在设置里停了服务（daemon 不在线）→ 不回向导、不自愈、
    /// 更新不拉起；点启动后恢复。
    /// 反证：`configured_verdict` 去掉「停过 ⇒ 配过」→ 「不回向导」那条红；user_stopped() 改回
    /// 只看用户目录的标记 → 「不自愈」那条红。
    #[test]
    fn a_configured_service_stopped_by_the_user_stays_on_the_main_screen() {
        let (_programdata, user, home) = service_home(|| DaemonAnswer::Unreachable);
        assert_eq!(
            home.configured(),
            Configured::Unknown,
            "没停过、连不上：等它"
        );
        assert!(self_heal_allowed(&home), "没停过：崩了要自愈");

        home.set_user_stopped(true).unwrap();
        assert_eq!(
            std::fs::read_to_string(home.stop_switch.as_ref().unwrap()).unwrap(),
            "stopped",
            "停止写进 daemon 与安装器读的同一个开关文件"
        );
        assert!(
            !user_stopped_marker(user.path()).exists(),
            "服务形态不另记一份停止标记"
        );
        assert!(home.user_stopped());
        assert_eq!(
            home.configured(),
            Configured::Yes,
            "停止只在主界面能点：停过 ⇒ 配过"
        );
        assert!(
            !show_wizard(home.configured(), true, home.user_stopped(), false),
            "停了服务不许回首启向导（#1238）"
        );
        assert!(!self_heal_allowed(&home), "用户停的不许自愈拉回（#456）");
        assert!(!should_pause_for_update(&home));
        assert!(!update_resume_needed(&home, true, false));

        home.set_user_stopped(false).unwrap();
        assert!(!home.user_stopped());
        assert!(self_heal_allowed(&home), "点了启动之后自愈恢复");
    }

    /// 服务形态、向导还没走完（daemon 答「未配置」）→ 照旧进向导；用户目录里残留的
    /// 老停止标记不算数（只认开关文件）。
    #[test]
    fn an_unconfigured_service_still_gets_the_wizard() {
        let (_programdata, user, home) = service_home(|| DaemonAnswer::Unconfigured);
        std::fs::write(user_stopped_marker(user.path()), "x").unwrap();
        assert_eq!(home.configured(), Configured::No);
        assert!(
            !home.user_stopped(),
            "开关是 running：残留的用户目录标记不算"
        );
        assert!(show_wizard(
            home.configured(),
            true,
            home.user_stopped(),
            false
        ));
        assert!(!self_heal_allowed(&home));
    }

    /// 开关文件读不出 / 坏内容 = 按「要运行」，与 daemon 开机自检同一口径。
    #[test]
    fn a_junk_stop_switch_means_running() {
        let (_programdata, _user, home) = service_home(|| DaemonAnswer::Unreachable);
        std::fs::write(home.stop_switch.as_ref().unwrap(), "banana").unwrap();
        assert!(!home.user_stopped());
        std::fs::remove_file(home.stop_switch.as_ref().unwrap()).unwrap();
        assert!(!home.user_stopped());
    }

    /// 库位置从 daemon 的 config 目录读（Windows 服务形态 = ProgramData），不从壳的数据目录读。
    #[test]
    fn the_library_is_read_from_the_daemon_config_dir() {
        let (programdata, user, home) = service_home(|| DaemonAnswer::Configured);
        std::fs::write(
            programdata.path().join("config.toml"),
            "data_dir = 'C:/Users/me/Pictures/P-Pass Library'\n",
        )
        .unwrap();
        std::fs::write(user.path().join("config.toml"), "data_dir = 'stale'\n").unwrap();
        assert_eq!(
            home.configured_library_dir().as_deref(),
            Some("C:/Users/me/Pictures/P-Pass Library")
        );
    }

    /// 向导门的判据（DESK-36 #456 的矩阵，#1045 起在 Rust）。反证：去掉
    /// `show_wizard` 里的 `&& !user_stopped`，「用户停了服务」那条必须红；去掉
    /// 开头的 `online` 判断，「在线永不显示」那条必须红。
    #[test]
    fn the_wizard_gate_separates_user_stop_from_an_abandoned_wizard() {
        use Configured::{No, Unknown, Yes};
        // 从没配置过 → 完整向导；残留的停止标记也不能让新机器跳过向导。
        assert!(show_wizard(No, false, false, false));
        assert!(show_wizard(No, false, true, false));
        // 配过、服务没注册、不是用户停的 → 向导中途退出，回向导。
        assert!(show_wizard(Yes, false, false, false));
        // 用户停了服务（autostart 被卸）→ 不回向导。
        assert!(!show_wizard(Yes, false, true, false));
        // 正常常驻、只是暂时离线 → 不显示（走自愈 / 启动按钮）。
        assert!(!show_wizard(Yes, true, false, false));
        // #1246：不知道（服务登记着、还没连上）→ 不显示，等服务 / 走错误页。
        // 反证：`Unknown => true` → 红。
        assert!(!show_wizard(Unknown, true, false, false));
        // 服务在线 → 任何配置状态都不显示。
        for configured in [No, Unknown, Yes] {
            for installed in [false, true] {
                for user_stopped in [false, true] {
                    assert!(
                        !show_wizard(configured, installed, user_stopped, true),
                        "online 时不许显示向导：{configured:?} {installed} {user_stopped}"
                    );
                }
            }
        }
    }

    /// #1246：「配过没有」的判据矩阵。daemon 答了就听它的；问不到时停过 ⇒ 配过、
    /// 登记着 ⇒ 不知道、都不是 ⇒ 没配置（macOS 首启）。
    /// 反证：「登记着 ⇒ 不知道」改成 `No` → `Unknown` 那条红；去掉「停过 ⇒ 配过」→
    /// 两条 `Yes` 里至少一条红；问不到一律当 `No` → 两条都红。
    #[test]
    fn configured_comes_from_the_daemon_not_from_a_file() {
        use DaemonAnswer::{Configured as Said, Unconfigured, Unreachable};
        for installed in [false, true] {
            for stopped in [false, true] {
                assert_eq!(
                    configured_verdict(Said, installed, stopped),
                    Configured::Yes
                );
                assert_eq!(
                    configured_verdict(Unconfigured, installed, stopped),
                    Configured::No
                );
            }
        }
        assert_eq!(configured_verdict(Unreachable, true, true), Configured::Yes);
        assert_eq!(
            configured_verdict(Unreachable, false, true),
            Configured::Yes
        );
        assert_eq!(
            configured_verdict(Unreachable, true, false),
            Configured::Unknown
        );
        assert_eq!(
            configured_verdict(Unreachable, false, false),
            Configured::No,
            "macOS 首启：没有常驻登记、也没有 daemon 可问 → 向导"
        );
    }

    /// #1246 回归现场：服务版覆盖安装后 config.toml 对壳不可读、App 抢在服务就绪前启动。
    /// 以前壳看文件判「没配置」→ 向导（对已配置的 daemon 是死路）。现在：服务登记着、
    /// 问不到 daemon ⇒ 不知道 ⇒ 不进向导、允许自愈拉起服务；daemon 一答「配过」就是主界面。
    /// 反证：`configured()` 改回看 config.toml 是否存在 → 第一条红。
    #[test]
    fn an_unreadable_config_before_the_service_answers_never_shows_the_wizard() {
        let (programdata, _user, home) = service_home(|| DaemonAnswer::Unreachable);
        assert!(!programdata.path().join("config.toml").exists());
        assert!(!show_wizard(
            home.configured(),
            true,
            home.user_stopped(),
            false
        ));
        assert!(self_heal_allowed(&home), "等不来就把服务拉起来");
        let answered = ShellHome {
            ask_daemon: || DaemonAnswer::Configured,
            ..home
        };
        assert_eq!(answered.configured(), Configured::Yes);
        assert!(!show_wizard(answered.configured(), true, false, false));
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
            .find("home.user_stopped()")
            .expect("对账必须先看停止记录");
        let rewrite = reconcile
            .find("reconcile_autostart(&sidecar)")
            .expect("对账");
        assert!(guard < rewrite, "停止标记必须在改写登记之前判定");
    }
}
