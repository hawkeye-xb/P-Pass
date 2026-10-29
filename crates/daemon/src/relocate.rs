//! #639：更改照片库位置 = 整库搬迁。手机不重扫码、不重传，原目录搬空。
//!
//! #1260 之后服务自己的数据（索引、身份、blob 元数据、缩略图）都在本机、按库 ID 存放，所以搬迁
//! 只需要搬库盘上的东西（`originals/`、`.ppf/` 库标记与 blob 数据、用户自己放进库目录的文件）、
//! 再改指向：库 ID 随 `.ppf/library-id` 一起走，本机数据原样接上——NodeId 不变（不重扫码），
//! 索引里存的是库内相对路径（不重传）。
//!
//! 目标就是用户选的那个文件夹（与首次设置同一条规则：已存在就直接写进去，不存在就建出来）。里面原有的东西我们
//! 一个都不碰：库的顶层条目与它们重名就拒绝（不让复制工具覆盖），失败时只清我们自己拷进去的。
//!
//! 复制交给各平台自带的工具（[`platform::copy_dir_contents`]：ditto / robocopy / cp -a），
//! P-Pass 只做编排：
//! 1. 预检（[`check`]）：别的库 / 嵌套 / 网络盘 / 重名 / 跨卷空间；
//! 2. 服务退出重启、以「正在搬迁」状态接着搬（窗口锁住，只显示进度；服务对手机与窗口的写一律拒绝）；
//! 3. 给源目录拍快照（文件、大小、修改时间、链接）；
//! 4. 同一个卷：逐个顶层条目改名过去；跨卷：用系统工具拷到目标里的临时目录，核对后改名到位；
//! 5. 用我们自己的清单核对（与快照一致），并与索引对账（索引里的每张照片在新位置都在）；
//! 6. 切换指向前最后核一次源目录：与快照有出入（用户在 Finder 里改了库）就放弃——原库不动，
//!    新位置里我们放进去的全部撤回，告诉用户「搬迁期间照片库被改动，已取消，请稍后重试」；
//! 7. 改指向 → 删原目录（只在核对通过、指向已改之后）。
//!
//! 每个最终状态只有两种：成功（新位置有全部数据、指向已改、原目录删除），或失败（指向不变、原库
//! 完整，新位置里没有我们留下的东西）。中途断电：计划还在，下次启动重来；「指向已改、原目录还没删」
//! 时中断，下次启动只补删原目录。

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use serde::{Deserialize, Serialize};

use crate::config::ui_err;
use crate::layout;

/// 本机 `libraries/` 下的搬迁计划文件。
pub const PLAN_FILE: &str = "relocation.json";

/// 跨卷复制时，目标文件夹里我们专用的临时目录（核对通过后里面的东西才改名到位）。
pub const STAGING_DIR: &str = ".p-pass-moving";

/// 一次搬迁的计划（落盘，跨重启）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Plan {
    /// 原库目录。
    pub from: PathBuf,
    /// 新库目录（就是用户选的文件夹）。
    pub to: PathBuf,
    /// 库 ID（搬前搬后不变）。
    pub id: String,
    /// 指向已经改到新位置（只差删原目录）。
    #[serde(default)]
    pub flipped: bool,
    /// 跨卷：核对已通过，正在把临时目录里的东西改名到位（这时被打断，目标里与库同名的条目都是我们
    /// 放的，重启后先清掉再从头来）。
    #[serde(default)]
    pub promoting: bool,
}

fn plan_path(local_base: &Path) -> PathBuf {
    local_base.join(layout::LIBRARIES_DIR).join(PLAN_FILE)
}

/// 未完成的搬迁计划。
pub fn pending(local_base: &Path) -> Option<Plan> {
    let text = std::fs::read_to_string(plan_path(local_base)).ok()?;
    serde_json::from_str(&text).ok()
}

fn save(local_base: &Path, plan: &Plan) -> Result<(), String> {
    let text = serde_json::to_vec_pretty(plan).map_err(|e| e.to_string())?;
    layout::write_atomically(&plan_path(local_base), &text).map_err(|e| e.to_string())
}

/// 搬完：清掉计划。
pub fn clear(local_base: &Path) {
    let _ = std::fs::remove_file(plan_path(local_base));
}

/// 上一次搬迁失败的原因（keyed `ui_err`），窗口在 `status.relocate_error` 里读到；下次搬迁清掉。
pub const ERROR_FILE: &str = "relocation-error";

pub fn last_error(local_base: &Path) -> Option<String> {
    std::fs::read_to_string(local_base.join(layout::LIBRARIES_DIR).join(ERROR_FILE)).ok()
}

pub fn record_error(local_base: &Path, error: &str) {
    let _ = layout::write_atomically(
        &local_base.join(layout::LIBRARIES_DIR).join(ERROR_FILE),
        error.as_bytes(),
    );
}

pub fn clear_error(local_base: &Path) {
    let _ = std::fs::remove_file(local_base.join(layout::LIBRARIES_DIR).join(ERROR_FILE));
}

/// 搬迁没成（新位置里我们放进去的已由 [`move_library`] / [`Moved::undo`] 撤回）：记下原因、清掉计划，
/// 下次启动照旧在原位置。
pub fn abandon(local_base: &Path, error: &str) {
    record_error(local_base, error);
    clear(local_base);
}

/// 预检要问系统的几件事（生产用平台实现，测试注入）。
pub struct Probes<'a> {
    /// 两个已存在的路径在不在同一个卷上；`None` = 读不出来，按跨卷算（要查空间）。
    pub same_volume: &'a dyn Fn(&Path, &Path) -> Option<bool>,
    /// 卷上的可用字节；`None` = 读不出来，不拦（复制时盘满照样会失败、放弃、原库不动）。
    pub free_bytes: &'a dyn Fn(&Path) -> Option<u64>,
    /// 是不是网络盘。
    pub network: &'a dyn Fn(&Path) -> bool,
}

fn platform_free(p: &Path) -> Option<u64> {
    use platform::PlatformAdapter as _;
    platform::adapter().volume_stats(p).map(|v| v.free)
}

fn platform_probes() -> Probes<'static> {
    Probes {
        same_volume: &platform::same_volume,
        free_bytes: &platform_free,
        network: &platform::is_network_volume,
    }
}

/// 预检结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Check {
    pub plan: Plan,
    /// 选的文件夹里已有别的东西（照片会和它们放在一起）——窗口确认前要额外提示。
    pub non_empty: bool,
    /// 选的就是这个库（用户自己搬过去了）：只改指向。
    pub adopt: bool,
}

/// 预检（不落盘）：窗口在确认框之前调，确认后再调 [`plan`]。错误是 keyed `ui_err`。
///
/// - 目标就是 `chosen`（方案 B，与首次设置一致）；不存在就由 [`plan`] 建出来；
/// - `chosen` 里已经是这个库（库 ID 相同）⇒ 只改指向；
/// - 网络盘（SMB / NFS 等）不放：推出审批与根目录监听在网络盘上不可靠；
/// - 新旧位置不能互相嵌套；`chosen` 不能是别的库、也不能在别的库里面；
/// - 库的顶层条目与 `chosen` 里原有的东西重名 ⇒ 拒绝（不合并、不覆盖用户的东西）；
/// - 跨卷时新位置要放得下整个库（多留 2%），不够直接拒绝并说明缺多少。
pub fn check(from: &Path, chosen: &Path, local_base: &Path) -> Result<Check, String> {
    check_with(from, chosen, local_base, &platform_probes())
}

/// [`check`] 的可测版本。
pub fn check_with(
    from: &Path,
    chosen: &Path,
    local_base: &Path,
    probes: &Probes,
) -> Result<Check, String> {
    let id = layout::read_library_id(from)
        .or_else(|| layout::recorded_library_id(local_base))
        .ok_or_else(|| ui_err("ui.err_relocate_no_library_id", &[]))?;
    // 选的文件夹不存在就由 [`plan`] 建出来（与首次设置一致）；还没建时，卷相关的探测问它最近的
    // 已存在的上级目录。
    if chosen.exists() && !chosen.is_dir() {
        return Err(ui_err(
            "ui.err_library_target_missing",
            &[("dir", &chosen.display())],
        ));
    }
    let (to_c, probe_at) = resolve(chosen);
    if (probes.network)(&probe_at) {
        return Err(ui_err("ui.err_relocate_network_volume", &[]));
    }
    let adopt = layout::read_library_id(chosen).as_deref() == Some(id.as_str());
    let from_c = canonical(from);
    if from_c == to_c || to_c.starts_with(&from_c) || from_c.starts_with(&to_c) {
        return Err(ui_err("ui.err_library_nested", &[]));
    }
    // 别的库：选的位置本身是别的库，或者在某个库里面（「这个库」自己除外：它就是 adopt）。
    for dir in to_c.ancestors() {
        if adopt && dir == to_c {
            continue;
        }
        if layout::read_library_id(dir).is_some() {
            return Err(ui_err(
                "ui.err_relocate_other_library",
                &[("dir", &dir.display())],
            ));
        }
    }
    let plan = Plan {
        from: from.to_path_buf(),
        to: chosen.to_path_buf(),
        id,
        flipped: false,
        promoting: false,
    };
    if adopt {
        return Ok(Check {
            plan,
            non_empty: false,
            adopt: true,
        });
    }
    if !crate::library_location::library_marker_present(from) {
        // 原库找不到时只能指向它现在所在的文件夹（adopt），不能「搬」一个不在的库。
        return Err(ui_err("ui.err_relocate_source_missing", &[]));
    }
    if let Some(name) = first_conflict(from, chosen).map_err(io_ui_err)? {
        return Err(ui_err(
            "ui.err_relocate_conflict",
            &[("name", &name.to_string_lossy())],
        ));
    }
    if (probes.same_volume)(from, &probe_at) != Some(true) {
        let need = Manifest::scan(from).map_err(io_ui_err)?.bytes();
        let need = need.saturating_add(need / 50);
        if let Some(free) = (probes.free_bytes)(&probe_at) {
            if free < need {
                return Err(ui_err(
                    "ui.err_relocate_no_space",
                    &[
                        ("need", &human_bytes(need)),
                        ("free", &human_bytes(free)),
                        ("short", &human_bytes(need - free)),
                    ],
                ));
            }
        }
    }
    let non_empty = chosen.exists()
        && std::fs::read_dir(chosen)
            .map_err(io_ui_err)?
            .flatten()
            .any(|e| !ignorable(&e.file_name()));
    Ok(Check {
        plan,
        non_empty,
        adopt: false,
    })
}

/// 预检通过就把计划落盘（服务随后退出重启去搬）。
pub fn plan(from: &Path, chosen: &Path, local_base: &Path) -> Result<Check, String> {
    let check = check(from, chosen, local_base)?;
    std::fs::create_dir_all(chosen).map_err(io_ui_err)?;
    save(local_base, &check.plan)?;
    clear_error(local_base);
    Ok(check)
}

fn io_ui_err(e: std::io::Error) -> String {
    ui_err("ui.err_set_library", &[("err", &e)])
}

/// 库的第一个与 `chosen` 里原有东西重名的顶层条目。
fn first_conflict(from: &Path, chosen: &Path) -> std::io::Result<Option<OsString>> {
    for entry in std::fs::read_dir(from)? {
        let name = entry?.file_name();
        if ignorable(&name) {
            continue;
        }
        if std::fs::symlink_metadata(chosen.join(&name)).is_ok() {
            return Ok(Some(name));
        }
    }
    Ok(None)
}

/// 不算「用户的东西」的系统附属文件：Finder 的 `.DS_Store`、AppleDouble（`._<名>`，macOS 往 exFAT /
/// FAT 写带扩展属性的文件时另生成的属性文件）。
fn ignorable(name: &std::ffi::OsStr) -> bool {
    let n = name.to_string_lossy();
    n == ".DS_Store" || n.starts_with("._")
}

/// 给人看的字节数（1000 进制，与 Finder 一致）。
fn human_bytes(n: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = n as f64;
    let mut u = 0;
    while v >= 1000.0 && u < UNITS.len() - 1 {
        v /= 1000.0;
        u += 1;
    }
    if u == 0 {
        format!("{n} B")
    } else {
        format!("{v:.1} {}", UNITS[u])
    }
}

fn canonical(p: &Path) -> PathBuf {
    p.canonicalize().unwrap_or_else(|_| p.to_path_buf())
}

/// 可能还不存在的路径：（规范化后的完整路径，最近的已存在的上级目录——卷相关的探测问它）。
fn resolve(p: &Path) -> (PathBuf, PathBuf) {
    let mut existing = p;
    let mut rest = Vec::new();
    while !existing.exists() {
        match (existing.parent(), existing.file_name()) {
            (Some(parent), Some(name)) => {
                rest.push(name.to_os_string());
                existing = parent;
            }
            _ => break,
        }
    }
    let base = canonical(existing);
    let full = rest.iter().rev().fold(base.clone(), |acc, n| acc.join(n));
    (full, base)
}

/// 指向是否已经改到新位置（`current` = 服务这次启动读到的库位置）。改完指向、还没记下「已改指向」
/// 就中断时，计划里 `flipped` 还是假，但位置已经是新的——只差删原目录，不能再搬一次。
pub fn already_repointed(plan: &Plan, current: &Path) -> bool {
    plan.flipped || canonical(current) == canonical(&plan.to)
}

/// 一个目录的清单：相对路径 → 条目（文件的大小与修改时间、链接的指向、目录）。系统附属文件不计。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Manifest(BTreeMap<PathBuf, Entry>);

#[derive(Debug, Clone, PartialEq, Eq)]
enum Entry {
    Dir,
    File {
        len: u64,
        modified: Option<SystemTime>,
    },
    /// 指向 + 指向文件的大小（指向不存在或是目录时为 None）。
    Link {
        target: PathBuf,
        len: Option<u64>,
    },
}

fn link_entry(path: &Path) -> std::io::Result<Entry> {
    let len = std::fs::metadata(path)
        .ok()
        .filter(|m| m.is_file())
        .map(|m| m.len());
    Ok(Entry::Link {
        target: std::fs::read_link(path)?,
        len,
    })
}

impl Manifest {
    pub fn scan(root: &Path) -> std::io::Result<Self> {
        let mut m = BTreeMap::new();
        scan_into(root, Path::new(""), &mut m)?;
        Ok(Self(m))
    }

    fn bytes(&self) -> u64 {
        self.0
            .values()
            .map(|e| match e {
                Entry::File { len, .. } => *len,
                _ => 0,
            })
            .sum()
    }

    /// 内容一致（类型、大小、链接指向）——拷贝后的核对。修改时间不比：exFAT 只有 2 秒精度。
    /// Windows 上普通用户与服务账户没有建符号链接的特权，robocopy 的 `/SL` 不生效、把文件链接
    /// 拷成指向文件的内容：目标是同样大小的普通文件也算一致。
    fn same_content(&self, other: &Self) -> bool {
        self.0.len() == other.0.len()
            && self.0.iter().all(|(k, a)| match (a, other.0.get(k)) {
                (Entry::Dir, Some(Entry::Dir)) => true,
                (Entry::File { len: x, .. }, Some(Entry::File { len: y, .. })) => x == y,
                (Entry::Link { target: x, .. }, Some(Entry::Link { target: y, .. })) => x == y,
                (Entry::Link { len: Some(x), .. }, Some(Entry::File { len: y, .. })) => {
                    cfg!(windows) && x == y
                }
                _ => false,
            })
    }
}

fn scan_into(dir: &Path, rel: &Path, out: &mut BTreeMap<PathBuf, Entry>) -> std::io::Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name();
        if ignorable(&name) {
            continue;
        }
        let path = entry.path();
        let r = rel.join(&name);
        let kind = entry.file_type()?;
        if kind.is_symlink() {
            out.insert(r, link_entry(&path)?);
        } else if kind.is_dir() {
            out.insert(r.clone(), Entry::Dir);
            scan_into(&path, &r, out)?;
        } else if kind.is_file() {
            let meta = entry.metadata()?;
            out.insert(
                r,
                Entry::File {
                    len: meta.len(),
                    modified: meta.modified().ok(),
                },
            );
        }
    }
    Ok(())
}

/// 正在进行的一次搬迁（进度给窗口看）。
pub struct Live {
    pub plan: Plan,
    done: std::sync::atomic::AtomicU64,
    total: std::sync::atomic::AtomicU64,
}

impl Live {
    pub fn new(plan: Plan) -> Self {
        Self {
            plan,
            done: Default::default(),
            total: Default::default(),
        }
    }

    /// 已搬 / 总量（字节）；同卷改名时都是 0。
    pub fn progress(&self) -> (u64, u64) {
        use std::sync::atomic::Ordering::Relaxed;
        (self.done.load(Relaxed), self.total.load(Relaxed))
    }
}

impl Progress for Live {
    fn set(&self, done: u64, total: u64) {
        use std::sync::atomic::Ordering::Relaxed;
        self.done.store(done, Relaxed);
        self.total.store(total, Relaxed);
    }
}

/// 搬迁进度（字节）。
pub trait Progress: Send + Sync {
    fn set(&self, done: u64, total: u64);
}

impl<F: Fn(u64, u64) + Send + Sync> Progress for F {
    fn set(&self, done: u64, total: u64) {
        self(done, total)
    }
}

/// 搬迁过程中可插入动作的时刻（只给测试用：模拟用户在 Finder 里改库）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    /// 拍完快照、开始搬之前。
    Snapshotted,
    /// 搬 / 拷完、核对之前。
    Moved,
}

/// [`move_library`] 依赖的外部动作（生产用平台实现，测试注入）。
pub struct Deps<'a> {
    pub same_volume: &'a dyn Fn(&Path, &Path) -> Option<bool>,
    pub copy: &'a dyn Fn(&Path, &Path) -> std::io::Result<()>,
    /// 跨卷核对通过、开始改名到位之前：把「正在改名到位」落进计划。
    pub promote: &'a dyn Fn() -> Result<(), String>,
    pub at: &'a dyn Fn(Stage),
}

/// 搬过去之后、改指向之前的结果——改指向失败时用它撤回。
#[derive(Debug)]
pub struct Moved {
    /// 顶层条目（相对库根的名字）。
    names: Vec<OsString>,
    /// 同卷改名（撤回 = 改名回去）；跨卷复制（撤回 = 删掉新位置里我们放的）。
    renamed: bool,
}

impl Moved {
    /// 撤回：新位置里我们放进去的全部拿走，原库完整（同卷改名回去；跨卷原库本来就没动）。
    pub fn undo(&self, plan: &Plan) {
        undo_names(plan, &self.names, self.renamed);
    }
}

fn undo_names(plan: &Plan, names: &[OsString], renamed: bool) {
    for name in names {
        let at = plan.to.join(name);
        if renamed {
            let _ = std::fs::rename(&at, plan.from.join(name));
        } else if let Ok(meta) = std::fs::symlink_metadata(&at) {
            if meta.is_dir() {
                let _ = std::fs::remove_dir_all(&at);
            } else {
                let _ = std::fs::remove_file(&at);
            }
        }
    }
}

/// 把库搬到 `plan.to`（不改指向、不删原目录——那两步由 [`complete`] 在核对通过后做）。
/// `indexed` 给出索引里每张照片的库内相对路径（对账用）。
pub fn move_library(
    local_base: &Path,
    plan: &Plan,
    progress: &dyn Progress,
    indexed: &dyn Fn() -> Result<Vec<String>, String>,
) -> Result<Moved, String> {
    let promote = || {
        let mut p = plan.clone();
        p.promoting = true;
        save(local_base, &p)
    };
    move_library_with(
        plan,
        progress,
        indexed,
        &Deps {
            same_volume: &platform::same_volume,
            copy: &platform::copy_dir_contents,
            promote: &promote,
            at: &|_| {},
        },
    )
}

/// [`move_library`] 的可测版本。
pub fn move_library_with(
    plan: &Plan,
    progress: &dyn Progress,
    indexed: &dyn Fn() -> Result<Vec<String>, String>,
    deps: &Deps,
) -> Result<Moved, String> {
    // 上次跨卷改名到位到一半被打断：原库完整，目标里与库同名的条目都是我们放的（计划落盘时核过没有
    // 重名）——清掉、连同临时目录，从头再来。
    if plan.promoting {
        let ours: Vec<OsString> = std::fs::read_dir(&plan.from)
            .map_err(io_ui_err)?
            .flatten()
            .map(|e| e.file_name())
            .filter(|n| !ignorable(n))
            .collect();
        undo_names(plan, &ours, false);
        let _ = std::fs::remove_dir_all(plan.to.join(STAGING_DIR));
    }
    // 已经整个在新位置（用户自己搬过去了，或上次搬完还没来得及改指向）：只改指向。原目录里还剩
    // 东西（上次同卷逐个改名到一半被打断）就接着把剩下的搬过去，绝不当成「搬完了」去删原目录。
    let leftover = |dir: &Path| {
        std::fs::read_dir(dir)
            .map(|d| d.flatten().any(|e| !ignorable(&e.file_name())))
            .unwrap_or(false)
    };
    if layout::read_library_id(&plan.to).as_deref() == Some(plan.id.as_str())
        && !leftover(&plan.from)
    {
        return Ok(Moved {
            names: Vec::new(),
            renamed: true,
        });
    }
    let changed = || ui_err("ui.err_relocate_changed", &[]);
    let snapshot = Manifest::scan(&plan.from).map_err(io_ui_err)?;
    let names: Vec<OsString> = std::fs::read_dir(&plan.from)
        .map_err(io_ui_err)?
        .flatten()
        .map(|e| e.file_name())
        .filter(|n| !ignorable(n))
        .collect();
    // 预检之后到现在，目标里可能又多了重名的东西。
    if let Some(name) = first_conflict(&plan.from, &plan.to).map_err(io_ui_err)? {
        return Err(ui_err(
            "ui.err_relocate_conflict",
            &[("name", &name.to_string_lossy())],
        ));
    }
    (deps.at)(Stage::Snapshotted);

    let renamed = (deps.same_volume)(&plan.from, &plan.to) == Some(true);
    let moved = Moved {
        names: names.clone(),
        renamed,
    };
    if renamed {
        // 同一个卷：逐个顶层条目改名过去（每一次改名都是原子的）。
        let mut done: Vec<OsString> = Vec::new();
        for name in &names {
            if let Err(e) = std::fs::rename(plan.from.join(name), plan.to.join(name)) {
                undo_names(plan, &done, true);
                // 快照里有、现在没了 = 有人在改库。
                if e.kind() == std::io::ErrorKind::NotFound {
                    return Err(changed());
                }
                return Err(ui_err("ui.err_relocate_copy_failed", &[("err", &e)]));
            }
            done.push(name.clone());
        }
        (deps.at)(Stage::Moved);
        // 改名期间源目录又冒出东西、或搬过去的与快照不一致 ⇒ 有人在改库：改名回去、放弃。
        if leftover(&plan.from) || subset(&plan.to, &names).map_err(io_ui_err)? != snapshot {
            moved.undo(plan);
            return Err(changed());
        }
    } else {
        // 跨卷：系统工具拷到目标里的临时目录 → 核对 → 源目录没被改 → 改名到位。
        let staging = plan.to.join(STAGING_DIR);
        let _ = std::fs::remove_dir_all(&staging);
        let total = snapshot.bytes();
        progress.set(0, total);
        let copied = with_progress(&staging, total, progress, || {
            (deps.copy)(&plan.from, &staging)
        });
        let cleanup = || {
            let _ = std::fs::remove_dir_all(&staging);
        };
        if let Err(e) = copied {
            cleanup();
            return Err(ui_err("ui.err_relocate_copy_failed", &[("err", &e)]));
        }
        (deps.at)(Stage::Moved);
        let got = Manifest::scan(&staging).map_err(io_ui_err)?;
        let source_changed = || {
            Manifest::scan(&plan.from)
                .map(|m| m != snapshot)
                .unwrap_or(true)
        };
        if !got.same_content(&snapshot) {
            cleanup();
            // 拷贝与快照对不上：多半是拍完快照后用户改了库（拷进来的是改过的样子）。
            if source_changed() {
                return Err(changed());
            }
            return Err(ui_err("ui.err_relocate_verify_failed", &[]));
        }
        if source_changed() {
            cleanup();
            return Err(changed());
        }
        if let Err(e) = (deps.promote)() {
            cleanup();
            return Err(e);
        }
        let mut up: Vec<OsString> = Vec::new();
        for name in &names {
            if let Err(e) = std::fs::rename(staging.join(name), plan.to.join(name)) {
                undo_names(plan, &up, false);
                cleanup();
                return Err(ui_err("ui.err_relocate_copy_failed", &[("err", &e)]));
            }
            up.push(name.clone());
        }
        cleanup();
        progress.set(total, total);
    }

    // 与索引对账：索引里、且搬之前在原库里的每张照片，在新位置都在。（原库里本来就没有的——服务
    // 停着时用户在 Finder 里删的——由 reconcile 处理，不是搬迁的事。）
    let rels = match indexed() {
        Ok(r) => r,
        Err(e) => {
            moved.undo(plan);
            return Err(ui_err("ui.err_relocate_copy_failed", &[("err", &e)]));
        }
    };
    if rels
        .iter()
        .any(|r| snapshot.0.contains_key(Path::new(r)) && !plan.to.join(r).exists())
    {
        moved.undo(plan);
        return Err(ui_err("ui.err_relocate_verify_failed", &[]));
    }
    // 切换指向前最后核一次：跨卷时源目录还在，与快照有出入就放弃。
    if !renamed && Manifest::scan(&plan.from).map_err(io_ui_err)? != snapshot {
        moved.undo(plan);
        return Err(changed());
    }
    Ok(moved)
}

/// `root` 里只看 `names` 这些顶层条目的清单（目标文件夹里用户原有的东西不算）。
fn subset(root: &Path, names: &[OsString]) -> std::io::Result<Manifest> {
    let mut m = BTreeMap::new();
    for name in names {
        let path = root.join(name);
        let rel = PathBuf::from(name);
        let meta = std::fs::symlink_metadata(&path)?;
        if meta.file_type().is_symlink() {
            m.insert(rel, link_entry(&path)?);
        } else if meta.is_dir() {
            m.insert(rel.clone(), Entry::Dir);
            scan_into(&path, &rel, &mut m)?;
        } else {
            m.insert(
                rel,
                Entry::File {
                    len: meta.len(),
                    modified: meta.modified().ok(),
                },
            );
        }
    }
    Ok(Manifest(m))
}

/// 跑复制工具，同时每半秒量一次临时目录的大小当进度（系统工具不报进度）。
fn with_progress(
    staging: &Path,
    total: u64,
    progress: &dyn Progress,
    copy: impl FnOnce() -> std::io::Result<()>,
) -> std::io::Result<()> {
    let stop = std::sync::atomic::AtomicBool::new(false);
    std::thread::scope(|s| {
        s.spawn(|| {
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                if let Ok(m) = Manifest::scan(staging) {
                    progress.set(m.bytes().min(total), total);
                }
                std::thread::sleep(std::time::Duration::from_millis(500));
            }
        });
        let r = copy();
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        r
    })
}

/// 改指向之后：删原目录（只在新位置确实是这个库时）。
pub fn remove_source(plan: &Plan) -> Result<(), String> {
    if layout::read_library_id(&plan.to).as_deref() != Some(plan.id.as_str()) {
        return Err("新位置上不是这个库，不删原目录".into());
    }
    match std::fs::remove_dir_all(&plan.from) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(format!("删原目录失败：{e}")),
    }
}

/// 搬完之后的收尾：改指向（`set_location`）→ 记「已改指向」→ 删原目录 → 清计划与旧的失败记录。
/// 改指向失败就返回错误（原库与计划都还在，调用方撤回 [`Moved`] 并放弃计划）。
pub fn complete(
    local_base: &Path,
    plan: &Plan,
    set_location: impl FnOnce(&Path) -> Result<(), String>,
) -> Result<(), String> {
    set_location(&plan.to)?;
    mark_flipped(local_base, plan)?;
    finish_flipped(local_base, plan);
    clear_error(local_base);
    Ok(())
}

/// 指向已经改好（可能是上次改完就崩溃了）：删原目录、清计划。删不掉只记日志，原目录留给用户。
pub fn finish_flipped(local_base: &Path, plan: &Plan) {
    if let Err(e) = remove_source(plan) {
        tracing::warn!(
            "#639: 原照片库目录没删掉（{e}），请手动处理：{}",
            plan.from.display()
        );
    }
    clear(local_base);
}

/// 记下「指向已改」（只差删原目录），重启后不再重复搬。
pub fn mark_flipped(local_base: &Path, plan: &Plan) -> Result<(), String> {
    let mut p = plan.clone();
    p.flipped = true;
    save(local_base, &p)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library_location::LIBRARY_MARKER;

    fn library(parent: &Path, name: &str) -> (PathBuf, String) {
        let lib = parent.join(name);
        std::fs::create_dir_all(lib.join("originals/aa/2026/09")).unwrap();
        std::fs::create_dir_all(lib.join(LIBRARY_MARKER)).unwrap();
        std::fs::write(lib.join("originals/aa/2026/09/a.jpg"), b"photo-a").unwrap();
        std::fs::write(lib.join("notes.txt"), b"user file").unwrap();
        let id = layout::ensure_library_id(&lib).unwrap();
        (lib, id)
    }

    fn no_progress() -> impl Progress {
        |_: u64, _: u64| {}
    }

    fn indexed_ok() -> Result<Vec<String>, String> {
        Ok(vec!["originals/aa/2026/09/a.jpg".into()])
    }

    fn deps<'a>(same: &'a dyn Fn(&Path, &Path) -> Option<bool>, at: &'a dyn Fn(Stage)) -> Deps<'a> {
        Deps {
            same_volume: same,
            copy: &platform::copy_dir_contents,
            promote: &|| Ok(()),
            at,
        }
    }

    fn probes<'a>(
        same: &'a dyn Fn(&Path, &Path) -> Option<bool>,
        free: &'a dyn Fn(&Path) -> Option<u64>,
        network: &'a dyn Fn(&Path) -> bool,
    ) -> Probes<'a> {
        Probes {
            same_volume: same,
            free_bytes: free,
            network,
        }
    }

    /// 目标文件夹里用户原有的东西。
    fn user_dest(parent: &Path) -> PathBuf {
        let dest = parent.join("Disk");
        std::fs::create_dir_all(&dest).unwrap();
        std::fs::write(dest.join("mine.txt"), b"keep me").unwrap();
        dest
    }

    fn library_entries_at(dir: &Path) -> bool {
        dir.join("originals").exists()
            || dir.join(LIBRARY_MARKER).exists()
            || dir.join("notes.txt").exists()
    }

    // 方案 B：目标就是选的文件夹；里面已有用户的东西 ⇒ 预检报 non_empty（窗口额外提示），不拒绝。
    #[test]
    fn the_target_is_the_chosen_folder_and_existing_files_are_flagged() {
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (from, _) = library(home.path(), "Lib");
        let dest = user_dest(home.path());
        let c = check(&from, &dest, local.path()).unwrap();
        assert_eq!(c.plan.to, dest);
        assert!(c.non_empty);
        let empty = home.path().join("Empty");
        std::fs::create_dir_all(&empty).unwrap();
        std::fs::write(empty.join(".DS_Store"), b"x").unwrap();
        assert!(
            !check(&from, &empty, local.path()).unwrap().non_empty,
            ".DS_Store 不算用户的东西"
        );
        assert_eq!(pending(local.path()), None, "预检不落计划");
    }

    // 同卷：顶层条目改名过去，目标里用户原有的文件不动；改完指向后原目录删掉。
    #[test]
    fn a_same_volume_move_keeps_what_was_already_in_the_target() {
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (from, id) = library(home.path(), "Lib");
        let dest = user_dest(home.path());
        let c = plan(&from, &dest, local.path()).unwrap();
        let same = |_: &Path, _: &Path| Some(true);
        move_library_with(&c.plan, &no_progress(), &indexed_ok, &deps(&same, &|_| {})).unwrap();
        complete(local.path(), &c.plan, |_| Ok(())).unwrap();
        assert_eq!(layout::read_library_id(&dest), Some(id));
        assert!(dest.join("originals/aa/2026/09/a.jpg").is_file());
        assert!(
            dest.join("notes.txt").is_file(),
            "库里用户自己的文件一起过来"
        );
        assert_eq!(
            std::fs::read(dest.join("mine.txt")).unwrap(),
            b"keep me",
            "目标原有的不动"
        );
        assert!(!from.exists(), "原目录删掉");
        assert_eq!(pending(local.path()), None);
    }

    // 跨卷：系统工具（本机 ditto / cp -a）拷到临时目录、核对、改名到位；链接照搬；临时目录不留。
    #[test]
    fn a_cross_volume_copy_uses_the_system_tool_and_preserves_links() {
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (from, id) = library(home.path(), "Lib");
        let outside = home.path().join("outside.jpg");
        std::fs::write(&outside, b"outside").unwrap();
        let linked = platform::test_support::file_symlink(&outside, &from.join("link.jpg")).is_ok();
        let dest = user_dest(home.path());
        let c = plan(&from, &dest, local.path()).unwrap();
        let cross = |_: &Path, _: &Path| Some(false);
        let moved = move_library_with(&c.plan, &no_progress(), &indexed_ok, &deps(&cross, &|_| {}))
            .unwrap();
        assert!(!moved.renamed);
        assert!(!dest.join(STAGING_DIR).exists(), "临时目录不留");
        assert!(
            from.join("originals/aa/2026/09/a.jpg").is_file(),
            "改指向前原库不动"
        );
        complete(local.path(), &c.plan, |_| Ok(())).unwrap();
        assert_eq!(layout::read_library_id(&dest), Some(id));
        assert!(dest.join("originals/aa/2026/09/a.jpg").is_file());
        assert!(dest.join("mine.txt").is_file());
        if linked {
            let l = dest.join("link.jpg");
            if std::fs::symlink_metadata(&l)
                .unwrap()
                .file_type()
                .is_symlink()
            {
                assert_eq!(std::fs::read_link(&l).unwrap(), outside, "链接照搬");
            } else {
                // Windows 无建链接特权：robocopy 拷成指向文件的内容。
                assert_eq!(
                    std::env::consts::OS,
                    "windows",
                    "只有 Windows 无特权时才会拷成普通文件"
                );
                assert_eq!(std::fs::read(&l).unwrap(), b"outside");
            }
        }
        assert!(!from.exists());
    }

    /// 搬迁中途在 Finder 里改库（加 / 删 / 改文件）：同卷与跨卷都要安全放弃——原库完整（含用户的改动），
    /// 目标里没有我们留下的东西，用户原有的不动。
    fn finder_edit_aborts(same_volume: bool, at_stage: Stage, edit: &dyn Fn(&Path)) {
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (from, _) = library(home.path(), "Lib");
        let dest = user_dest(home.path());
        let c = plan(&from, &dest, local.path()).unwrap();
        let same = move |_: &Path, _: &Path| Some(same_volume);
        let src = from.clone();
        let at = move |s: Stage| {
            if s == at_stage {
                edit(&src);
            }
        };
        let err =
            move_library_with(&c.plan, &no_progress(), &indexed_ok, &deps(&same, &at)).unwrap_err();
        assert!(
            err.contains("ui.err_relocate_changed"),
            "{same_volume} {at_stage:?}: {err}"
        );
        assert!(!library_entries_at(&dest), "目标里没有我们留下的东西");
        assert!(!dest.join(STAGING_DIR).exists());
        assert_eq!(std::fs::read(dest.join("mine.txt")).unwrap(), b"keep me");
        assert!(
            from.join(LIBRARY_MARKER).join("library-id").is_file(),
            "原库完整"
        );
    }

    #[test]
    fn a_file_added_during_the_move_aborts_it() {
        let add = |src: &Path| std::fs::write(src.join("new.jpg"), b"new").unwrap();
        finder_edit_aborts(false, Stage::Snapshotted, &add);
        finder_edit_aborts(false, Stage::Moved, &add);
        finder_edit_aborts(true, Stage::Moved, &add);
    }

    #[test]
    fn a_file_deleted_during_the_move_aborts_it() {
        let del = |src: &Path| std::fs::remove_file(src.join("notes.txt")).unwrap();
        // 跨卷：拷完后用户在原库删了一个——新位置不能留着它当孤儿再去删原库。
        finder_edit_aborts(false, Stage::Moved, &del);
        // 跨卷：拍完快照、拷贝之前删——拷来的少一个，报的是「库被改动」而不是「核对不一致」。
        finder_edit_aborts(false, Stage::Snapshotted, &del);
        // 同卷：拍完快照、改名之前删——搬过去的与快照对不上。
        finder_edit_aborts(true, Stage::Snapshotted, &del);
    }

    #[test]
    fn a_file_modified_during_the_move_aborts_it() {
        let modify = |src: &Path| {
            std::thread::sleep(std::time::Duration::from_millis(1100));
            std::fs::write(src.join("notes.txt"), b"user file, edited").unwrap();
        };
        finder_edit_aborts(false, Stage::Snapshotted, &modify);
        finder_edit_aborts(false, Stage::Moved, &modify);
        finder_edit_aborts(true, Stage::Snapshotted, &modify);
    }

    // 复制工具失败：原库不动，清掉拷了一半的临时目录，目标原有的不动。
    // 反证：失败时不清临时目录 ⇒ 断言红。
    #[test]
    fn a_failing_copy_tool_leaves_the_library_and_cleans_up() {
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (from, _) = library(home.path(), "Lib");
        let dest = user_dest(home.path());
        let c = plan(&from, &dest, local.path()).unwrap();
        let cross = |_: &Path, _: &Path| Some(false);
        let half = |_: &Path, to: &Path| -> std::io::Result<()> {
            std::fs::create_dir_all(to.join("originals")).unwrap();
            std::fs::write(to.join("originals/half.jpg"), b"ha").unwrap();
            Err(std::io::Error::other("disk full"))
        };
        let d = Deps {
            same_volume: &cross,
            copy: &half,
            promote: &|| Ok(()),
            at: &|_| {},
        };
        let err = move_library_with(&c.plan, &no_progress(), &indexed_ok, &d).unwrap_err();
        assert!(err.contains("ui.err_relocate_copy_failed"), "{err}");
        assert!(!dest.join(STAGING_DIR).exists(), "拷了一半的清掉");
        assert!(!library_entries_at(&dest));
        assert!(from.join("originals/aa/2026/09/a.jpg").is_file());
    }

    // 复制工具少拷了一张（索引里有）：核对不过 ⇒ 清掉、放弃，原库完整。
    #[test]
    fn a_copy_that_drops_a_photo_aborts() {
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (from, _) = library(home.path(), "Lib");
        let dest = user_dest(home.path());
        let c = plan(&from, &dest, local.path()).unwrap();
        let cross = |_: &Path, _: &Path| Some(false);
        let lossy = |src: &Path, to: &Path| -> std::io::Result<()> {
            platform::copy_dir_contents(src, to)?;
            std::fs::remove_file(to.join("originals/aa/2026/09/a.jpg"))
        };
        let d = Deps {
            same_volume: &cross,
            copy: &lossy,
            promote: &|| Ok(()),
            at: &|_| {},
        };
        let err = move_library_with(&c.plan, &no_progress(), &indexed_ok, &d).unwrap_err();
        assert!(err.contains("ui.err_relocate_verify_failed"), "{err}");
        assert!(!library_entries_at(&dest));
        assert!(!dest.join(STAGING_DIR).exists());
        assert!(from.join("originals/aa/2026/09/a.jpg").is_file());
    }

    // 索引里有、原库里本来就没有的（服务停着时在 Finder 里删的）不挡搬迁——那是 reconcile 的事。
    #[test]
    fn a_stale_index_entry_does_not_block_the_move() {
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (from, _) = library(home.path(), "Lib");
        let dest = user_dest(home.path());
        let c = plan(&from, &dest, local.path()).unwrap();
        let same = |_: &Path, _: &Path| Some(true);
        let indexed = || {
            Ok(vec![
                "originals/aa/2026/09/a.jpg".to_string(),
                "originals/aa/2026/09/gone.jpg".to_string(),
            ])
        };
        move_library_with(&c.plan, &no_progress(), &indexed, &deps(&same, &|_| {})).unwrap();
        assert!(dest.join("originals/aa/2026/09/a.jpg").is_file());
    }

    // 改指向失败：撤回后原库完整、目标里没有我们的东西（同卷改名回去）。
    #[test]
    fn a_failed_repoint_is_undone() {
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (from, _) = library(home.path(), "Lib");
        let dest = user_dest(home.path());
        let c = plan(&from, &dest, local.path()).unwrap();
        let same = |_: &Path, _: &Path| Some(true);
        let moved =
            move_library_with(&c.plan, &no_progress(), &indexed_ok, &deps(&same, &|_| {})).unwrap();
        assert!(complete(local.path(), &c.plan, |_| Err("keychain".into())).is_err());
        moved.undo(&c.plan);
        assert!(from.join("originals/aa/2026/09/a.jpg").is_file());
        assert!(!library_entries_at(&dest));
        assert!(!pending(local.path()).unwrap().flipped);
    }

    // 用户自己把库搬过去了，选的就是它：只改指向，不再搬、不删。
    #[test]
    fn choosing_the_library_itself_only_repoints() {
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (old, id) = library(home.path(), "Old");
        let moved_dir = home.path().join("Moved");
        std::fs::rename(&old, &moved_dir).unwrap();
        layout::record_library_id(local.path(), &id).unwrap();
        let c = plan(&old, &moved_dir, local.path()).unwrap();
        assert!(c.adopt);
        let same = |_: &Path, _: &Path| Some(true);
        move_library_with(&c.plan, &no_progress(), &indexed_ok, &deps(&same, &|_| {})).unwrap();
        assert!(moved_dir.join("originals/aa/2026/09/a.jpg").is_file());
    }

    // 同卷逐个改名到一半被打断（库标记已过去、照片还在原处）：重启后接着搬完，原目录里的照片不能
    // 被当成「已经搬完」删掉。反证：只看原目录有没有库标记就走捷径 ⇒ a.jpg 跟着原目录被删，红。
    #[test]
    fn an_interrupted_same_volume_move_resumes_instead_of_deleting() {
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (from, id) = library(home.path(), "Lib");
        let dest = user_dest(home.path());
        let c = plan(&from, &dest, local.path()).unwrap();
        std::fs::rename(from.join(LIBRARY_MARKER), dest.join(LIBRARY_MARKER)).unwrap();
        let same = |_: &Path, _: &Path| Some(true);
        move_library_with(&c.plan, &no_progress(), &indexed_ok, &deps(&same, &|_| {})).unwrap();
        complete(local.path(), &c.plan, |_| Ok(())).unwrap();
        assert_eq!(layout::read_library_id(&dest), Some(id));
        assert!(
            dest.join("originals/aa/2026/09/a.jpg").is_file(),
            "照片搬过去了"
        );
        assert!(dest.join("notes.txt").is_file());
        assert!(!from.exists());
    }

    // 方案 B 与首次设置一致：选的文件夹不存在就建出来（预检不建，落计划时建）。
    #[test]
    fn a_missing_target_folder_is_created() {
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (from, _) = library(home.path(), "Lib");
        let dest = home.path().join("New/Photos");
        let c = check(&from, &dest, local.path()).unwrap();
        assert!(!c.non_empty);
        assert!(!dest.exists(), "预检不建");
        plan(&from, &dest, local.path()).unwrap();
        assert!(dest.is_dir());
    }

    // 跨卷改名到位到一半被打断（目标里已有库标记与部分照片，原库完整）：重启后清掉我们放的、从头来，
    // 不报「重名」、不留第二份。反证：去掉 promoting 时的清理 ⇒ 重名报错，红。
    #[test]
    fn a_cross_volume_move_interrupted_while_promoting_starts_over() {
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (from, id) = library(home.path(), "Lib");
        let dest = user_dest(home.path());
        let mut p = plan(&from, &dest, local.path()).unwrap().plan;
        let staging = dest.join(STAGING_DIR);
        platform::copy_dir_contents(&from, &staging).unwrap();
        std::fs::rename(staging.join(LIBRARY_MARKER), dest.join(LIBRARY_MARKER)).unwrap();
        std::fs::rename(staging.join("notes.txt"), dest.join("notes.txt")).unwrap();
        p.promoting = true;
        let cross = |_: &Path, _: &Path| Some(false);
        move_library_with(&p, &no_progress(), &indexed_ok, &deps(&cross, &|_| {})).unwrap();
        complete(local.path(), &p, |_| Ok(())).unwrap();
        assert_eq!(layout::read_library_id(&dest), Some(id));
        assert!(dest.join("originals/aa/2026/09/a.jpg").is_file());
        assert!(!staging.exists());
        assert_eq!(std::fs::read(dest.join("mine.txt")).unwrap(), b"keep me");
        assert!(!from.exists());
    }

    // 改完指向、还没记下「已改指向」就中断：服务读到的位置已是新位置 ⇒ 只差删原目录。
    #[test]
    fn a_crash_right_after_setting_the_location_counts_as_repointed() {
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (from, _) = library(home.path(), "Lib");
        let dest = user_dest(home.path());
        let c = plan(&from, &dest, local.path()).unwrap();
        assert!(!already_repointed(&c.plan, &from));
        assert!(already_repointed(&c.plan, &dest));
    }

    #[test]
    fn nesting_and_name_conflicts_are_refused() {
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (from, _) = library(home.path(), "Lib");
        let err = check(&from, &from.join("originals"), local.path()).unwrap_err();
        assert!(err.contains("ui.err_library_nested"), "{err}");
        let dest = home.path().join("Disk");
        std::fs::create_dir_all(dest.join("originals")).unwrap();
        let err = check(&from, &dest, local.path()).unwrap_err();
        assert!(
            err.contains("ui.err_relocate_conflict"),
            "重名不合并、不覆盖：{err}"
        );
    }

    // 跨卷且空间不够：拒绝并说明缺多少；同卷（改名不占新空间）不查空间。
    // 反证：去掉空间检查 ⇒ 第一段通过，红。
    #[test]
    fn not_enough_space_on_another_volume_is_refused_with_the_shortfall() {
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (from, _) = library(home.path(), "Lib");
        let dest = home.path().join("Disk");
        std::fs::create_dir_all(&dest).unwrap();
        let cross = |_: &Path, _: &Path| Some(false);
        let tiny = |_: &Path| Some(3);
        let local_net = |_: &Path| false;
        let err = check_with(
            &from,
            &dest,
            local.path(),
            &probes(&cross, &tiny, &local_net),
        )
        .unwrap_err();
        assert!(err.contains("ui.err_relocate_no_space"), "{err}");
        assert!(err.contains("short"), "说明缺多少：{err}");
        let same = |_: &Path, _: &Path| Some(true);
        assert!(check_with(
            &from,
            &dest,
            local.path(),
            &probes(&same, &tiny, &local_net)
        )
        .is_ok());
    }

    #[test]
    fn a_network_volume_is_refused() {
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (from, _) = library(home.path(), "Lib");
        let dest = home.path().join("Share");
        std::fs::create_dir_all(&dest).unwrap();
        let same = |_: &Path, _: &Path| Some(true);
        let plenty = |_: &Path| Some(u64::MAX);
        let net = |_: &Path| true;
        let err =
            check_with(&from, &dest, local.path(), &probes(&same, &plenty, &net)).unwrap_err();
        assert!(err.contains("ui.err_relocate_network_volume"), "{err}");
    }

    // 选的位置是另一个库、在另一个库里面，或在当前库里面：都拒绝。
    // 反证：去掉「祖先目录有库 ID」的检查 ⇒ 前两条通过（嵌进别的库），红。
    #[test]
    fn another_library_or_inside_one_is_refused() {
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (from, _) = library(home.path(), "Lib");
        let (other, _) = library(home.path(), "Other");
        let err = check(&from, &other, local.path()).unwrap_err();
        assert!(
            err.contains("ui.err_relocate_other_library"),
            "目标就是别的库：{err}"
        );
        let err = check(&from, &other.join("originals/aa"), local.path()).unwrap_err();
        assert!(
            err.contains("ui.err_relocate_other_library"),
            "目标在别的库里面：{err}"
        );
        let err = check(&from, &from.join("originals/aa"), local.path()).unwrap_err();
        assert!(
            err.contains("ui.err_library_nested"),
            "目标在当前库里面：{err}"
        );
    }

    #[test]
    fn appledouble_and_ds_store_do_not_count() {
        let home = tempfile::tempdir().unwrap();
        let (lib, _) = library(home.path(), "Lib");
        let before = Manifest::scan(&lib).unwrap();
        std::fs::write(lib.join("originals/aa/2026/09/._a.jpg"), [0u8; 4096]).unwrap();
        std::fs::write(lib.join(".DS_Store"), b"x").unwrap();
        assert_eq!(Manifest::scan(&lib).unwrap(), before);
    }

    // 改完指向、还没删原目录时崩溃：下次启动只补删原目录、清计划。
    // 反证：finish_flipped 不删原目录 ⇒ 红。
    #[test]
    fn a_crash_after_repointing_only_finishes_the_cleanup() {
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (from, _) = library(home.path(), "Lib");
        let dest = user_dest(home.path());
        let c = plan(&from, &dest, local.path()).unwrap();
        let cross = |_: &Path, _: &Path| Some(false);
        move_library_with(&c.plan, &no_progress(), &indexed_ok, &deps(&cross, &|_| {})).unwrap();
        mark_flipped(local.path(), &c.plan).unwrap();
        let resumed = pending(local.path()).unwrap();
        assert!(resumed.flipped);
        finish_flipped(local.path(), &resumed);
        assert!(!from.exists(), "原目录补删了");
        assert!(dest.join("originals/aa/2026/09/a.jpg").is_file());
        assert_eq!(pending(local.path()), None);
    }

    // 真跨卷（手动跑）：PPASS_RELOCATE_OTHER_VOLUME 指向另一个卷上的空文件夹（如 hdiutil 挂的镜像），
    // 用生产的平台探测与复制工具走一遍，确认判成跨卷、系统工具拷完核对通过、原目录删掉。
    #[test]
    #[ignore = "需要另一个卷：PPASS_RELOCATE_OTHER_VOLUME=<另一个卷上的空文件夹>"]
    fn a_real_cross_volume_move() {
        let other = PathBuf::from(std::env::var("PPASS_RELOCATE_OTHER_VOLUME").unwrap());
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (from, id) = library(home.path(), "Lib");
        assert_eq!(
            platform::same_volume(&from, &other),
            Some(false),
            "要在另一个卷上"
        );
        let c = plan(&from, &other, local.path()).unwrap();
        let moved = move_library(local.path(), &c.plan, &no_progress(), &indexed_ok).unwrap();
        assert!(!moved.renamed);
        complete(local.path(), &c.plan, |_| Ok(())).unwrap();
        assert_eq!(layout::read_library_id(&other), Some(id));
        assert_eq!(
            std::fs::read(other.join("originals/aa/2026/09/a.jpg")).unwrap(),
            b"photo-a"
        );
        assert!(!other.join(STAGING_DIR).exists());
        assert!(!from.exists());
    }

    #[test]
    fn the_source_is_only_removed_once_the_target_is_this_library() {
        let home = tempfile::tempdir().unwrap();
        let (from, id) = library(home.path(), "Lib");
        let plan = Plan {
            from: from.clone(),
            to: home.path().join("Elsewhere"),
            id,
            flipped: true,
            promoting: false,
        };
        assert!(remove_source(&plan).is_err());
        assert!(from.exists(), "新位置不是这个库，原目录一个文件都不删");
    }
}
