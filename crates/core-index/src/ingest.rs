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
    /// DESK-12: the uploader's own capture-time fact (phone MediaStore
    /// `DATE_TAKEN`, unix ms), used only when the file carries no EXIF.
    /// `None` for callers that have no such fact (legacy batch pipeline,
    /// local directory watcher) — those keep the pre-existing mtime
    /// fallback. This must NEVER override embedded EXIF: EXIF travels with
    /// the bytes through content-addressed transfer and is already correct;
    /// only the *local mtime* is untrustworthy for Flow-delivered files
    /// (iroh-blobs `export_to` stamps the export moment, not the original
    /// capture moment — the mtime silently becomes "when this daemon wrote
    /// the file to disk", not "when the photo was taken").
    pub capture_at_ms_hint: Option<i64>,
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
    pub(crate) db: Db,
    pub(crate) library_root: PathBuf,
    /// IDX-08 (#1010): the target OS's file-name policy, injected by the
    /// daemon from `platform::adapter()`. `None` keeps the POSIX behaviour
    /// (macOS/Linux). The function receives the name after core's traversal
    /// cleanup and returns the name to create on disk.
    pub(crate) file_name_sanitizer: Option<fn(&str) -> String>,
}

impl Ingestor {
    pub fn new(db: Db, library_root: impl Into<PathBuf>) -> Self {
        Self {
            db,
            library_root: library_root.into(),
            file_name_sanitizer: None,
        }
    }

    /// IDX-08 (#1010): inject the current OS's file-name policy. The daemon
    /// passes `platform::adapter().ingest_file_name_sanitizer()`; tests can
    /// pass a fake policy. `None` keeps the pre-#1010 behaviour.
    #[must_use]
    pub fn with_file_name_sanitizer(mut self, sanitizer: Option<fn(&str) -> String>) -> Self {
        self.file_name_sanitizer = sanitizer;
        self
    }

    /// WATCH-07：被 ingest 的文件就是索引记录里的同一个文件（同一路径）时，
    /// 这次 ingest 是「复检」而不是事件——备份管线 place() 之后 watcher 必然
    /// 再报一遍这个路径，每个文件写一条 `ingest.duplicate` 会把活动流刷屏。
    /// 审计只记「数据层面发生的事」：同一文件被看了第二遍 = 什么都没发生。
    /// 而**不同路径**出现的同内容文件是用户真实放了一份拷贝，仍记审计。
    /// canonicalize 双侧比较（/var vs /private/var 陷阱，WATCH-03 踩过）；
    /// 任一侧失败保守按「不同」处理（宁可多记一行，不漏真实事件）。
    fn is_recorded_file(&self, src_path: &Path, recorded_rel: &str) -> bool {
        let recorded = self.library_root.join(recorded_rel);
        match (src_path.canonicalize(), recorded.canonicalize()) {
            (Ok(a), Ok(b)) => a == b,
            _ => false,
        }
    }

    /// NET-20: true iff `hash` already has a durable, on-disk copy in this
    /// library. A caller about to fetch bytes over the network can skip that
    /// fetch entirely when this returns true.
    ///
    /// Deliberately NOT just `db.get_asset(hash).is_some()` — an index row
    /// whose recorded file no longer exists on disk (WATCH-03: the file was
    /// externally deleted, then the same content reappeared elsewhere) is
    /// not a durable copy; `ingest_inner`'s own duplicate check makes this
    /// exact distinction (`existing.rel_path` must still resolve), and this
    /// method mirrors it so the two duplicate judgements never diverge.
    ///
    /// #851: a hash that was superseded (a location-redacted copy replaced by its original) counts
    /// as durable when its replacement is — otherwise a phone re-reporting the old hash (presence
    /// reconcile, a second device, a revoked location grant) would upload the redacted copy again
    /// next to the original.
    pub async fn has_durable_copy(&self, hash: &[u8; 32]) -> Result<bool> {
        let existing = match self.db.get_asset(hash).await? {
            Some(existing) => existing,
            None => match self.db.alias_target(hash).await? {
                Some(target) => match self.db.get_asset(&target).await? {
                    Some(existing) => existing,
                    None => return Ok(false),
                },
                None => return Ok(false),
            },
        };
        Ok(self.library_root.join(&existing.rel_path).exists())
    }

    pub async fn ingest(&self, f: &IncomingFile) -> Result<IngestOutcome> {
        self.ingest_inner(f, true).await
    }

    /// AUDIT-01: Flow item materialization must not create a per-item
    /// long-term audit row — a Flow window writes exactly one
    /// `flow.round.finished` summary, never one row per file (card decision
    /// #3). This variant is otherwise byte-identical to [`Self::ingest`];
    /// only the audit side effect is suppressed. Legacy batch backup,
    /// rebuild, and the directory watcher keep calling the audited
    /// [`Self::ingest`] — their per-file audit trail is unaffected.
    pub async fn ingest_unaudited(&self, f: &IncomingFile) -> Result<IngestOutcome> {
        self.ingest_inner(f, false).await
    }

    async fn ingest_inner(&self, f: &IncomingFile, audited: bool) -> Result<IngestOutcome> {
        // block_in_place: hashing and (cross-volume) copying a large file
        // are CPU/IO-bound synchronous work whose cost scales with file
        // size — running them inline on a tokio worker thread starves every
        // other task scheduled on that thread for the duration. Traced to a
        // real symptom: a multi-hundred-MB Flow transfer's ingest froze the
        // desktop UI (photo wall refresh, pause/cancel clicks queued behind
        // the same local IPC handling) for as long as the hash+copy took
        // (2026-09-07). `block_in_place` moves this call off the runtime's
        // async scheduling for its duration without needing a dedicated
        // thread pool; it requires a multi-thread runtime, which every
        // production call site (the daemon binary) already uses.
        let hash = tokio::task::block_in_place(|| dedup::hash_file(&f.src_path))?;
        let now_ms = unix_ms_now();

        if let Some(existing) = self.db.get_asset(&hash).await? {
            if self.library_root.join(&existing.rel_path).exists() {
                if audited && !self.is_recorded_file(&f.src_path, &existing.rel_path) {
                    self.audit(
                        now_ms,
                        f,
                        &hash,
                        "ingest.duplicate",
                        Some(existing.rel_path),
                    )
                    .await?;
                }
                return Ok(IngestOutcome::Duplicate);
            }
            // WATCH-03：记录的住址空了，同一内容又出现在 src_path。
            // 这份内容早就属于这个库，只是搬了家——重新指向，不重复入库。
            // 已经在 originals/ 树内 = 用户自己摆的位置，就地采纳（分类归
            // 用户）；来自库外（staging）= 按 canonical 布局落位。
            let new_rel = match self.rel_inside_originals(&f.src_path) {
                Some(rel) => rel,
                None => self.place(f, taken_at_ms(&f.src_path, f.capture_at_ms_hint)?)?,
            };
            self.db.update_asset_rel_path(&hash, &new_rel).await?;
            if audited {
                self.audit(now_ms, f, &hash, "asset.relocated", Some(new_rel.clone()))
                    .await?;
            }
            return Ok(IngestOutcome::Moved(new_rel));
        }

        let bytes = fs::metadata(&f.src_path)
            .map_err(|source| IndexError::Io {
                path: f.src_path.clone(),
                source,
            })?
            .len() as i64;
        let taken_at = taken_at_ms(&f.src_path, f.capture_at_ms_hint)?;
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
                if audited {
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
                if audited {
                    self.audit(now_ms, f, &hash, "ingest.duplicate", None)
                        .await?;
                }
                return Ok(IngestOutcome::Duplicate);
            }
            return Err(e.into());
        }

        if audited {
            self.audit(now_ms, f, &hash, "ingest.new", Some(rel_path.clone()))
                .await?;
        }
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
    ///
    /// `block_in_place`: a cross-volume move falls back to a full-file copy
    /// (`publish_no_clobber`) — for a large Flow-delivered video this can run for
    /// seconds, and without this it runs inline on the async runtime the
    /// same way the hash above did (2026-09-07 real-device symptom: desktop
    /// UI froze for the duration).
    fn place(&self, f: &IncomingFile, taken_at_ms: i64) -> Result<String> {
        tokio::task::block_in_place(|| self.place_blocking(f, taken_at_ms))
    }

    fn place_blocking(&self, f: &IncomingFile, taken_at_ms: i64) -> Result<String> {
        // IDX-08 (#1010): traversal cleanup first (last component, `.`/`..`,
        // empty → unnamed.bin), then the target OS's legality policy. The
        // policy never sees a path; POSIX runs with no policy and keeps the
        // old names byte-for-byte.
        let cleaned = sanitize_file_name(&f.file_name);
        let name = match self.file_name_sanitizer {
            Some(sanitize) => sanitize(&cleaned),
            None => cleaned,
        };
        let (yyyy, mm) = year_month(taken_at_ms);
        let dir_rel = format!("originals/{}/{yyyy:04}/{mm:02}", device_dir(&f.src_device));
        let dir_abs = self.library_root.join(&dir_rel);
        fs::create_dir_all(&dir_abs).map_err(|source| IndexError::Io {
            path: dir_abs.clone(),
            source,
        })?;

        let (stem, ext) = split_name(&name);
        // 跨卷（或文件系统不支持硬链接）时才会用到的临时文件，惰性创建、
        // 各候选名共用一份。**只在最终目录里**，所以与最终文件同卷。
        let mut temp: Option<PathBuf> = None;
        for i in 0..10_000u32 {
            let candidate = match (i, ext) {
                (0, _) => name.clone(),
                (_, Some(ext)) => format!("{stem}-{i}.{ext}"),
                (_, None) => format!("{stem}-{i}"),
            };
            let dest = dir_abs.join(&candidate);
            match publish_no_clobber(&f.src_path, &dest, &dir_abs, &mut temp) {
                Ok(()) => {
                    discard_temp(&mut temp);
                    return Ok(format!("{dir_rel}/{candidate}"));
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(source) => {
                    discard_temp(&mut temp);
                    return Err(IndexError::Io { path: dest, source });
                }
            }
        }
        discard_temp(&mut temp);
        Err(IndexError::NameSpaceExhausted(name))
    }

    async fn audit(
        &self,
        ts: i64,
        f: &IncomingFile,
        hash: &[u8; 32],
        kind: &str,
        detail: Option<String>,
    ) -> Result<()> {
        self.db
            .append_audit(&AuditEntry::local(
                ts,
                Some(f.src_device.clone()),
                kind,
                Some(hash.to_vec()),
                detail.map(|d| serde_json::json!({ "detail": d }).to_string()),
            ))
            .await?;
        Ok(())
    }
}

/// EXIF `DateTimeOriginal` (fallback `DateTime`) as unix ms — read via
/// core-media (T-013) — first choice always. DESK-12: when the file has no
/// EXIF, an uploader-supplied capture-time hint (phone MediaStore
/// `DATE_TAKEN`) is preferred over the local file's mtime — Flow-delivered
/// files land via iroh-blobs `export_to`, whose mtime is the export moment,
/// not the original capture moment (screenshots/some videos have no EXIF
/// and were landing in "this month" instead of their real date). The local
/// mtime remains the last-resort fallback for callers with no hint (legacy
/// batch pipeline, local directory watcher) and for a hint of 0 (unknown).
pub(crate) fn taken_at_ms(path: &Path, capture_at_ms_hint: Option<i64>) -> Result<i64> {
    if let Some(ms) = core_media::read_meta(path).taken_at_ms {
        return Ok(ms);
    }
    if let Some(hint) = capture_at_ms_hint {
        if hint > 0 {
            return Ok(hint);
        }
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
pub fn device_dir(node_id: &[u8]) -> String {
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

/// 入库临时文件的命名特征（#1047）：`.ppf-ingest-<随机>.part`。
///
/// 点文件——`collect_files` / watcher 本来就跳过——所以半截内容即使留在
/// `originals/` 里也不会被当成照片收编；启动清理只认这一种名字
/// （[`is_ingest_temp_name`]），绝不按「0 字节」「看起来不完整」之类的
/// 内容特征去猜，因为用户自己放进库里的文件在内容上与它们无法区分。
const INGEST_TEMP_PREFIX: &str = ".ppf-ingest-";
const INGEST_TEMP_SUFFIX: &str = ".part";

/// 文件名是否是入库临时文件（前缀与后缀必须**同时**严格匹配）。
pub(crate) fn is_ingest_temp_name(name: &str) -> bool {
    name.len() > INGEST_TEMP_PREFIX.len() + INGEST_TEMP_SUFFIX.len()
        && name.starts_with(INGEST_TEMP_PREFIX)
        && name.ends_with(INGEST_TEMP_SUFFIX)
}

/// 把 `src` 的内容以 `dest` 为名**不覆盖地**放进目录（#1047）。
///
/// 目标是「`dest` 这个名字一出现，里面就是完整内容」——没有「先占位 0 字节、
/// 再填内容」的窗口，所以进程在任何一刻被杀（SIGKILL / 断电）都不会在
/// `originals/` 里留下占着最终文件名的 0 字节或半截文件：
///
/// 1. `hard_link(src, dest)`：同卷时一步到位。目标已存在则原子地报
///    `AlreadyExists`（调用方换下一个候选名）——和旧的 `create_new` 同样
///    不会被并发入库抢到同一个名字，也不会盖掉用户已有的文件。随后删 `src`；
///    被杀在两步之间只会留下「两份都完整」。
/// 2. 跨卷 / 文件系统不支持硬链接：先把内容复制到**目标目录里**的点文件临时
///    名（半截内容只会出现在这个名字下，源文件此时仍完好，所以启动清理删它
///    不会丢任何数据），再对临时文件做 `hard_link(temp, dest)`。
/// 3. 连硬链接都做不了（FAT/exFAT 一类）：退回 `create_new` 占位 + 同目录
///    rename 覆盖——窗口缩到两次系统调用之间，且内容此刻已完整落在临时文件
///    里，对账看到的至多是一个被 rename 立刻覆盖的占位。
///
/// `temp` 由调用方持有，跨候选名复用，结束时用 [`discard_temp`] 清掉。
fn publish_no_clobber(
    src: &Path,
    dest: &Path,
    dir: &Path,
    temp: &mut Option<PathBuf>,
) -> std::io::Result<()> {
    use std::io::ErrorKind;
    if temp.is_none() {
        match fs::hard_link(src, dest) {
            Ok(()) => return fs::remove_file(src),
            Err(e) if e.kind() == ErrorKind::AlreadyExists => return Err(e),
            // 跨卷 / 不支持硬链接 / 源是不能链接的东西：走临时文件路径。
            Err(_) => {}
        }
    }
    let tmp = match temp {
        Some(t) => t.clone(),
        None => {
            let t = dir.join(format!(
                "{INGEST_TEMP_PREFIX}{}-{}{INGEST_TEMP_SUFFIX}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.as_nanos())
                    .unwrap_or(0)
            ));
            *temp = Some(t.clone());
            fs::copy(src, &t)?;
            // 内容在 rename 之前就要落到介质上，否则断电后可能得到
            // 「名字在、内容是空」。
            fs::File::open(&t)?.sync_all()?;
            t
        }
    };
    match fs::hard_link(&tmp, dest) {
        Ok(()) => {}
        Err(e) if e.kind() == ErrorKind::AlreadyExists => return Err(e),
        Err(_) => {
            // 文件系统不支持硬链接：占位后立刻 rename 覆盖。
            fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(dest)?;
            if let Err(e) = fs::rename(&tmp, dest) {
                let _ = fs::remove_file(dest);
                return Err(e);
            }
            *temp = None;
            return fs::remove_file(src);
        }
    }
    fs::remove_file(&tmp)?;
    *temp = None;
    fs::remove_file(src)
}

fn discard_temp(temp: &mut Option<PathBuf>) {
    if let Some(t) = temp.take() {
        let _ = fs::remove_file(t);
    }
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

#[cfg(test)]
mod publish_tests {
    use super::*;

    fn dirs() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let t = tempfile::tempdir().unwrap();
        let src = t.path().join("src.bin");
        fs::write(&src, b"payload").unwrap();
        let dir = t.path().join("originals");
        fs::create_dir_all(&dir).unwrap();
        (t, src, dir)
    }

    fn listing(dir: &Path) -> Vec<String> {
        let mut v: Vec<String> = fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        v.sort();
        v
    }

    /// 同卷：一步到位，目录里只有最终文件，源被移走。
    #[test]
    fn same_volume_publish_leaves_only_the_final_file() {
        let (_t, src, dir) = dirs();
        let mut temp = None;
        publish_no_clobber(&src, &dir.join("a.jpg"), &dir, &mut temp).unwrap();
        assert!(temp.is_none());
        assert_eq!(listing(&dir), ["a.jpg"]);
        assert_eq!(fs::read(dir.join("a.jpg")).unwrap(), b"payload");
        assert!(!src.exists());
    }

    /// 已存在的名字（用户的文件）绝不被覆盖，源保持原样。
    #[test]
    fn existing_destination_is_never_clobbered() {
        let (_t, src, dir) = dirs();
        fs::write(dir.join("a.jpg"), b"users own").unwrap();
        let mut temp = None;
        let e = publish_no_clobber(&src, &dir.join("a.jpg"), &dir, &mut temp).unwrap_err();
        assert_eq!(e.kind(), std::io::ErrorKind::AlreadyExists);
        assert_eq!(fs::read(dir.join("a.jpg")).unwrap(), b"users own");
        assert!(src.exists());
    }

    /// 跨卷路径（这里强制 `temp` 已存在来走它）：内容先完整落在点文件临时名，
    /// 最终名一出现就是完整内容；完成后临时名消失。
    #[test]
    fn temp_path_publishes_complete_content_and_cleans_up() {
        let (_t, src, dir) = dirs();
        let tmp = dir.join(format!("{INGEST_TEMP_PREFIX}t-1{INGEST_TEMP_SUFFIX}"));
        fs::copy(&src, &tmp).unwrap();
        let mut temp = Some(tmp.clone());
        publish_no_clobber(&src, &dir.join("b.jpg"), &dir, &mut temp).unwrap();
        assert_eq!(listing(&dir), ["b.jpg"]);
        assert_eq!(fs::read(dir.join("b.jpg")).unwrap(), b"payload");
        assert!(temp.is_none() && !tmp.exists() && !src.exists());
    }

    #[test]
    fn temp_name_matcher_is_strict() {
        assert!(is_ingest_temp_name(".ppf-ingest-1-2.part"));
        for bad in [
            ".ppf-ingest-.part",
            ".ppf-ingest-1-2",
            "ppf-ingest-1-2.part",
            ".ppf-ingest-1-2.part.bak",
            "IMG.part",
        ] {
            assert!(!is_ingest_temp_name(bad), "{bad}");
        }
    }
}
