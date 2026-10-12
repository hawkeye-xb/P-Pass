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
//!    隔离 A → 一个事务里删 A 行、插 B 行（同一 rel_path）、记别名、记待换文件 → rename 换文件
//!    → 清待换记录。任何一步之前失败都不动库；换文件前崩溃由 [`Ingestor::finish_pending_swaps`]
//!    在启动时补完，`rel_path` 上任何时刻都有文件（对账不会把它当成外部删除）。
//!
//! 核对不通过一律拒绝、两份都不动：宁可留着抹过地点的副本，也不换错照片。

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::ops::Range;
use std::path::{Path, PathBuf};

use storage::Asset;

use crate::{dedup, IndexError, Ingestor, Result};

/// 一次替换最多向手机要这么多字节（MP4 的 moov 可能有几 MB）；超过就拒绝，不整张重传。
pub const MAX_REGION_BYTES: u64 = 8 * 1024 * 1024;

/// 隔离区：被替换掉的旧副本挪到这里（不进 `originals/`，重建索引不会把它捡回来），不硬删。
pub const QUARANTINE_DIR: &str = ".ppf/superseded";
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
    /// 已换成 B；`quarantined` 是旧副本挪去的位置（相对库根）。
    Replaced {
        rel_path: String,
        quarantined: String,
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
        let path = self.library_root.join(&asset.rel_path);
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

        // 隔离 A（硬链接，同卷零拷贝；不行就复制）——索引改之前旧字节已经有一份在库外。
        let ext = Path::new(&plan.rel_path)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("bin");
        let quarantined = format!("{QUARANTINE_DIR}/{}.{ext}", hex32(&plan.old));
        let q_abs = self.library_root.join(&quarantined);
        tokio::task::block_in_place(|| -> Result<()> {
            mkdir_parent(&q_abs)?;
            if !q_abs.exists() && fs::hard_link(&old_abs, &q_abs).is_err() {
                fs::copy(&old_abs, &q_abs).map_err(io_err(&q_abs))?;
            }
            Ok(())
        })?;

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
            quarantined,
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
