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
//! 也只用 staged 文件与待换记录。旧版留在 [`LEGACY_SUPERSEDED_DIR`] 的存量由
//! [`sweep_legacy_superseded`] 在启动时清掉。
//!
//! 核对不通过一律拒绝、两份都不动：宁可留着抹过地点的副本，也不换错照片。

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::ops::Range;
use std::path::{Path, PathBuf};

use storage::{Asset, Db};

use crate::{dedup, IndexError, Ingestor, Result};

/// 一次替换最多向手机要这么多字节（MP4 的 moov 可能有几 MB）；超过就拒绝，不整张重传。
pub const MAX_REGION_BYTES: u64 = 8 * 1024 * 1024;

/// 旧版遗留目录：v2026.10.4 起到 #1182 之前，被替换掉的旧副本会被留在这里、永不回收（占盘翻倍）。
/// 现在**没有任何写入方**，只由 [`sweep_legacy_superseded`] 在启动时按判据清掉存量。
pub const LEGACY_SUPERSEDED_DIR: &str = ".ppf/superseded";
const STAGING_DIR: &str = ".ppf/supersede-staging";

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
        let staged_rel = format!("{STAGING_DIR}/{hex}.part");
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
            })?;
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
        self.db
            .supersede_asset(&plan.old, &replacement, &staged_rel, now_ms)
            .await?;
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

/// [`sweep_legacy_superseded`] 的结果：删了几个，以及没删的（指纹前 8 位 + 原因，给日志用；
/// 不带路径、不带完整指纹，按日志脱敏约定；文件名认不出是指纹的记 `-`）。
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct LegacySupersededSweep {
    pub removed: u64,
    pub kept: Vec<(String, &'static str)>,
    /// 目录清空后已删除。
    pub dir_removed: bool,
}

/// #1182：清掉旧版留在 [`LEGACY_SUPERSEDED_DIR`] 里的旧副本。启动时、
/// [`Ingestor::finish_pending_swaps`] 之后调。
///
/// **判据（全部满足才删，否则不删、记进 `kept`）**：
/// 1. 目录里的普通文件（符号链接、子目录不碰、不递归），文件名严格是 `<64 位小写 hex>.<扩展名>`；
/// 2. 别名表里有 这个指纹 → 某个新指纹（`alias_target`）；
/// 3. 新指纹的 asset 行存在，且它的 `rel_path` 在盘上是普通文件；
/// 4. 新指纹没有未换完的待换记录（补完失败时 `rel_path` 上可能仍是旧副本，此刻不删）。
///
/// 满足时，这份旧副本的信息已全部包含在库里那份原图里（替换前逐字节核对过），删掉不丢数据。
/// 目录只在删空后用 `remove_dir` 删（非空自然失败）；绝不递归删除。
pub async fn sweep_legacy_superseded(
    db: &Db,
    library_root: &Path,
) -> Result<LegacySupersededSweep> {
    let dir = library_root.join(LEGACY_SUPERSEDED_DIR);
    let mut out = LegacySupersededSweep::default();
    if !dir.is_dir() {
        return Ok(out);
    }
    let pending: Vec<Vec<u8>> = db
        .pending_swaps()
        .await?
        .into_iter()
        .map(|p| p.new_hash)
        .collect();
    let io_dir = |source| IndexError::Io {
        path: dir.clone(),
        source,
    };
    let mut entries = Vec::new();
    for entry in fs::read_dir(&dir).map_err(io_dir)? {
        let entry = entry.map_err(io_dir)?;
        let is_file = entry.file_type().map_err(io_dir)?.is_file();
        entries.push((entry.path(), entry.file_name(), is_file));
    }
    for (path, name, is_file) in entries {
        let name = name.to_string_lossy();
        // 只有认得出的指纹名才给前 8 位；别的名字可能是用户自己的文件名，一个字也不进日志。
        let parsed = legacy_name_hash(&name);
        if !is_file {
            out.kept.push(("-".into(), "not_a_file"));
            continue;
        }
        let Some(old) = parsed else {
            out.kept.push(("-".into(), "unrecognized_name"));
            continue;
        };
        let tag = hex32(&old[..4]);
        let Some(target) = db.alias_target(&old).await? else {
            out.kept.push((tag, "no_alias"));
            continue;
        };
        let Some(asset) = db.get_asset(&target).await? else {
            out.kept.push((tag, "target_missing"));
            continue;
        };
        if !library_root.join(&asset.rel_path).is_file() {
            out.kept.push((tag, "target_file_missing"));
            continue;
        }
        if pending.contains(&target) {
            out.kept.push((tag, "swap_pending"));
            continue;
        }
        match fs::remove_file(&path) {
            Ok(()) => out.removed += 1,
            Err(_) => out.kept.push((tag, "remove_failed")),
        }
    }
    out.dir_removed = fs::remove_dir(&dir).is_ok();
    Ok(out)
}

/// `<64 位小写 hex>.<非空扩展名>` → 指纹；别的一律 `None`。
fn legacy_name_hash(name: &str) -> Option<[u8; 32]> {
    let (stem, ext) = name.split_once('.')?;
    if stem.len() != 64 || ext.is_empty() {
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
