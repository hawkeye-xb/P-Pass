//! Ingest: hash → dedup → land under `originals/` → index row → audit.
//!
//! 契约 (T-011): `ingest(IncomingFile) -> IngestOutcome{New|Duplicate|Moved}`.
//! EXIF `DateTimeOriginal` is the timeline key; missing EXIF falls back to
//! the file's mtime. Every ingest is audited to device granularity
//! (审计裁决 2026-07-29).

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use storage::{Asset, AuditEntry, Db};
use time::OffsetDateTime;

use crate::{dedup, IndexError, Result};

/// A file handed to ingest — bytes already fully on local disk (landed by
/// the blobs receiver, or found by the directory watcher). Ingest *moves*
/// it into the library; on `Duplicate` the source file is left untouched.
#[derive(Debug, Clone)]
pub struct IncomingFile {
    /// Where the bytes currently sit.
    pub src_path: PathBuf,
    /// Uploader-provided name, e.g. `IMG_1234.HEIC`. Reduced to its final
    /// component before use — a name can never escape the library dir.
    pub file_name: String,
    /// MIME type, e.g. `image/jpeg`.
    pub media_type: String,
    /// Uploading device NodeId (32 bytes) — audit actor + layout dir.
    pub src_device: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IngestOutcome {
    /// Landed and indexed; path relative to the library root.
    New(String),
    /// Content already in the library **and the recorded file is still
    /// there** — nothing was written.
    Duplicate,
    /// WATCH-03：同一内容已在索引里，但记录的文件不在磁盘上了，而这份
    /// 字节又出现在别处 —— 这是「移动」，不是新增也不是重复。索引改指
    /// 新位置（hash 是身份，路径只是当前住址），行不删。
    Moved(String),
}

/// Ingest façade over one library directory + its index.
#[derive(Clone)]
pub struct Ingestor {
    db: Db,
    library_root: PathBuf,
}

impl Ingestor {
    pub fn new(db: Db, library_root: impl Into<PathBuf>) -> Self {
        Self {
            db,
            library_root: library_root.into(),
        }
    }

    pub async fn ingest(&self, f: &IncomingFile) -> Result<IngestOutcome> {
        let hash = dedup::hash_file(&f.src_path)?;
        let now_ms = unix_ms_now();

        if let Some(existing) = self.db.get_asset(&hash).await? {
            if self.library_root.join(&existing.rel_path).exists() {
                self.audit(
                    now_ms,
                    f,
                    &hash,
                    "ingest.duplicate",
                    Some(existing.rel_path),
                )
                .await?;
                return Ok(IngestOutcome::Duplicate);
            }
            // WATCH-03：记录的住址空了，同一内容又出现在 src_path。
            // 这份内容早就属于这个库，只是搬了家——重新指向，不重复入库。
            // 已经在 originals/ 树内 = 用户自己摆的位置，就地采纳（分类归
            // 用户）；来自库外（staging）= 按 canonical 布局落位。
            let new_rel = match self.rel_inside_originals(&f.src_path) {
                Some(rel) => rel,
                None => self.place(f, taken_at_ms(&f.src_path)?)?,
            };
            self.db.update_asset_rel_path(&hash, &new_rel).await?;
            self.audit(now_ms, f, &hash, "asset.relocated", Some(new_rel.clone()))
                .await?;
            return Ok(IngestOutcome::Moved(new_rel));
        }

        let bytes = fs::metadata(&f.src_path)
            .map_err(|source| IndexError::Io {
                path: f.src_path.clone(),
                source,
            })?
            .len() as i64;
        let taken_at = taken_at_ms(&f.src_path)?;
        // Header-only probe; videos and exotic codecs are honest None
        // (the timeline shows them without dimensions).
        let (width, height) = match image::image_dimensions(&f.src_path) {
            Ok((w, h)) => (Some(w as i64), Some(h as i64)),
            Err(_) => (None, None),
        };
        // 宽容落位（2026-08-21 用户裁决）：`originals/` 是**用户的**目录。
        // 已经在树内的文件就地采纳（他在 Finder 里怎么摆就怎么留）；只有
        // 来自库外（手机上传落在 staging）的文件才由我们按 canonical 布局
        // 找个家——那些文件此刻还没有家。
        //
        // 理由（实测支撑见 docs/product/2026-08-21-macos-fs-events.md）：
        // 系统分不清「拖进来」和「拖出去」，我们本来就必须 stat 每个路径，
        // 宽容不多花一分钱；而备份工具最不该干的事就是把用户的文件从他放的
        // 位置挪走。ADR-006 的重建路径本来就是宽容的（rebuild.rs 模块注释），
        // 严格入库 + 宽容重建 = 重建一次库的语义就变了。
        let (rel_path, we_moved_it) = match self.rel_inside_originals(&f.src_path) {
            Some(rel) => (rel, false),
            None => (self.place(f, taken_at)?, true),
        };

        // 「一个路径只能被一条索引行占用」：用户编辑了一张我们收到的照片，
        // 内容变了 → hash 变了 → 走到这里是一条新行，而老行还指着同一个
        // 路径。老行记的那份内容在磁盘上**确实已经不存在了**，让位。
        // ⚠️ 已知欠账：老行的缩略图文件成为孤儿（thumb 按 hash 存，
        // core-index 不掌握 .ppf/thumbs 布局——那是 daemon 侧 Reconcile 的
        // 职责）。与 reconcile.rs 里已接受的孤儿 blob 同一类：内容寻址、
        // 无任何产品路径引用它，惰性无害。
        if let Some(evicted) = self.db.hash_at_rel_path(&rel_path).await? {
            if evicted != hash {
                self.db.delete_asset(&evicted).await?;
                self.audit(
                    now_ms,
                    f,
                    &hash,
                    "asset.replaced_in_place",
                    Some(rel_path.clone()),
                )
                .await?;
            }
        }

        let asset = Asset {
            hash: hash.to_vec(),
            rel_path: rel_path.clone(),
            media_type: f.media_type.clone(),
            bytes,
            taken_at: Some(taken_at),
            width,
            height,
            src_device: f.src_device.clone(),
            added_at: now_ms,
            thumb_state: 0,
        };
        if let Err(e) = self.db.insert_asset(&asset).await {
            // 只回滚**我们自己搬进来的**文件（来自库外）。就地采纳的文件是
            // 用户放在那儿的，入库失败绝不能把它删掉——那是删用户数据。
            if we_moved_it {
                let _ = fs::remove_file(self.library_root.join(&rel_path));
            }
            if is_unique_violation(&e) {
                // Lost a race with a concurrent ingest of the same content.
                self.audit(now_ms, f, &hash, "ingest.duplicate", None)
                    .await?;
                return Ok(IngestOutcome::Duplicate);
            }
            return Err(e.into());
        }

        self.audit(now_ms, f, &hash, "ingest.new", Some(rel_path.clone()))
            .await?;
        Ok(IngestOutcome::New(rel_path))
    }

    /// `src` 若已在本库的 `originals/` 树内，返回它的 rel_path（`/`
    /// 分隔，与索引口径一致）；否则 `None`。
    ///
    /// ⚠️ 两侧都要 canonicalize：macOS 上 `/var` 是 `/private/var` 的
    /// 符号链接，watcher 的监听根做过 canonicalize 而 `library_root` 通常
    /// 没有，不规范化的话 `strip_prefix` 永远失败，库内移动会被误判成
    /// 「来自库外」而被搬回日期目录。
    fn rel_inside_originals(&self, src: &Path) -> Option<String> {
        let root = self.library_root.canonicalize().ok()?;
        let src = src.canonicalize().ok()?;
        let rel = src.strip_prefix(&root).ok()?;
        let parts: Option<Vec<&str>> = rel
            .components()
            .map(|c| c.as_os_str().to_str())
            .collect::<Option<Vec<_>>>();
        let parts = parts?;
        if parts.first() != Some(&"originals") {
            return None; // .ppf/staging 之类不是「用户摆的位置」
        }
        Some(parts.join("/"))
    }

    /// Move the source file to `originals/<device>/<yyyy>/<mm>/<name>`,
    /// suffixing `-1`, `-2`, … on name collisions. Returns the rel path.
    fn place(&self, f: &IncomingFile, taken_at_ms: i64) -> Result<String> {
        let name = sanitize_file_name(&f.file_name);
        let (yyyy, mm) = year_month(taken_at_ms);
        let dir_rel = format!("originals/{}/{yyyy:04}/{mm:02}", device_dir(&f.src_device));
        let dir_abs = self.library_root.join(&dir_rel);
        fs::create_dir_all(&dir_abs).map_err(|source| IndexError::Io {
            path: dir_abs.clone(),
            source,
        })?;

        let (stem, ext) = split_name(&name);
        for i in 0..10_000u32 {
            let candidate = match (i, ext) {
                (0, _) => name.clone(),
                (_, Some(ext)) => format!("{stem}-{i}.{ext}"),
                (_, None) => format!("{stem}-{i}"),
            };
            let dest = dir_abs.join(&candidate);
            // create_new reserves the name atomically — two concurrent
            // ingests can't pick the same slot, only fall through to -N.
            match fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&dest)
            {
                Ok(_) => {
                    move_file(&f.src_path, &dest)?;
                    return Ok(format!("{dir_rel}/{candidate}"));
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(source) => return Err(IndexError::Io { path: dest, source }),
            }
        }
        Err(IndexError::NameSpaceExhausted(name))
    }

    async fn audit(
        &self,
        ts: i64,
        f: &IncomingFile,
        hash: &[u8; 32],
        action: &str,
        detail: Option<String>,
    ) -> Result<()> {
        self.db
            .append_audit(&AuditEntry {
                ts,
                actor: Some(f.src_device.clone()),
                action: action.into(),
                target_hash: Some(hash.to_vec()),
                detail,
            })
            .await?;
        Ok(())
    }
}

/// EXIF `DateTimeOriginal` (fallback `DateTime`) as unix ms — read via
/// core-media (T-013) — with the file's mtime as last resort. EXIF wall
/// clock carries no zone; core-media interprets it as UTC so the key is
/// stable across machines.
pub(crate) fn taken_at_ms(path: &Path) -> Result<i64> {
    if let Some(ms) = core_media::read_meta(path).taken_at_ms {
        return Ok(ms);
    }
    let io_err = |source| IndexError::Io {
        path: path.to_path_buf(),
        source,
    };
    let mtime = fs::metadata(path)
        .map_err(io_err)?
        .modified()
        .map_err(io_err)?;
    Ok(system_time_ms(mtime))
}

/// Layout dir for a device: the full NodeId as hex (§4.2 `<deviceId>`).
/// The tree alone must reproduce every index field on rebuild (ADR-006) —
/// a truncated prefix would lose `src_device` when the index is wiped.
pub(crate) fn device_dir(node_id: &[u8]) -> String {
    node_id.iter().map(|b| format!("{b:02x}")).collect()
}

fn year_month(unix_ms: i64) -> (i32, u8) {
    let dt = OffsetDateTime::from_unix_timestamp(unix_ms.div_euclid(1000))
        .unwrap_or(OffsetDateTime::UNIX_EPOCH);
    (dt.year(), u8::from(dt.month()))
}

/// Final path component only; `.`/`..`/empty become a safe placeholder.
fn sanitize_file_name(name: &str) -> String {
    let last = name.rsplit(['/', '\\']).next().unwrap_or_default().trim();
    match last {
        "" | "." | ".." => "unnamed.bin".into(),
        ok => ok.into(),
    }
}

/// `IMG_1.jpg` → (`IMG_1`, Some(`jpg`)); dotless and dotfiles keep the
/// whole name as stem so `-N` suffixes stay readable.
fn split_name(name: &str) -> (&str, Option<&str>) {
    match name.rsplit_once('.') {
        Some((stem, ext)) if !stem.is_empty() && !ext.is_empty() => (stem, Some(ext)),
        _ => (name, None),
    }
}

/// rename() when possible (same volume), copy+delete across volumes.
fn move_file(src: &Path, dest: &Path) -> Result<()> {
    if fs::rename(src, dest).is_ok() {
        return Ok(());
    }
    fs::copy(src, dest).map_err(|source| IndexError::Io {
        path: dest.to_path_buf(),
        source,
    })?;
    fs::remove_file(src).map_err(|source| IndexError::Io {
        path: src.to_path_buf(),
        source,
    })?;
    Ok(())
}

fn is_unique_violation(e: &storage::StorageError) -> bool {
    match e {
        storage::StorageError::Db(sqlx_err) => sqlx_err
            .as_database_error()
            .is_some_and(|d| d.is_unique_violation()),
        _ => false,
    }
}

fn unix_ms_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn system_time_ms(t: SystemTime) -> i64 {
    t.duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_strips_directories_and_traversal() {
        assert_eq!(sanitize_file_name("IMG_1.jpg"), "IMG_1.jpg");
        assert_eq!(sanitize_file_name("a/b/../IMG_1.jpg"), "IMG_1.jpg");
        assert_eq!(sanitize_file_name("..\\..\\evil.exe"), "evil.exe");
        assert_eq!(sanitize_file_name(".."), "unnamed.bin");
        assert_eq!(sanitize_file_name(""), "unnamed.bin");
        assert_eq!(sanitize_file_name("a/b/"), "unnamed.bin");
    }

    #[test]
    fn split_name_handles_dotless_and_dotfiles() {
        assert_eq!(split_name("IMG_1.jpg"), ("IMG_1", Some("jpg")));
        assert_eq!(split_name("noext"), ("noext", None));
        assert_eq!(split_name(".nomedia"), (".nomedia", None));
        assert_eq!(split_name("dot."), ("dot.", None));
    }

    #[test]
    fn year_month_matches_calendar() {
        // 2026-07-29T12:00:00Z
        assert_eq!(year_month(1_785_326_400_000), (2026, 7));
        assert_eq!(year_month(0), (1970, 1));
        // Pre-epoch stays sane (div_euclid, no panic).
        assert_eq!(year_month(-1), (1969, 12));
    }

    #[test]
    fn device_dir_is_full_node_id_hex() {
        let d = device_dir(&[0xab; 32]);
        assert_eq!(d.len(), 64);
        assert_eq!(d, "ab".repeat(32));
    }
}
