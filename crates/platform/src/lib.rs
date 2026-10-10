//! Platform — PlatformAdapter trait + Windows/macOS implementations
//! (T-040, 架构 §4 原样实施).
//!
//! Architecture enforcement: this is the ONLY crate allowed to use
//! `#[cfg(windows)]` / `#[cfg(target_os = "macos")]` (rule B.2).
//!
//! The pure parsers (`pmset` / `powercfg` output → [`PowerHint`]) are
//! platform-independent functions so both are unit-tested everywhere;
//! only the syscall/process wrappers live behind cfg.

// DESK-33 (#325)：clippy.toml 禁止产品代码直接 `Command::new`；单元测试
// 里的子进程（拉起测试二进制自身等）不面向用户，统一放行。
#![cfg_attr(test, allow(clippy::disallowed_methods))]

use std::path::PathBuf;

// DESK-24 (#173)：数据目录搬家。整个模块**不在 cfg 里**——里面全是
// `rename` / `read_dir`，没有一行平台专属代码，三条 lane 都跑得到它的测试。
// 只有 Windows 有遗留位置要搬，那部分知识在 `windows.rs`。
//
// 那也正是这条 `allow` 的由来：**今天只有 `windows.rs` 调它**，所以在别的
// 平台上整个模块的函数都没有调用方，`clippy -D warnings` 会报 8 条
// `is never used`。本地 `just ci` 跑在 Windows 上看不见，远端 Linux lane 上
// 必红（PR #368 实测）。
//
// 不改成 `pub mod` 让它「有调用方」：那是拿扩大公开 API 去换一条 lint 闭嘴。
// 这个模块是平台内部的管道，不该被 daemon / 桌面壳绕过适配器直接调。
// 只在非 Windows 上放行，Windows 那边的死代码照样挡得住。
#[cfg_attr(not(windows), allow(dead_code))]
mod data_migration;

#[cfg(target_os = "macos")]
mod macos;
// QA-09 迁移（#211）：macOS 与 Linux 共享的 unix 实现。迁过来的分叉里有
// 3 处是 `#[cfg(unix)]`（同时覆盖两者），没有共享模块就得抄两遍。
#[cfg(unix)]
mod unix;
#[cfg(windows)]
mod windows;
// #287：只给测试用的建链能力。默认不编译，见该模块顶部说明。
#[cfg(feature = "test-support")]
pub mod test_support;

pub use data_migration::DataDirMigration;

#[cfg(target_os = "macos")]
pub use macos::MacosAdapter;
#[cfg(windows)]
pub use windows::WindowsAdapter;

/// How the daemon stays resident on this platform (§4 对照表).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServiceMode {
    /// User-level autostart process (registry Run key + watchdog).
    UserAutostart,
    /// LaunchAgent with KeepAlive (crash-restart built in).
    LaunchAgent,
}

/// Current sleep policy, for the first-run wizard's diagnosis (T-042).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PowerHint {
    /// The machine never sleeps on idle — backups run unattended.
    NeverSleeps,
    /// Sleeps after this many idle minutes — the wizard offers a fix.
    SleepsWhenIdle { minutes: u32 },
    /// Could not determine (parse failure, exotic setup).
    Unknown,
}

/// Keeps the system awake while alive (RAII). Dropping releases the
/// assertion. MVP 尽力而为：合盖必睡等平台边界由诊断文案覆盖（§4）。
///
/// NET-26 (#419)：guard 是 `Send` 的，可以在**任意线程**上 drop——daemon
/// 在 tokio 多线程 runtime 的一个 worker 上拿、在另一个 worker 上放。各平台
/// 实现必须保证这一点（Windows 的线程级执行状态因此由专属线程持有）。
pub struct AwakeGuard {
    #[allow(dead_code)] // the handle's Drop is the whole point
    inner: AwakeGuardImpl,
}

#[cfg(target_os = "macos")]
type AwakeGuardImpl = macos::CaffeinateGuard;
#[cfg(windows)]
type AwakeGuardImpl = windows::ExecutionStateGuard;
#[cfg(not(any(target_os = "macos", windows)))]
type AwakeGuardImpl = ();

// Compile-time proof of the `Send` contract documented on `AwakeGuard`.
const _: fn() = || {
    fn assert_send<T: Send>() {}
    assert_send::<AwakeGuard>();
};

/// Device private-key storage (DPAPI / Keychain).
pub trait KeyStore {
    fn store(&self, name: &str, secret: &[u8]) -> Result<()>;
    fn load(&self, name: &str) -> Result<Option<Vec<u8>>>;
    fn delete(&self, name: &str) -> Result<()>;
}

#[derive(Debug, thiserror::Error)]
pub enum PlatformError {
    #[error("{action}: {source}")]
    Io {
        action: &'static str,
        #[source]
        source: std::io::Error,
    },
    #[error("{action}: {detail}")]
    Failed {
        action: &'static str,
        detail: String,
    },
    /// DESK-22 (#171)：用户在系统授权弹窗上点了**取消**。
    ///
    /// 单开一个变体而不是并进 `Failed`：取消不是失败，是用户的选择。
    /// 混在一起，调用方要么把取消当错误吓人一跳，要么干脆吞掉假装成功。
    #[error("{action}: 用户取消了授权")]
    Cancelled { action: &'static str },
}

pub type Result<T> = std::result::Result<T, PlatformError>;

/// 内置 daemon 可执行文件的基名（不含平台扩展名）。
///
/// QA-09 迁移（#211）：迁移前这个字符串在桌面壳 `lib.rs` 里被
/// `if cfg!(windows) { "ppf-daemon.exe" } else { "ppf-daemon" }` **抄了三遍**。
pub const DAEMON_EXECUTABLE_STEM: &str = "ppf-daemon";

/// 杀 daemon 进程的结果。
///
/// QA-09 迁移（#211）：**「进程本来就没在跑」不是错误**，是一种正常结果。
/// 各系统表达它的方式不同（unix 的 `pkill` 用退出码 1；Windows 原来是
/// `taskkill` 的 128，DESK-52 #787 起改为进程快照里没有匹配项），而迁移前这条知识被抄散在三个调用点上，其中两处直接
/// `let _ = ...` 把结果丢了。DESK-25 (#208) 就是因为**另一处**没看退出码、
/// 把「没杀掉」当成杀成功、紧接着去 spawn 第二个 daemon 才出的事。
///
/// 收进这个枚举之后判据只有一份：真失败（权限不足、被杀软拦、参数错）
/// 才是 `Err`。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KillOutcome {
    /// 进程在，已经杀掉了。
    Killed,
    /// 进程本来就没在跑。
    NotRunning,
}

/// DAE-05：卷容量水位（`free` 对齐 unix `statvfs` 的 `f_bavail` 语义）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VolumeStats {
    pub free: u64,
    pub total: u64,
}

/// DESK-16 (#165)：系统缩略图器产出的一帧，**未编码的 RGBA 像素**。
///
/// 为什么不返回「写好的 PNG 文件路径」：那样本 crate 就得带一个图像编码
/// 器，而编码能力已经在 `crates/media-codec`（`image` 依赖）里了。让本
/// crate 只做「调系统 API 取像素」这一件事，编码留给调用方 —— 分层更干净，
/// 也省掉一次落盘再读回。
///
/// `rgba` 的长度**必须**等于 `width * height * 4`；构造方负责保证，调用方
/// 可以据此直接喂给 `image::RgbaImage::from_raw`。
#[derive(Debug, Clone)]
pub struct SystemThumbnail {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

/// QA-09 迁移（#211）：一个平台动作的结果口径。
///
/// 为什么不用 `Result<()>`：`Ok(())` 会把「这个平台上其实什么都没做」
/// 说成成功。本仓这一轮在修的缺陷全是这个形状——#189 的 paths 让必需
/// 检查永不汇报、#192 的清理脚本静默不删、#268 的 0 字节 daemon 注册完
/// 报 resident。三个变体把「做了 / 没实现 / 不需要」分开，调用方就没法
/// 把缺口当成完成。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Applied {
    /// 本平台做了这件事。
    Done,
    /// 本平台**没有实现**——已知缺口，别当成做过了。
    Unsupported,
    /// 本平台**机制上不需要**做这件事，不是缺口。
    /// 例：Windows 的命名管道不在文件系统留端点，没有残留要清。
    NotApplicable,
}

/// 【DESK-42 #604】开机自启登记的对账结果。
///
/// 为什么不能只用 `bool`：`false` 会把「本来就没登记」和「登记正确、不用动」
/// 混成一件事——这正是本卡要修的缺陷形状（登记路径漂移后没人发现）。变体各自可断言，
/// 日志也能说清到底发生了什么。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AutostartReconcile {
    /// 本来就没有登记：**不动**（纯新启动不得篡改用户的开机自启配置，DAE-03 ②）。
    NotRegistered,
    /// 已登记且指向期望路径：不动。
    Unchanged,
    /// 已登记但指向别处（换目录 / 更新 / 从临时或备份副本注册过）：已用期望路径重写。
    Rewritten,
    /// 【#726】登记条目在，但读不出目标路径（写了一半 / 被改坏）：已用期望路径重写。
    ///
    /// 与 `Rewritten` 分开：日志要能说清是「修好了一个坏文件」还是「改了一个旧路径」。
    Repaired,
    /// **闸门拦下**：当前可执行文件不在「稳定安装位置」（dmg 挂载点 / 下载目录 /
    /// App Translocation 随机路径 / 备份副本 …），一律不碰登记。
    ///
    /// 为什么单列一个变体：这是「我们**故意**没动」而不是「没有需要动的」——
    /// 静默跳过会让闸门失效时没人发现（外部评审 2026-10-01 在 PR #611 上拦下的
    /// 正是「不判位置就静默改名」这件事）。
    SkippedUnstableLocation,
}

/// 【#726】登记条目的三种状态。
///
/// 为什么不用 `Option<PathBuf>`：`None` 会把「没登记」和「登记文件坏了」混成一件事——
/// 前者不许动（DAE-03 ②），后者必须重写，否则每次开机服务都起不来、且不会自己好。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AutostartRegistration {
    /// 没有登记条目（用户没开自启，或已关掉）。
    Absent,
    /// 有登记条目，但读不出目标路径。
    Unreadable,
    /// 登记指向这个可执行文件。
    At(std::path::PathBuf),
}

/// 【DESK-42 #604】对账决策（纯函数——各分支由单测钉死）。
///
/// 缺陷现场：登记被钉在 `~/P-Pass-Backups/<日期>/old-app/P-Pass.app/...`，
/// 而实际安装的 App 在 `/Applications`——没登记/指向自己/指向别处/读不出四种情形
/// 必须能被分开判定，否则「漂移」永远只是静默的旧值。
pub fn reconcile_decision(
    registered: &AutostartRegistration,
    expected: &std::path::Path,
) -> AutostartReconcile {
    match registered {
        AutostartRegistration::Absent => AutostartReconcile::NotRegistered,
        AutostartRegistration::Unreadable => AutostartReconcile::Repaired,
        AutostartRegistration::At(p) if p == expected => AutostartReconcile::Unchanged,
        AutostartRegistration::At(_) => AutostartReconcile::Rewritten,
    }
}

/// 架构 §4 trait —— 签名原样实施（updater/notify 的完整实现随
/// T-041/T-062 落地，此处为可用的最小形态）.
pub trait PlatformAdapter: Send + Sync {
    // 生命周期
    fn install_autostart(&self, exec: &std::path::Path) -> Result<()>;
    fn autostart_installed(&self) -> Result<bool>;
    fn uninstall_autostart(&self) -> Result<()>;

    /// 【DESK-42 #604】已登记的开机自启**目标可执行路径**。
    ///
    /// `None` = 没有登记（或本平台读不出，如 Windows 的 Run key 未实现读取）——
    /// 注意这与「登记正确」不是一回事，调用方必须自己能分开（见 `AutostartReconcile`）。
    fn autostart_registered_exec(&self) -> Result<Option<std::path::PathBuf>> {
        Ok(None)
    }

    /// 【#726】登记条目的状态：比 [`Self::autostart_registered_exec`] 多分出「读不出」。
    ///
    /// 默认实现只能分出两种（读不出的平台没有「坏文件」这个概念）；能分的平台覆盖它。
    fn autostart_registration(&self) -> Result<AutostartRegistration> {
        Ok(match self.autostart_registered_exec()? {
            Some(p) => AutostartRegistration::At(p),
            None => AutostartRegistration::Absent,
        })
    }

    /// 【DESK-42 #604】对账**闸门**：本平台是否允许用 `expected` 改写开机自启登记。
    ///
    /// 默认 `false` = **保守拒绝**：平台必须显式声明哪些位置算「稳定安装位置」，
    /// 没声明就不许动用户的登记。真机风险（外部评审 2026-10-01 拦停）：dmg 挂载点、
    /// 「下载」目录、macOS App Translocation 随机路径都是一次性路径，把登记改指到
    /// 那里 → 下次开机 launchd 拉起一个已消失的可执行文件，服务静默起不来。
    fn autostart_reconcile_allowed(&self, _expected: &std::path::Path) -> bool {
        false
    }

    /// 【DESK-42 #604】开机自启登记对账：登记存在但指向别处或读不出 → 用 `expected`
    /// 重写（幂等）；未登记 → 不动；一致 → 不动；**位置不稳定 → 闸门拦下，不碰**。
    ///
    /// 由启动路径调用一次即可自愈「换目录 / 更新后路径漂移」的历史登记。
    /// ⚠️ 闸门在**读登记之前**判定：不稳定的位置连读都不读，避免任何后续分支
    /// 有机会写。
    fn reconcile_autostart(&self, expected: &std::path::Path) -> Result<AutostartReconcile> {
        if !self.autostart_reconcile_allowed(expected) {
            return Ok(AutostartReconcile::SkippedUnstableLocation);
        }
        let registered = self.autostart_registration()?;
        let action = reconcile_decision(&registered, expected);
        if matches!(
            action,
            AutostartReconcile::Rewritten | AutostartReconcile::Repaired
        ) {
            self.install_autostart(expected)?;
        }
        Ok(action)
    }

    fn service_mode(&self) -> ServiceMode;
    // 安全
    fn key_store(&self) -> Box<dyn KeyStore>;
    // 电源（MVP 尽力而为）
    fn assert_awake(&self) -> Result<AwakeGuard>;
    fn power_hint(&self) -> PowerHint;
    // 系统集成
    fn notify(&self, title: &str, body: &str);
    /// 本平台**生效的**数据目录。
    ///
    /// DESK-24 (#173)：Windows 上这个值不是常量——`%APPDATA%`（Roaming）时代
    /// 的老目录只要还在，返回的就是它，搬完了才换成新位置。这样「搬迁失败」
    /// 退化成「保持原样」，而不是指着一个空目录（见 [`DataDirMigration`]）。
    /// 想真正换过去，调用方得先调 [`Self::migrate_legacy_data_dir`]。
    fn data_dir(&self) -> PathBuf;

    /// DESK-24 (#173)：把遗留位置的数据搬到 [`Self::data_dir`] 现在该在的地方。
    ///
    /// **在任何人读 data dir 之前调一次**，进程生命周期里一次就够。daemon 那边
    /// 还得排在日志初始化**之前**——日志文件路径本身就是从 data dir 算出来的。
    ///
    /// 不返回 `Result`：搬迁失败不得导致启动失败（卡面第 2 条），所以类型上
    /// 就没给出「炸掉」这个选项，失败表达成 [`DataDirMigration::Deferred`]。
    ///
    /// 默认实现 = 本平台**没有遗留位置这回事**（macOS 的 Application Support、
    /// Linux 的 XDG 目录当初就选对了）。这不是缺口。
    fn migrate_legacy_data_dir(&self) -> DataDirMigration {
        DataDirMigration::NothingToDo
    }
    /// DEVLOG-02：daemon 在 `PPF_LOG_FILE` 未设时的**平台默认**日志文件。
    ///
    /// Windows 必须返回 `Some`：HKCU Run 键没有任何重定向能力，release 又不再
    /// 分配控制台，不落盘就等于没有日志。
    ///
    /// macOS 也返回 `Some`（DIAG-B1）：原先指望 launchd plist 的
    /// `StandardErrorPath`，但桌面壳还有好几条一次性 spawn 路径（注册失败兜底、
    /// 更新后恢复、重启）把 stdio 全接到 `/dev/null`——真机上 0.6.0 的 daemon
    /// 就是这么跑的，日志整段丢失。daemon 在 macOS 上**同时**写这个文件和
    /// stderr（后者留给向导读启动错误），见 main.rs。
    /// DAE-05：`path` 所在卷的容量水位。`None` = 本平台没有实现（调用方
    /// 应当序列化成 null，而不是编一个数字出来）。
    ///
    /// `free` 的语义**必须**是「无特权写入者真正可用的字节数」，对齐 unix
    /// 侧 `statvfs` 的 `f_bavail`（也就是 `df` / Finder 显示的那个数），
    /// 而不是卷上的物理空闲量——两者在有配额/保留区的卷上不一样。
    fn volume_stats(&self, path: &std::path::Path) -> Option<VolumeStats> {
        let _ = path;
        None
    }

    /// 入参是**生效的** data dir（由调用方解析 env / 平台约定后给出），
    /// 因为一次性 daemon 靠 `PPF_DATA_DIR` 做隔离，日志不跟着走就会污染
    /// 真实日志文件。默认实现返回 `None`——既无 launchd 托管也无 Run 键的
    /// 平台自己决定。
    fn default_log_file(&self, data_dir: &std::path::Path) -> Option<PathBuf> {
        let _ = data_dir;
        None
    }

    /// DIAG-B1：写 [`default_log_file`](Self::default_log_file) 时是否**同时**照旧写
    /// stderr。macOS 为 true：launchd 托管时 stderr 是 `.err`，桌面向导读它的最后
    /// 一行报启动失败（DESK-09）。默认 false（Windows release 没有控制台可写）。
    fn default_log_tees_stderr(&self) -> bool {
        false
    }

    /// QA-09 迁移（#211）：把文件权限收紧到「只有属主可读写」。
    ///
    /// 用在身份密钥这类文件上。默认实现返回 [`Applied::Unsupported`] 而
    /// **不是** `Ok(Applied::Done)`——没实现却报做过了，正是这套口径要防的。
    fn restrict_to_owner(&self, path: &std::path::Path) -> Result<Applied> {
        let _ = path;
        Ok(Applied::Unsupported)
    }

    /// QA-09 迁移（#211）：把本进程自己的 stderr 截断到 0 字节。
    ///
    /// 日志洪水防线的最后一环（前面还有「折叠重复行」那道，那道是所有
    /// 平台共同的主防线）。只有当 stderr 被托管方重定向到文件时才有意义。
    fn truncate_own_stderr(&self) -> Applied {
        Applied::Unsupported
    }

    /// DESK-22 (#171)：关掉「空闲自动睡眠」，让备份能在无人值守时跑完。
    ///
    /// 两个平台都要走系统的授权弹窗（macOS 是 Touch ID/密码，Windows 是
    /// UAC），所以 `Err(PlatformError::Cancelled)` 是**正常路径之一**，
    /// 调用方必须把它和真失败分开呈现。
    ///
    /// ⚠️ 实现方**必须回读确认**再返回 `Done`。Windows 上实测过：
    /// `powercfg /x standby-timeout-ac 0` 在非管理员下**退出码是 0，但注册表
    /// 根本没被写**（用注册表键的最后写入时间比对出来的）。拿退出码当"已
    /// 生效"就是本仓这一轮在修的那类缺陷——静默没做却报成功。
    fn disable_auto_sleep(&self) -> Result<Applied> {
        Ok(Applied::Unsupported)
    }

    /// QA-09 迁移（#211）：清掉被强杀的前任留在文件系统里的 IPC 端点。
    ///
    /// 默认 [`Applied::NotApplicable`]：只有 unix domain socket 会落文件，
    /// 命名管道这类端点不存在「残留」这个问题。
    fn remove_stale_ipc_endpoint(&self, name: &str) -> Applied {
        let _ = name;
        Applied::NotApplicable
    }

    /// DESK-16 (#165)：向系统自带的缩略图器要一帧视频首帧。
    ///
    /// 这是回退链 `ffmpeg → 系统兜底` 里「系统兜底」那一环在**本 crate** 的
    /// 落点。两个平台的形态不对称，原因是系统能力不对称：
    ///
    /// - **macOS** 有 `/usr/bin/qlmanage` 这个 CLI，所以 `media-codec` 自己
    ///   探测那个固定路径就够了（`quicklook.rs`），**不经过本方法** —— 探测
    ///   一个 unix 路径不需要 cfg，那是它能待在 media-codec 里的原因。
    /// - **Windows** 没有对等的 CLI，只能走 COM（`IShellItemImageFactory`）。
    ///   COM 调用必然带 `#[cfg(windows)]`，而红线 B.2 要求平台 cfg 只许待在
    ///   本 crate —— 所以 Windows 那半必须从这里出去。
    ///
    /// `Ok(None)` = **本平台没有实现**（不是「这个文件没有缩略图」）。
    /// 真取不到缩略图返回 `Err`，让调用方能把「平台不支持」与「这个文件
    /// 失败了」分开 —— 混成一个 `None` 就又回到「静默降级说不清原因」。
    ///
    /// `max_px` 是最长边的**上界**，实现方不许放大（与 `qlmanage -s` 同义）。
    fn system_video_thumbnail(
        &self,
        src: &std::path::Path,
        max_px: u32,
    ) -> Result<Option<SystemThumbnail>> {
        let _ = (src, max_px);
        Ok(None)
    }

    // ── QA-09 迁移（#211）桌面壳批次 ─────────────────────────────
    //
    // 以下五个能力此前以 `#[cfg]` / `cfg!()` 的形式散在
    // `apps/desktop/src-tauri/src/lib.rs` 里（18 处）。搬过来之后调用点
    // 一个 cfg 不留，`tools/arch-check.sh` 对那个文件的整文件豁免因此
    // 可以删掉——那是本卡的销号条件。

    /// 这个系统的名字，喂给前端 `wizard_state` 的 json。
    ///
    /// **没有默认实现**：每个系统都有名字，编一个默认值只会在某天悄悄
    /// 把平台标错，而前端拿它决定显示哪套文案。
    fn platform_name(&self) -> &'static str;

    /// 内置 daemon 可执行文件的文件名。
    ///
    /// 默认是不带扩展名的 [`DAEMON_EXECUTABLE_STEM`]——这对除 Windows 外的
    /// 每个系统都成立，所以它是个诚实的默认值，不是猜的。
    fn daemon_executable_name(&self) -> &'static str {
        DAEMON_EXECUTABLE_STEM
    }

    /// 这个系统「电源与睡眠」设置页的 URI；`None` = 没有可直接跳转的页面。
    ///
    /// 只给 URI，**不给「怎么打开」**。理由：
    ///
    /// 1. 本 crate 是 **daemon 也在用**的，而 daemon 不是 Tauri 应用——
    ///    把 `tauri_plugin_opener` 引进来是错的方向。
    /// 2. 另一条路是在这里手写 `ShellExecuteW`，那等于把 DESK-19 (#168)
    ///    刚修好的「不闪黑窗」用手写代码重做一遍，**有回归风险、换不来
    ///    任何好处**。opener 插件的候选命令条条带 `CREATE_NO_WINDOW`。
    ///
    /// 真正属于平台知识的是「这个系统的电源设置在哪」，不是「怎么打开一个
    /// URI」。后者是桌面壳（Tauri 层）的事。
    fn power_settings_uri(&self) -> Option<&'static str> {
        None
    }

    /// 托盘图标是不是「模板图标」（单色、随系统深浅色自动反色）。
    ///
    /// 这是 macOS 的习惯，所以默认 `false`——**默认值取的是多数派行为，
    /// 不是「不知道」**。命名上刻意不叫 `is_macos()`：那只是把 cfg 挪了个
    /// 地方，没有说出为什么要分叉。
    fn tray_icon_is_template(&self) -> bool {
        false
    }

    /// 托盘左键是出菜单（macOS 习惯）还是开窗口（Windows / Linux 习惯）。
    ///
    /// DESK-18 (#167)：Windows 上左键出菜单与系统习惯相反。
    fn tray_shows_menu_on_left_click(&self) -> bool {
        false
    }

    /// 杀掉正在跑的内置 daemon 进程。
    ///
    /// **没有默认实现**：三个系统都做得到这件事，编一个「不支持」的默认值
    /// 等于给将来的实现留一条静默什么都不做的路。
    ///
    /// 「进程本来就没在跑」返回 [`KillOutcome::NotRunning`]，**不是 `Err`**。
    /// 真失败（权限不足、被杀软拦、参数错）才是 `Err`——判据见各平台实现。
    fn kill_daemon_process(&self) -> Result<KillOutcome>;

    // ── UPD-06 (#616)：让**系统**负责"重启桌面壳" ─────────────────────
    //
    // 背景：更新装完磁盘上已是新版，但正在跑的壳仍是旧版，而**壳不能原地
    // 换代码**。0.7.5 的解法是壳自己 `restart_app`（spawn 自己 + exit），
    // 那要在被替换的进程里自证没竞态（托盘常驻 + single-instance）。
    //
    // 更好的一层：把"杀 + 拉"交给系统的服务管理器（macOS = launchd），
    // **杀和拉都不在壳里发生**，single-instance 竞态在架构上消失，而且
    // 系统会告诉我们新实例的 pid（可验证）。
    //
    // ⚠️ 登记 ≠ 守卫：壳的登记**只解决"系统知道怎么启动它"**，因此**绝不挂
    // KeepAlive** —— 挂上 KeepAlive 用户就再也退不掉 App（托盘「退出 App」
    // 会被立刻复活）。守卫（崩溃自恢复）是 daemon 那一侧的事。
    // 壳是**登录项**（`RunAtLoad=true`，2026-10-02 验收人拍板）：登录时由 launchd
    // 拉起常驻托盘 —— 目的就是让"启动/重启壳"归系统管，而不是让进程自己换自己。
    // 没有 KeepAlive ⇒ 用户仍可完全退出，只是下次登录会再起来。

    /// 本平台给"桌面壳"用的服务标签（`None` = 本平台没有这个能力，调用方
    /// 降级回壳自己重启 / 显式重启）。
    fn shell_agent_label(&self) -> Option<&'static str> {
        None
    }

    /// **本进程是不是服务管理器自己拉起来的那一份**（macOS = launchd 设的
    /// `XPC_SERVICE_NAME` 等于我们的壳 label）。
    ///
    /// 为什么这条判据不可省（2026-10-02 读手册 + 推演所得）：
    /// `kickstart -k` 的 "kill the running instance" 只能杀掉**服务管理器自己
    /// 启动的**那个进程。用户从访达/Dock 直接打开的壳，launchd 手里没有它的
    /// pid ⇒ `-k` 无物可杀 ⇒ kickstart 只会**再拉起第二个实例**；而壳装了
    /// single-instance，第二个实例会把焦点交回旧壳后自杀 ⇒ 用户点"重启"什么
    /// 都没发生（比不重启更糟：看起来像坏掉）。
    ///
    /// 所以：只有"我确实是 launchd 的那一份"时才走系统路径；否则走壳自己重启
    /// （`tauri::process::restart`，0.7.5 起就在用、已在真机跑过）。
    /// 让系统路径成为常态需要产品决定"壳是否由 launchd 拉起（登录项）"——
    /// 已挂在 #616 的 PR 描述里等拍板，不在本卡悄悄改。
    fn shell_agent_started_us(&self) -> bool {
        false
    }

    /// 把**当前壳**登记成"按需可启动"的服务（幂等）。
    ///
    /// 只在需要换壳前调用；**绝不 bootout 正在运行的实例**（那会当场把壳
    /// 杀掉，而不是"等需要时再重启"）。已登记且指向同一个可执行文件 = 无操作。
    fn register_shell_agent(&self, exec: &std::path::Path) -> Result<()> {
        let _ = exec;
        Err(PlatformError::Failed {
            action: "register_shell_agent",
            detail: "此平台没有服务管理器，壳由调用方自行重启".into(),
        })
    }

    /// 已登记的壳服务指向哪个可执行文件（`None` = 没登记）。
    /// 调用方**必须先比对这个路径**再 kickstart，否则可能拉起另一份副本。
    fn shell_agent_registered_exec(&self) -> Result<Option<std::path::PathBuf>> {
        Ok(None)
    }

    /// **服务管理器眼里正在跑的壳**的 pid（`None` = 没在跑 / 没登记 / 本平台没有）。
    ///
    /// 为什么需要它（UPD-07 #617）：owner（daemon）在动手换壳前，必须先确认
    /// "壳登记里的那个实例**就是用户现在用的这一把**" —— `kickstart -k` 只杀得到
    /// 服务管理器自己启动的进程；pid 对不上（壳是用户手动打开的、或登记里的实例
    /// 已经死了）⇒ kickstart 只会再拉起一个实例、被 single-instance 顶掉 ⇒
    /// 用户点"重启"看起来什么都没发生。**宁可不动，也不要制造这种假动作。**
    fn shell_agent_running_pid(&self) -> Option<u32> {
        None
    }

    /// 让服务管理器**杀掉并重启**壳，返回新实例 pid。
    /// 调用方：`shell_agent_label().is_some()` 且登记路径 == 当前可执行文件时才用。
    fn kickstart_shell_agent(&self) -> Result<u32> {
        Err(PlatformError::Failed {
            action: "kickstart_shell_agent",
            detail: "此平台没有服务管理器".into(),
        })
    }

    /// 磁盘上**安装包**的版本（macOS = `defaults read <bundle>/Contents/Info.plist
    /// CFBundleShortVersionString`；`None` = 读不到或本平台没实现）。
    ///
    /// 用途（UPD-06 #616）：与"进程自己编译进去的版本"比对，就是"更新装完了、
    /// 但**运行中的这只壳/这个 daemon 还是旧版**"的**确定性判据**——可执行文件
    /// 在 `/Applications` 下跨更新路径不变，包在它下面被换掉，于是"读到的包版本
    /// ≠ 我的编译版本"只有一种解释：我是旧进程、磁盘已是新版。
    ///
    /// ⚠️ 读不到必须返回 `None`（= 不知道），**绝不许**降级成"版本不一致"：
    /// 那会让一切正常的机器也去做一次没必要的换壳/重启（读不到＝无从判断，
    /// fail-safe 的方向永远是"什么都不做"）。
    fn installed_bundle_version(&self) -> Option<String> {
        None
    }

    // ── #667 / #732：常驻 daemon 必须始终归服务管理器托管 ───────────────
    //
    // 2026-10-08 取证（#667 评论）：更新后在跑的内核是旧壳一次性 spawn 的，
    // launchd 手里没有它（`state = not running`）⇒ 它崩了 KeepAlive 不会拉；
    // 一次性 spawn 的 stdio 接 null，LaunchAgent 的 `.err` 里也没有它的记录。
    // 解法同 UPD-06 的思路：**杀和拉都交给服务管理器**，壳只发一句
    // "按磁盘上的文件（重新）拉起来"。

    /// 服务管理器眼里正在跑的常驻 daemon 的 pid（`None` = 没在跑 / 没登记 /
    /// 本平台没有服务管理器）。与 daemon 自报的 `status.pid` 比对，就是
    /// "在跑的这个内核归不归服务管理器管"的确定性判据。
    fn resident_daemon_pid(&self) -> Option<u32> {
        None
    }

    /// 让服务管理器按**磁盘上的文件**拉起常驻 daemon。
    ///
    /// `kill_running = true`：在跑的那个（服务管理器自己启动的）先被杀掉再拉
    /// ——换版本用；`false`：没在跑才拉、在跑就不动——自愈用。
    ///
    /// ⚠️ 只管得到**服务管理器自己启动的**实例。一次性 spawn 出来的野生实例
    /// 它杀不到；新拉起来的实例若与它同版本会按 DAE-01 退位（exit 0 不重拉）
    /// ⇒ 结果仍是野生实例在岗。所以调用方要先让野生实例退位，再调本方法。
    ///
    /// 返回 `NotRegistered` / `Unsupported` 时**什么都没做**，调用方退回
    /// 一次性 spawn（Windows 的 Run key 没有服务管理器语义，行为不变）。
    fn restart_resident_daemon(&self, kill_running: bool) -> Result<ResidentRestart> {
        let _ = kill_running;
        Ok(ResidentRestart::Unsupported)
    }
}

/// [`PlatformAdapter::restart_resident_daemon`] 的结论。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResidentRestart {
    /// 服务管理器已（重新）拉起，新实例 pid（`-p` 报出来的，可验证）。
    Started { pid: u32 },
    /// 没杀也没拉：`kill_running=false` 且它本来就在跑。
    AlreadyRunning { pid: u32 },
    /// 本机没有登记常驻服务（用户停过服务 / 首启向导没走完）——什么都没做。
    NotRegistered,
    /// 本平台没有服务管理器语义——什么都没做。
    Unsupported,
}

/// DESK-33 (#325) / DESK-54 (#814)：产品代码启动子进程的**唯一入口**。
///
/// 等价于 `std::process::Command::new(program)`，只多一件事：在 Windows 上
/// 带 `CREATE_NO_WINDOW`。桌面壳与 daemon 的 release 构建都是 GUI 子系统，
/// 直接拉起 console 子系统程序（cmd / taskkill / ffmpeg …）时 Windows 会新
/// 分配一个控制台——用户看到黑窗一闪（#168 / #787 / #814）。对 GUI 子系统的
/// 子进程（比如 ppf-daemon sidecar）这个标志没有效果，所以一律带上即可。
///
/// 直接写 `Command::new` 会被 clippy 的 `disallowed-methods` 拦下（见仓根
/// `clippy.toml`）。调用方不用、也不许关心平台差异。
pub fn command(program: impl AsRef<std::ffi::OsStr>) -> std::process::Command {
    #[allow(clippy::disallowed_methods)] // 唯一被批准的构造点。
    #[cfg_attr(not(windows), allow(unused_mut))]
    let mut cmd = std::process::Command::new(program);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt as _;
        use windows_sys::Win32::System::Threading::CREATE_NO_WINDOW;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

/// The adapter for the current platform.
#[cfg(target_os = "macos")]
pub fn adapter() -> impl PlatformAdapter {
    MacosAdapter::new()
}
#[cfg(windows)]
pub fn adapter() -> impl PlatformAdapter {
    WindowsAdapter::new()
}
/// Headless/server platforms (Linux cloud boxes run the daemon too):
/// data dir follows XDG; desktop-only capabilities answer honestly.
#[cfg(not(any(target_os = "macos", windows)))]
pub fn adapter() -> impl PlatformAdapter {
    HeadlessAdapter
}

#[cfg(not(any(target_os = "macos", windows)))]
pub struct HeadlessAdapter;

#[cfg(not(any(target_os = "macos", windows)))]
impl PlatformAdapter for HeadlessAdapter {
    fn install_autostart(&self, _exec: &std::path::Path) -> Result<()> {
        Err(PlatformError::Failed {
            action: "autostart",
            detail: "unsupported on this platform (use systemd)".into(),
        })
    }
    fn autostart_installed(&self) -> Result<bool> {
        Ok(false)
    }
    fn uninstall_autostart(&self) -> Result<()> {
        Ok(())
    }
    fn service_mode(&self) -> ServiceMode {
        ServiceMode::UserAutostart
    }
    fn key_store(&self) -> Box<dyn KeyStore> {
        Box::new(NoKeyStore)
    }
    fn assert_awake(&self) -> Result<AwakeGuard> {
        // Servers don't idle-sleep; a no-op guard keeps callers simple.
        Ok(AwakeGuard { inner: () })
    }
    fn power_hint(&self) -> PowerHint {
        PowerHint::NeverSleeps
    }
    fn notify(&self, _title: &str, _body: &str) {}
    fn data_dir(&self) -> PathBuf {
        let base = std::env::var("XDG_DATA_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into()))
                    .join(".local/share")
            });
        base.join("p-pass")
    }

    // QA-09 迁移（#211）：headless 平台实际上就是 Linux（unix），四个能力
    // 直接走共享的 unix 实现。这里的 cfg 在 platform crate 内部，是 B.2
    // 规则的自留地。`not(unix)` 那半保持诚实的「没实现」，不编数字。
    fn volume_stats(&self, path: &std::path::Path) -> Option<VolumeStats> {
        #[cfg(unix)]
        {
            crate::unix::volume_stats(path)
        }
        #[cfg(not(unix))]
        {
            let _ = path;
            None
        }
    }
    fn restrict_to_owner(&self, path: &std::path::Path) -> Result<Applied> {
        #[cfg(unix)]
        {
            crate::unix::restrict_to_owner(path)
        }
        #[cfg(not(unix))]
        {
            let _ = path;
            Ok(Applied::Unsupported)
        }
    }
    fn truncate_own_stderr(&self) -> Applied {
        #[cfg(unix)]
        {
            crate::unix::truncate_own_stderr()
        }
        #[cfg(not(unix))]
        {
            Applied::Unsupported
        }
    }
    fn platform_name(&self) -> &'static str {
        // headless 平台实际上就是 Linux；迁移前桌面壳那行 `else` 分支
        // 给的也是 "linux"，行为一字不变。
        "linux"
    }
    fn kill_daemon_process(&self) -> Result<KillOutcome> {
        #[cfg(unix)]
        {
            crate::unix::kill_daemon_process()
        }
        #[cfg(not(unix))]
        {
            Err(PlatformError::Failed {
                action: "kill_daemon_process",
                detail: "这个平台没有实现杀进程".into(),
            })
        }
    }
    fn remove_stale_ipc_endpoint(&self, name: &str) -> Applied {
        #[cfg(unix)]
        {
            crate::unix::remove_stale_ipc_endpoint(name)
        }
        #[cfg(not(unix))]
        {
            let _ = name;
            Applied::NotApplicable
        }
    }
}

#[cfg(not(any(target_os = "macos", windows)))]
struct NoKeyStore;

#[cfg(not(any(target_os = "macos", windows)))]
impl KeyStore for NoKeyStore {
    fn store(&self, _name: &str, _secret: &[u8]) -> Result<()> {
        Err(PlatformError::Failed {
            action: "key store",
            detail: "no secure store on this platform".into(),
        })
    }
    fn load(&self, _name: &str) -> Result<Option<Vec<u8>>> {
        Ok(None)
    }
    fn delete(&self, _name: &str) -> Result<()> {
        Ok(())
    }
}

// ── Pure parsers (unit-tested on every platform) ─────────────────────

/// Parse `pmset -g custom` output: the smallest positive `sleep` value
/// across power profiles wins (the machine sleeps whenever the current
/// profile says so); 0 = never.
pub fn parse_pmset(output: &str) -> PowerHint {
    let mut min_positive: Option<u32> = None;
    let mut saw_sleep = false;
    for line in output.lines() {
        let t = line.trim();
        // ` sleep    10` — exact key match, not displaysleep/disksleep.
        let mut parts = t.split_whitespace();
        if parts.next() == Some("sleep") {
            if let Some(v) = parts.next().and_then(|v| v.parse::<u32>().ok()) {
                saw_sleep = true;
                if v > 0 {
                    min_positive = Some(min_positive.map_or(v, |m| m.min(v)));
                }
            }
        }
    }
    match (saw_sleep, min_positive) {
        (true, None) => PowerHint::NeverSleeps,
        (true, Some(minutes)) => PowerHint::SleepsWhenIdle { minutes },
        (false, _) => PowerHint::Unknown,
    }
}

/// Parse `powercfg /query <scheme> SUB_SLEEP STANDBYIDLE` style output:
/// the current AC setting index is seconds (0 = never).
pub fn parse_powercfg(output: &str) -> PowerHint {
    for line in output.lines() {
        let t = line.trim();
        // "Current AC Power Setting Index: 0x00000384"
        if let Some(rest) = t
            .strip_prefix("Current AC Power Setting Index:")
            .map(str::trim)
        {
            let seconds = if let Some(hex) = rest.strip_prefix("0x") {
                u32::from_str_radix(hex, 16).ok()
            } else {
                rest.parse::<u32>().ok()
            };
            return match seconds {
                Some(0) => PowerHint::NeverSleeps,
                Some(s) => PowerHint::SleepsWhenIdle {
                    minutes: s.div_ceil(60),
                },
                None => PowerHint::Unknown,
            };
        }
    }
    PowerHint::Unknown
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pmset_sleep_zero_means_never() {
        let out = "System-wide power settings:\nCurrently in use:\n standby 1\n sleep 0\n displaysleep 10\n";
        assert_eq!(parse_pmset(out), PowerHint::NeverSleeps);
    }

    #[test]
    fn pmset_positive_sleep_reports_minutes() {
        let out = "Battery Power:\n sleep 10\nAC Power:\n sleep 30\n";
        assert_eq!(parse_pmset(out), PowerHint::SleepsWhenIdle { minutes: 10 });
    }

    #[test]
    fn pmset_displaysleep_is_not_system_sleep() {
        let out = " displaysleep 5\n disksleep 10\n";
        assert_eq!(parse_pmset(out), PowerHint::Unknown);
    }

    #[test]
    fn powercfg_hex_seconds_to_minutes() {
        let out = "  Current AC Power Setting Index: 0x00000384\n"; // 900 s
        assert_eq!(
            parse_powercfg(out),
            PowerHint::SleepsWhenIdle { minutes: 15 }
        );
    }

    #[test]
    fn powercfg_zero_means_never() {
        let out = "Current AC Power Setting Index: 0x00000000";
        assert_eq!(parse_powercfg(out), PowerHint::NeverSleeps);
    }

    #[test]
    fn powercfg_garbage_is_unknown() {
        assert_eq!(parse_powercfg("no such section"), PowerHint::Unknown);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_plist_keepalive_spares_clean_exit() {
        // DAE-02 缺陷①：退位实例 exit(0) 后 launchd 不得重拉（无条件
        // KeepAlive 会把它无限复活成 churn）。plist 必须是
        // SuccessfulExit=false 语义——成功退出不重拉、崩溃/被杀才复活。
        let plist = macos::agent_plist(std::path::Path::new(
            "/Applications/P-Pass.app/Contents/MacOS/ppf-daemon",
        ));
        assert!(
            plist.contains("<key>SuccessfulExit</key><false/>"),
            "clean exit (stand-down) must not relaunch: {plist}"
        );
        assert!(
            !plist.contains("<key>KeepAlive</key><true/>"),
            "unconditional KeepAlive would churn a stepped-down instance: {plist}"
        );
        assert!(
            plist.contains("<key>RunAtLoad</key><true/>"),
            "RunAtLoad must stay"
        );
    }

    /// 【DESK-42 #604】对账决策的四条分支：
    /// 未登记（不许多手去装）、登记正确（不许动它）、登记漂移（必须重写）、登记损坏（#726，必须重写）。
    #[test]
    fn reconcile_decision_covers_all_four_shapes() {
        use AutostartRegistration::{Absent, At, Unreadable};
        let expected = std::path::Path::new("/Applications/P-Pass.app/Contents/MacOS/ppf-daemon");
        // 真机实测值（#604 挂号现象）：登记被钉在备份目录里的旧 App 上。
        let stale = std::path::Path::new(
            "/Users/lizhaowen/P-Pass-Backups/2026-09-30-before-0.6.2/old-app/P-Pass.app/Contents/MacOS/ppf-daemon",
        );

        assert_eq!(
            reconcile_decision(&Absent, expected),
            AutostartReconcile::NotRegistered,
            "没登记就不许顺手装（DAE-03 ②：纯新启动不得改用户的开机自启）"
        );
        assert_eq!(
            reconcile_decision(&At(expected.into()), expected),
            AutostartReconcile::Unchanged,
            "登记正确时不许反复重写（否则每次启动都 bootout/bootstrap 一次）"
        );
        assert_eq!(
            reconcile_decision(&At(stale.into()), expected),
            AutostartReconcile::Rewritten,
            "指向别处（换目录/更新/备份副本）必须判要重写——这就是本卡的现象"
        );
        // #726：登记文件在但读不出 ⇒ 必须修。当成「没登记」⇒ 每次开机服务都起不来、不会自己好。
        assert_eq!(
            reconcile_decision(&Unreadable, expected),
            AutostartReconcile::Repaired,
            "登记文件损坏必须判要重写，不许当成没登记"
        );
    }

    /// 【DESK-42 #604】读得出登记路径，是对账的前提；读不出来就永远发现不了漂移。
    #[cfg(target_os = "macos")]
    #[test]
    fn macos_plist_round_trips_its_program_argument() {
        let exec = std::path::Path::new("/Applications/P-Pass.app/Contents/MacOS/ppf-daemon");
        let text = macos::agent_plist(exec);
        assert_eq!(
            macos::plist_program_argument(&text).as_deref(),
            Some("/Applications/P-Pass.app/Contents/MacOS/ppf-daemon"),
            "生成的 plist 必须能被自己的解析器读回同一个路径"
        );
        // 反证：把 ProgramArguments 段换掉，必须读不出——否则「读到了」可能只是巧合。
        let broken = text.replace(
            "<key>ProgramArguments</key>",
            "<key>NotProgramArguments</key>",
        );
        assert_eq!(macos::plist_program_argument(&broken), None);
    }

    /// #726：登记文件「在但读不出」必须归成 `Unreadable`，不许混进「没登记」。
    /// 每种坏法都是真实会出现的形状：写到一半断电、被截成空文件、被改坏。
    /// 反证：把 `registration_from_read` 里的 `Unreadable` 换回 `Absent` → 本测试必须红。
    #[cfg(target_os = "macos")]
    #[test]
    fn macos_unreadable_registration_is_not_mistaken_for_absent() {
        use macos::registration_from_read as classify;
        use AutostartRegistration::{Absent, At, Unreadable};
        let exec = std::path::Path::new("/Applications/P-Pass.app/Contents/MacOS/ppf-daemon");
        let good = macos::agent_plist(exec);

        assert_eq!(classify(Ok(good.clone())).unwrap(), At(exec.into()));
        let not_found = std::io::Error::from(std::io::ErrorKind::NotFound);
        assert_eq!(classify(Err(not_found)).unwrap(), Absent);

        let half = good[..good.find("<key>ProgramArguments</key>").unwrap() + 10].to_string();
        for (shape, text) in [
            ("写到一半", half),
            ("空文件", String::new()),
            ("被改坏", "not a plist at all".to_string()),
        ] {
            assert_eq!(
                classify(Ok(text)).unwrap(),
                Unreadable,
                "{shape}：登记文件在但读不出，必须判损坏（由对账重写）"
            );
        }
        // 读文件本身出错（权限等）照旧报错，不许静默归类
        let denied = std::io::Error::from(std::io::ErrorKind::PermissionDenied);
        assert!(classify(Err(denied)).is_err());
    }

    /// #726：原子写入——写完内容完整、临时文件不残留、已有文件被整体替换。
    #[cfg(target_os = "macos")]
    #[test]
    fn macos_write_atomic_replaces_whole_file_and_leaves_no_temp() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("com.p-pass.daemon.plist");
        std::fs::write(&path, "half a plist <key>Progr").unwrap();

        macos::write_atomic(&path, "complete").unwrap();

        assert_eq!(std::fs::read_to_string(&path).unwrap(), "complete");
        let names: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["com.p-pass.daemon.plist"], "临时文件不许残留");
    }

    /// UPD-06 (#616)：壳是**登录项**，但**不是守卫**。
    ///
    /// 两件事必须同时成立：
    /// ① `RunAtLoad=true` —— 登录时由 launchd 拉起（"启动壳"归系统管；也正因为
    ///    如此 `kickstart -k` 才有东西可杀，见 `shell_agent_started_us`）；
    /// ② **不许出现 `KeepAlive`** —— 挂上它用户就再也退不掉 App（托盘「退出 App」
    ///    会被立刻复活）。用户可以完全退出，只是下次登录会再起来。
    ///
    /// 反证：把 `KeepAlive` 段加回去、或把 `RunAtLoad` 改成 `<false/>` → 本测试必须红。
    #[cfg(target_os = "macos")]
    #[test]
    fn shell_agent_is_a_login_item_but_never_guarded() {
        let exec = std::path::Path::new("/Applications/P-Pass.app/Contents/MacOS/p-pass-desktop");
        let plist = macos::shell_agent_plist(exec);
        assert!(
            !plist.contains("KeepAlive"),
            "壳的登记不许挂 KeepAlive（用户会退不掉 App）: {plist}"
        );
        assert!(
            plist.contains("<key>RunAtLoad</key><true/>"),
            "壳是登录项：登录时由 launchd 拉起，kickstart 才有东西可杀: {plist}"
        );
        assert_eq!(
            macos::plist_program_argument(&plist),
            Some(exec.display().to_string()),
            "ProgramArguments 必须指向壳自己的可执行文件，kickstart 才有意义"
        );
        // 能力要真的暴露出来：调用方靠它决定走"系统重启"还是退化到自己重启。
        assert_eq!(
            PlatformAdapter::shell_agent_label(&macos::MacosAdapter::new()),
            Some("com.p-pass.shell")
        );
    }

    /// UPD-06 (#616)：安装包版本的判据建立在"从可执行文件推出它所属的 `.app`"上，
    /// 形状不对必须返回 `None`（= **不知道**）——猜错方向的代价是"一切正常的机器
    /// 也去做一次没必要的换壳/重启"。
    #[cfg(target_os = "macos")]
    #[test]
    fn bundle_root_only_accepts_the_app_bundle_shape() {
        use macos::bundle_root;
        use std::path::{Path, PathBuf};
        assert_eq!(
            bundle_root(Path::new(
                "/Applications/P-Pass.app/Contents/MacOS/p-pass-desktop"
            )),
            Some(PathBuf::from("/Applications/P-Pass.app"))
        );
        // 不是 .app 布局的一律 None：开发构建、裸二进制、少一层目录
        assert_eq!(bundle_root(Path::new("/usr/local/bin/ppf-daemon")), None);
        assert_eq!(
            bundle_root(Path::new("/Applications/P-Pass.app/p-pass-desktop")),
            None
        );
        assert_eq!(
            bundle_root(Path::new("/Applications/P-Pass.app/Contents/MacOS")),
            None
        );
    }

    /// UPD-07 (#617)：owner 换壳前必须先确认"登记里的实例就是用户现在这把壳"。
    /// 判据取自 `launchctl print` 的真实输出形状（样本来自本机 `ai.hermes.gateway`）。
    /// 反证：把解析改成"取任意含数字的行"→ 下面「没在跑」那条会读到别的数字而红。
    #[cfg(target_os = "macos")]
    #[test]
    fn launchd_job_pid_only_reads_the_running_instances_pid_line() {
        use macos::launchd_job_pid;
        // 正在跑（真机样本，pid 换成了假数）
        let running = "gui/501/ai.hermes.gateway = {\n\tactive count = 1\n\tpath = /Users/x/Library/LaunchAgents/ai.hermes.gateway.plist\n\ttype = LaunchAgent\n\tstate = running\n\n\tprogram = /usr/bin/python\n\tlast exit code = 0\n\tpid = 992\n}\n";
        assert_eq!(launchd_job_pid(running), Some(992));
        // 没在跑：launchd 不打 pid 行（真机样本）
        let not_running = "gui/501/com.apple.SafariHistoryServiceAgent = {\n\tactive count = 0\n\tstate = not running\n\n\tprogram = /usr/libexec/SafariHistoryServiceAgent\n\tlast exit code = 78\n}\n";
        assert_eq!(launchd_job_pid(not_running), None);
        // 别的行里出现的数字不许被当成 pid
        assert_eq!(launchd_job_pid("\tactive count = 123\n"), None);
        assert_eq!(launchd_job_pid(""), None);
    }

    /// #667/#732：`kickstart -p` 的 stdout 就是新 pid（本机 2026-10-08 实测输出 `35736\n`）。
    /// 读不出必须是 `None`（调用方再用 `print` 兜），不许编一个 0。
    #[cfg(target_os = "macos")]
    #[test]
    fn kickstart_reported_pid_reads_the_bare_pid_line() {
        use macos::kickstart_reported_pid;
        assert_eq!(kickstart_reported_pid("35736\n"), Some(35736));
        assert_eq!(kickstart_reported_pid(""), None);
        assert_eq!(kickstart_reported_pid("service already running\n"), None);
    }

    /// #667/#732：非 macOS 平台（Windows Run key / headless）**什么都不做**，
    /// 调用方据此退回原来的一次性 spawn —— Windows 行为不许因本卡改变。
    #[cfg(not(target_os = "macos"))]
    #[test]
    fn resident_restart_is_a_no_op_off_macos() {
        assert_eq!(
            adapter().restart_resident_daemon(true).unwrap(),
            ResidentRestart::Unsupported
        );
        assert_eq!(adapter().resident_daemon_pid(), None);
    }

    /// 【DESK-42 #604】闸门判据：只放行稳定安装位置。
    /// 外部评审在 PR #611 上拦下的正是「不判位置就静默改写登记」——这些一次性路径
    /// 必须一条都不许过。
    #[cfg(target_os = "macos")]
    #[test]
    fn gate_allows_only_stable_install_locations() {
        use macos::is_stable_install_location as allowed;
        let p = |s: &str| std::path::PathBuf::from(s);

        // 稳定：系统级 / 用户级安装
        assert!(allowed(&p(
            "/Applications/P-Pass.app/Contents/MacOS/ppf-daemon"
        )));
        assert!(allowed(&p(&format!(
            "{}/Applications/P-Pass.app/Contents/MacOS/ppf-daemon",
            std::env::var("HOME").unwrap_or_default()
        ))));

        // 一次性 / 不稳定：一条都不许过（每行都是真机上真实存在的形态）
        assert!(
            !allowed(&p("/Volumes/P-Pass/P-Pass.app/Contents/MacOS/ppf-daemon")),
            "dmg 挂载点"
        );
        assert!(
            !allowed(&p(&format!(
                "{}/Downloads/P-Pass.app/Contents/MacOS/ppf-daemon",
                std::env::var("HOME").unwrap_or_default()
            ))),
            "「下载」目录直接点开"
        );
        assert!(
            !allowed(&p("/private/var/folders/xy/abc/T/AppTranslocation/1234-5678/d/P-Pass.app/Contents/MacOS/ppf-daemon")),
            "App Translocation 随机路径"
        );
        assert!(
            !allowed(&p("/Users/lizhaowen/P-Pass-Backups/2026-09-30-before-0.6.2/old-app/P-Pass.app/Contents/MacOS/ppf-daemon")),
            "备份副本（本卡的原始现场）"
        );
        assert!(
            !allowed(&p("/Users/x/workspace/P-Pass/target/debug/ppf-daemon")),
            "开发构建路径"
        );
    }

    /// 【DESK-42 #604】闸门必须**先于**读登记生效：不稳定位置上，对账直接返回
    /// `SkippedUnstableLocation`，既不改也不读。
    /// 反证：把闸门去掉（恒真），这条会变成 NotRegistered/Unchanged/Rewritten → 断言失败。
    #[cfg(target_os = "macos")]
    #[test]
    fn gate_precedes_registration_read_and_write() {
        let adapter = macos::MacosAdapter::new();
        let dmg = std::path::Path::new("/Volumes/P-Pass/P-Pass.app/Contents/MacOS/ppf-daemon");
        assert_eq!(
            adapter.reconcile_autostart(dmg).expect("reconcile"),
            AutostartReconcile::SkippedUnstableLocation,
            "从 dmg 挂载点启动时绝不许改写开机自启登记"
        );
    }
}
