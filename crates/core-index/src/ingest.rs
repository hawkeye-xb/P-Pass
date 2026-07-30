//! Ingest: hash → dedup → land under `originals/` → index row → audit.
//!
//! 契约 (T-011): `ingest(IncomingFile) -> IngestOutcome{New(rel_path)|Duplicate}`.
//! EXIF `DateTimeOriginal` is the timeline key; missing EXIF falls back to
//! the file's mtime. Every ingest is audited to device granularity
//! (审计裁决 2026-07-29).

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use storage::{Asset, AuditEntry, Db};
use time::{Date, Month, OffsetDateTime, PrimitiveDateTime, Time};

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
    /// Content already in the library — nothing was written.
    Duplicate,
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

        let bytes = fs::metadata(&f.src_path)
            .map_err(|source| IndexError::Io {
                path: f.src_path.clone(),
                source,
            })?
            .len() as i64;
        let taken_at = taken_at_ms(&f.src_path)?;
        let rel_path = self.place(f, taken_at)?;

        let asset = Asset {
            hash: hash.to_vec(),
            rel_path: rel_path.clone(),
            media_type: f.media_type.clone(),
            bytes,
            taken_at: Some(taken_at),
            width: None,
            height: None,
            src_device: f.src_device.clone(),
            added_at: now_ms,
            thumb_state: 0,
        };
        if let Err(e) = self.db.insert_asset(&asset).await {
            // The file is already moved; roll it back out of the library
            // so index and originals never disagree.
            let _ = fs::remove_file(self.library_root.join(&rel_path));
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

/// EXIF `DateTimeOriginal` (fallback `DateTime`) as unix ms; if the file
/// has no usable EXIF, the file's mtime. EXIF wall clock carries no zone —
/// it is interpreted as UTC so the key is stable across machines.
pub(crate) fn taken_at_ms(path: &Path) -> Result<i64> {
    if let Some(ms) = exif_taken_at_ms(path) {
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

fn exif_taken_at_ms(path: &Path) -> Option<i64> {
    let file = fs::File::open(path).ok()?;
    let mut reader = std::io::BufReader::new(file);
    let meta = exif::Reader::new().read_from_container(&mut reader).ok()?;
    let field = meta
        .get_field(exif::Tag::DateTimeOriginal, exif::In::PRIMARY)
        .or_else(|| meta.get_field(exif::Tag::DateTime, exif::In::PRIMARY))?;
    let raw = match &field.value {
        exif::Value::Ascii(v) => v.first()?,
        _ => return None,
    };
    let dt = exif::DateTime::from_ascii(raw).ok()?;
    let date =
        Date::from_calendar_date(i32::from(dt.year), Month::try_from(dt.month).ok()?, dt.day)
            .ok()?;
    let tod = Time::from_hms(dt.hour, dt.minute, dt.second).ok()?;
    Some(
        PrimitiveDateTime::new(date, tod)
            .assume_utc()
            .unix_timestamp()
            * 1000,
    )
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
