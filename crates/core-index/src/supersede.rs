//! #851：用原图替换抹过拍摄地点的旧副本。
//!
//! Android 10+ 给没有 `ACCESS_MEDIA_LOCATION` 的 App 读照片时，把位置相关字节置 0、长度不变
//! （三星 Android 15 实测 JPEG / HEIC / MP4 都是这样，样本见 core-media 的 tests/fixtures/redaction）。
//! 于是库里有一批「旧副本 A」，手机现在能读出原图 B。A 与 B 指纹不同，按指纹认照片的库会把 B
//! 当成另一张——这里把 A **原地**换成 B，库里仍是一张。
//!
//! 分两步，中间由 daemon 走网络：
//! 1. [`Ingestor::plan_supersede`]：核对 A 归这台设备、文件还在，按 A 的结构算出元数据区间
//!    （只向手机要这几段）。
//! 2. [`Ingestor::apply_supersede`]：把收到的 B 的字节拼进 A 的副本，核对「只是抹地点」
//!    （长度相同；凡是不同的位置，A 在那里都是 0）且整份文件的指纹 = B，然后：
//!    一个事务里删 A 行、插 B 行（同一 rel_path）、记别名、记待换文件 → rename 换文件
//!    → 清待换记录。任何一步之前失败都不动库；换文件前崩溃由 [`Ingestor::finish_pending_swaps`]
//!    在启动时补完，`rel_path` 上任何时刻都有文件（对账不会把它当成外部删除）。
//!
//! 不留旧副本（#1182）：rename 覆盖之后 A 不在任何位置，库占盘仍是 1x。留着 A 没有用处——
//! 换之前已逐字节核对 B 包含 A 的全部信息（长度相同、差异处 A 为 0、整份指纹 = B），崩溃补完
//! 也只用 staged 文件与待换记录。旧版留在 [`SUPERSEDED_RESIDUE_DIR`] 的存量由
//! [`sweep_superseded_residue`] 清掉。
//!
//! 核对不通过一律拒绝、两份都不动：宁可留着抹过地点的副本，也不换错照片。
//!
//! staged 文件（[`SUPERSEDE_STAGING_DIR`] 下的 `<新指纹>-<pid>.part`）的去留（#1183）：
//! - 出错路径当场删：拼接 / 核对出错、索引事务报错（且没有这个新指纹的待换记录）；
//! - 有待换记录的一律留给 [`Ingestor::finish_pending_swaps`]；
//! - 其余（事务提交前崩溃 / 断电留下的）由 [`sweep_supersede_staging`] 清。文件名里带写入
//!   进程的 pid：本进程写的可能正在拼，一律不碰。

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::ops::Range;
use std::path::{Path, PathBuf};

use storage::{Asset, Db};

use crate::{dedup, IndexError, Ingestor, Result};

/// 一次替换最多向手机要这么多字节（MP4 的 moov 可能有几 MB）；超过就拒绝，不整张重传。
pub const MAX_REGION_BYTES: u64 = 8 * 1024 * 1024;

/// 残留目录：v2026.10.4 起到 #1182 之前，被替换掉的旧副本会被留在这里、永不回收（占盘翻倍）。
/// 现在**没有任何写入方**，只由 [`sweep_superseded_residue`] 按判据清掉存量。
pub const SUPERSEDED_RESIDUE_DIR: &str = ".ppf/superseded";
/// 拼接 B 用的临时目录（#1183：名字 `<新指纹 hex>-<pid>.part`）。
pub const SUPERSEDE_STAGING_DIR: &str = ".ppf/supersede-staging";
const STAGED_SUFFIX: &str = ".part";

/// 第一步的结论。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SupersedeCheck {
    /// 可以做：向手机要 `ranges` 这几段 B 的字节，再调 [`Ingestor::apply_supersede`]。
    Ready(SupersedePlan),
    /// 已经换过了（别名 A→B 在、B 的文件在）：重放同一个请求直接回成功。
    AlreadyDone,
    /// 不做，原因进回复（见 [`SupersedeCheck::Refused`] 的取值）。
    Refused(&'static str),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SupersedePlan {
    pub old: [u8; 32],
    pub rel_path: String,
    pub len: u64,
    pub ranges: Vec<Range<u64>>,
}

/// 第二步的结论。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SupersedeApplied {
    /// 已换成 B（`rel_path` 不变）。A 被 rename 覆盖、不留任何副本（#1182）。
    Replaced {
        rel_path: String,
    },
    Refused(&'static str),
}

impl Ingestor {
    pub async fn plan_supersede(
        &self,
        old: &[u8; 32],
        new: &[u8; 32],
        uploader: &[u8],
    ) -> Result<SupersedeCheck> {
        if self.db.alias_target(old).await?.as_deref() == Some(new.as_slice())
            && self.has_durable_copy(new).await?
        {
            return Ok(SupersedeCheck::AlreadyDone);
        }
        let Some(asset) = self.db.get_asset(old).await? else {
            return Ok(SupersedeCheck::Refused("old_missing"));
        };
        if asset.src_device != uploader {
            return Ok(SupersedeCheck::Refused("not_uploader"));
        }
        // #1150: the file to read must resolve inside the library.
        let Ok(path) = crate::resolve_in_library(&self.library_root, &asset.rel_path) else {
            return Ok(SupersedeCheck::Refused("old_missing"));
        };
        let plan = tokio::task::block_in_place(
            || -> Result<std::result::Result<SupersedePlan, &'static str>> {
                if !path.exists() {
                    return Ok(Err("old_missing"));
                }
                // 不在这里算指纹：apply 拼之前会核对副本确实是 A（大视频算一次就是几秒，不算两遍）。
                let mut f = File::open(&path).map_err(io_err(&path))?;
                let len = f.metadata().map_err(io_err(&path))?.len();
                let Some(mut ranges) = core_media::metadata_ranges_from(&mut f, len) else {
                    return Ok(Err("unknown_format"));
                };
                ranges.retain(|r| r.start < r.end && r.end <= len);
                if ranges.is_empty() {
                    return Ok(Err("unknown_format"));
                }
                if ranges.iter().map(|r| r.end - r.start).sum::<u64>() > MAX_REGION_BYTES {
                    return Ok(Err("region_too_large"));
                }
                Ok(Ok(SupersedePlan {
                    old: *old,
                    rel_path: asset.rel_path.clone(),
                    len,
                    ranges,
                }))
            },
        )?;
        Ok(match plan {
            Ok(plan) => SupersedeCheck::Ready(plan),
            Err(reason) => SupersedeCheck::Refused(reason),
        })
    }

    /// `size` / `pieces`：手机上 B 的总长度与收到的字节（`(offset, bytes)`，已按 B 的根哈希逐块校验过）。
    pub async fn apply_supersede(
        &self,
        plan: &SupersedePlan,
        new: &[u8; 32],
        size: u64,
        pieces: &[(u64, Vec<u8>)],
        now_ms: i64,
    ) -> Result<SupersedeApplied> {
        if size != plan.len {
            return Ok(SupersedeApplied::Refused("size_mismatch"));
        }
        let covered = |r: &Range<u64>| {
            pieces
                .iter()
                .any(|(off, buf)| *off <= r.start && r.end <= off + buf.len() as u64)
        };
        if !plan.ranges.iter().all(covered)
            || pieces
                .iter()
                .any(|(off, buf)| off + buf.len() as u64 > size)
        {
            return Ok(SupersedeApplied::Refused("incomplete_ranges"));
        }
        let Some(asset) = self.db.get_asset(&plan.old).await? else {
            return Ok(SupersedeApplied::Refused("old_missing"));
        };
        let old_abs = self.library_root.join(&plan.rel_path);
        let hex = hex32(new);
        let staged_rel = format!(
            "{SUPERSEDE_STAGING_DIR}/{hex}-{}{STAGED_SUFFIX}",
            std::process::id()
        );
        let staged = self.library_root.join(&staged_rel);

        // 拼：A 的副本 + B 的这几段。副本先核对确实是 A（规划之后文件可能又被动过）。
        let verdict =
            tokio::task::block_in_place(|| -> Result<std::result::Result<(), &'static str>> {
                mkdir_parent(&staged)?;
                fs::copy(&old_abs, &staged).map_err(io_err(&staged))?;
                if dedup::hash_file(&staged)? != plan.old {
                    return Ok(Err("old_changed"));
                }
                let mut f = OpenOptions::new()
                    .read(true)
                    .write(true)
                    .open(&staged)
                    .map_err(io_err(&staged))?;
                for (off, buf) in pieces {
                    let mut a = vec![0u8; buf.len()];
                    f.seek(SeekFrom::Start(*off)).map_err(io_err(&staged))?;
                    f.read_exact(&mut a).map_err(io_err(&staged))?;
                    // 只是抹地点：凡是不同的位置，A 在那里都是 0。
                    if a.iter().zip(buf).any(|(x, y)| x != y && *x != 0) {
                        return Ok(Err("not_a_redaction"));
                    }
                    f.seek(SeekFrom::Start(*off)).map_err(io_err(&staged))?;
                    f.write_all(buf).map_err(io_err(&staged))?;
                }
                f.sync_all().map_err(io_err(&staged))?;
                drop(f);
                if dedup::hash_file(&staged)? != *new {
                    return Ok(Err("hash_mismatch"));
                }
                Ok(Ok(()))
            });
        // #1183：拼接 / 核对出错（io 错误）与核对不通过一样，当场删掉自己的 staged——
        // 此刻还没有待换记录，留着它没有任何用处。
        let verdict = match verdict {
            Ok(v) => v,
            Err(e) => {
                let _ = fs::remove_file(&staged);
                return Err(e);
            }
        };
        if let Err(reason) = verdict {
            let _ = fs::remove_file(&staged);
            return Ok(SupersedeApplied::Refused(reason));
        }

        let replacement = Asset {
            hash: new.to_vec(),
            bytes: size as i64,
            thumb_state: 0,
            ..asset
        };
        if let Err(e) = self
            .db
            .supersede_asset(&plan.old, &replacement, &staged_rel, now_ms)
            .await
        {
            // #1183：事务报错 = 整体回滚，正常情况下没有待换记录，staged 删掉。
            // 现读一次待换记录再删：万一有（或者连查询也失败、判断不了），就留给
            // `finish_pending_swaps` / 残留清扫，不冒险删掉补完要用的文件。
            if matches!(self.db.pending_swaps().await, Ok(p) if !p.iter().any(|p| p.new_hash == new.as_slice()))
            {
                let _ = fs::remove_file(&staged);
            }
            return Err(e.into());
        }
        // 走到这里待换记录已在：换文件失败时 staged 必须留着，由 `finish_pending_swaps` 补完。
        self.swap_in(new, &plan.rel_path, &staged_rel).await?;
        Ok(SupersedeApplied::Replaced {
            rel_path: plan.rel_path.clone(),
        })
    }

    /// 启动时调：补完「索引已改、文件还没换」的替换。返回补完了几条。
    pub async fn finish_pending_swaps(&self) -> Result<usize> {
        let pending = self.db.pending_swaps().await?;
        let n = pending.len();
        for p in pending {
            self.swap_in(&p.new_hash, &p.rel_path, &p.staged_path)
                .await?;
        }
        Ok(n)
    }

    /// staged 在就 rename 过去（原子，同卷）；不在说明上次已经换过了。之后清待换记录。
    async fn swap_in(&self, new: &[u8], rel_path: &str, staged_rel: &str) -> Result<()> {
        let staged = self.library_root.join(staged_rel);
        if staged.exists() {
            let dest = self.library_root.join(rel_path);
            fs::rename(&staged, &dest).map_err(io_err(&dest))?;
        }
        self.db.clear_pending_swap(new).await?;
        Ok(())
    }
}

/// 一类残留清扫的结果：删了几个、释放了多少字节，以及没删的（指纹前 8 位 + 原因，给日志用；
/// 不带路径、不带完整指纹，按日志脱敏约定；文件名认不出是我们命名的记 `-`）。
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ResidueSweep {
    pub removed: u64,
    pub freed_bytes: u64,
    pub kept: Vec<(String, &'static str)>,
    /// 目录清空后已删除（只有 [`sweep_superseded_residue`] 会删自己的目录）。
    pub dir_removed: bool,
}

impl ResidueSweep {
    fn keep(&mut self, tag: impl Into<String>, reason: &'static str) {
        self.kept.push((tag.into(), reason));
    }

    fn remove(&mut self, path: &Path, tag: String, len: u64) {
        match fs::remove_file(path) {
            Ok(()) => {
                self.removed += 1;
                self.freed_bytes += len;
            }
            Err(_) => self.keep(tag, "remove_failed"),
        }
    }
}

/// 目录里的一项：路径、名字、是不是普通文件（不跟随符号链接）、长度。
struct DirItem {
    path: PathBuf,
    name: String,
    is_file: bool,
    len: u64,
}

/// 列目录（不递归、不跟随符号链接）。目录不在 ⇒ `None`。在阻塞线程上做（§5.6）。
async fn list_dir(dir: PathBuf) -> Result<Option<Vec<DirItem>>> {
    let joined = tokio::task::spawn_blocking(move || -> Result<Option<Vec<DirItem>>> {
        let io_dir = |source| IndexError::Io {
            path: dir.clone(),
            source,
        };
        let meta = match fs::symlink_metadata(&dir) {
            Ok(m) => m,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(io_dir(e)),
        };
        // 目录本身是符号链接（指到库外）：不进去。
        if !meta.is_dir() {
            return Ok(None);
        }
        let mut out = Vec::new();
        for entry in fs::read_dir(&dir).map_err(io_dir)? {
            let entry = entry.map_err(io_dir)?;
            let kind = entry.file_type().map_err(io_dir)?;
            let len = if kind.is_file() {
                entry.metadata().map(|m| m.len()).unwrap_or(0)
            } else {
                0
            };
            out.push(DirItem {
                path: entry.path(),
                name: entry.file_name().to_string_lossy().into_owned(),
                is_file: kind.is_file(),
                len,
            });
        }
        Ok(Some(out))
    })
    .await;
    joined.map_err(|e| IndexError::Io {
        path: PathBuf::new(),
        source: std::io::Error::other(e.to_string()),
    })?
}

/// #1182 / #1183：清掉旧版留在 [`SUPERSEDED_RESIDUE_DIR`] 里的旧副本。该目录没有写入方，
/// 任何时刻都可以跑（判据第 4 条只在补完失败时留下文件）。
///
/// **判据（全部满足才删，否则不删、记进 `kept`）**：
/// 1. 目录里的普通文件（符号链接、子目录不碰、不递归），文件名严格是 `<64 位小写 hex>.<扩展名>`；
/// 2. 别名表里有 这个指纹 → 某个新指纹（`alias_target`）；
/// 3. 新指纹的 asset 行存在，且它的 `rel_path` 在盘上是普通文件；
/// 4. 新指纹没有未换完的待换记录（补完失败时 `rel_path` 上可能仍是旧副本，此刻不删）。
///
/// 满足时，这份旧副本的信息已全部包含在库里那份原图里（替换前逐字节核对过），删掉不丢数据。
/// 目录只在删空后用 `remove_dir` 删（非空自然失败）；绝不递归删除。
pub async fn sweep_superseded_residue(db: &Db, library_root: &Path) -> Result<ResidueSweep> {
    let dir = library_root.join(SUPERSEDED_RESIDUE_DIR);
    let mut out = ResidueSweep::default();
    let Some(items) = list_dir(dir.clone()).await? else {
        return Ok(out);
    };
    let pending: Vec<Vec<u8>> = db
        .pending_swaps()
        .await?
        .into_iter()
        .map(|p| p.new_hash)
        .collect();
    for item in items {
        // 只有认得出的指纹名才给前 8 位；别的名字可能是用户自己的文件名，一个字也不进日志。
        let parsed = superseded_name_hash(&item.name);
        if !item.is_file {
            out.keep("-", "not_a_file");
            continue;
        }
        let Some(old) = parsed else {
            out.keep("-", "unrecognized_name");
            continue;
        };
        let tag = hex32(&old[..4]);
        let Some(target) = db.alias_target(&old).await? else {
            out.keep(tag, "no_alias");
            continue;
        };
        let Some(asset) = db.get_asset(&target).await? else {
            out.keep(tag, "target_missing");
            continue;
        };
        if !library_root.join(&asset.rel_path).is_file() {
            out.keep(tag, "target_file_missing");
            continue;
        }
        if pending.contains(&target) {
            out.keep(tag, "swap_pending");
            continue;
        }
        out.remove(&item.path, tag, item.len);
    }
    out.dir_removed = fs::remove_dir(&dir).is_ok();
    Ok(out)
}

/// #1183：清掉 [`SUPERSEDE_STAGING_DIR`] 里没人要的 staged 文件（事务提交前崩溃 / 断电留下的，
/// 或旧版出错路径漏删的）。运行期随时可跑。
///
/// **判据（全部满足才删，否则不删、记进 `kept`）**：
/// 1. 目录里的普通文件（符号链接、子目录不碰、不递归）；
/// 2. 文件名严格是 `<64 位小写 hex>.part`（旧版命名）或 `<64 位小写 hex>-<pid>.part`；
/// 3. 名字里的 pid 不是本进程（本进程写的可能正在拼接 / 等事务，属于「正在进行的操作」）；
/// 4. 待换表里没有任何记录指向它：`staged_path` 不是它，`new_hash` 也不是它名字里的指纹
///    （有记录的归 [`Ingestor::finish_pending_swaps`] 补完）。待换表现读，查询失败整类跳过。
///
/// staged 永远是「A 的副本 + 手机给的几段」，A 在补完前一直在 `rel_path` 上，删掉不丢数据。
/// 目录本身不删（下次替换还要用）。
pub async fn sweep_supersede_staging(db: &Db, library_root: &Path) -> Result<ResidueSweep> {
    let dir = library_root.join(SUPERSEDE_STAGING_DIR);
    let mut out = ResidueSweep::default();
    let Some(items) = list_dir(dir).await? else {
        return Ok(out);
    };
    let pending = db.pending_swaps().await?;
    let me = std::process::id();
    for item in items {
        if !item.is_file {
            out.keep("-", "not_a_file");
            continue;
        }
        let Some((hash, pid)) = staged_name(&item.name) else {
            out.keep("-", "unrecognized_name");
            continue;
        };
        let tag = hex32(&hash[..4]);
        if pid == Some(me) {
            out.keep(tag, "in_flight");
            continue;
        }
        let rel = format!("{SUPERSEDE_STAGING_DIR}/{}", item.name);
        if pending
            .iter()
            .any(|p| p.staged_path == rel || p.new_hash == hash.as_slice())
        {
            out.keep(tag, "swap_pending");
            continue;
        }
        out.remove(&item.path, tag, item.len);
    }
    Ok(out)
}

/// `<64 hex>.part` → (指纹, None)；`<64 hex>-<十进制 pid>.part` → (指纹, Some(pid))；别的 `None`。
fn staged_name(name: &str) -> Option<([u8; 32], Option<u32>)> {
    let stem = name.strip_suffix(STAGED_SUFFIX)?;
    let (hex, pid) = match stem.split_once('-') {
        Some((hex, pid)) => {
            if pid.is_empty() || !pid.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            (hex, Some(pid.parse::<u32>().ok()?))
        }
        None => (stem, None),
    };
    Some((parse_hex32(hex)?, pid))
}

/// `<64 位小写 hex>.<非空扩展名>` → 指纹；别的一律 `None`。
fn superseded_name_hash(name: &str) -> Option<[u8; 32]> {
    let (stem, ext) = name.split_once('.')?;
    if ext.is_empty() {
        return None;
    }
    parse_hex32(stem)
}

/// 恰好 64 位小写 hex → 32 字节；别的一律 `None`。
pub(crate) fn parse_hex32(stem: &str) -> Option<[u8; 32]> {
    if stem.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, pair) in stem.as_bytes().chunks(2).enumerate() {
        let nib = |c: u8| match c {
            b'0'..=b'9' => Some(c - b'0'),
            b'a'..=b'f' => Some(c - b'a' + 10),
            _ => None,
        };
        out[i] = nib(pair[0])? << 4 | nib(pair[1])?;
    }
    Some(out)
}

fn hex32(h: &[u8]) -> String {
    h.iter().map(|b| format!("{b:02x}")).collect()
}

fn mkdir_parent(p: &Path) -> Result<()> {
    if let Some(dir) = p.parent() {
        fs::create_dir_all(dir).map_err(io_err(dir))?;
    }
    Ok(())
}

fn io_err(path: &Path) -> impl FnOnce(std::io::Error) -> IndexError + '_ {
    move |source| IndexError::Io {
        path: PathBuf::from(path),
        source,
    }
}
