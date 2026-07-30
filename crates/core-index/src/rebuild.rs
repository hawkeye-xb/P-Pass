//! Rebuild: ADR-006 made executable — wipe the asset table and re-derive
//! every row from the files under `originals/` alone.
//!
//! 契约 (T-012): `rebuild(db, library_root)` 清 asset 表 → 全量重扫入库。
//! Every field of an asset row is recomputed from the tree:
//! `src_device` from the `<deviceId>` directory (full NodeId hex),
//! `taken_at` from EXIF with mtime fallback (same rules as ingest),
//! `media_type` from the file extension. Files that a user dropped in by
//! hand (outside the canonical `<deviceId>/<yyyy>/<mm>/` layout) are
//! indexed too, with an empty `src_device` — origin unknown, recorded
//! honestly (审计裁决 2026-07-29: external changes are detected, not
//! attributed).
//!
//! Known, accepted drift vs. the original ingest: a client-provided MIME
//! type that disagrees with the file extension is not recoverable, and
//! `added_at` is the rebuild time — both are index metadata, not content
//! truth.

use std::fs;
use std::path::{Path, PathBuf};

use storage::{Asset, AuditEntry, Db};

use crate::{ingest, IndexError, Result};

/// What a rebuild did. `duplicates` counts extra on-disk copies of content
/// already indexed this run — the first path (lexicographic) wins the row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RebuildReport {
    pub indexed: u64,
    pub duplicates: u64,
}

/// Clear the asset table and re-index everything under
/// `<library_root>/originals`. A missing `originals/` yields an empty
/// index, not an error (a fresh library is a valid library). Hidden
/// entries (`.DS_Store`, dotdirs) are skipped. One audit row records the
/// reconciliation with `actor = None` — the filesystem cannot say who.
pub async fn rebuild(db: &Db, library_root: &Path) -> Result<RebuildReport> {
    db.clear_assets().await?;

    let originals = library_root.join("originals");
    let mut files = Vec::new();
    if originals.is_dir() {
        collect_files(&originals, &mut files)?;
    }
    // Lexicographic order makes the duplicate-content winner deterministic.
    files.sort();

    let mut report = RebuildReport {
        indexed: 0,
        duplicates: 0,
    };
    for path in &files {
        let hash = crate::hash_file(path)?;
        if db.get_asset(&hash).await?.is_some() {
            report.duplicates += 1;
            continue;
        }
        let meta = fs::metadata(path).map_err(|source| IndexError::Io {
            path: path.clone(),
            source,
        })?;
        let rel_path = rel_path_of(library_root, path)?;
        db.insert_asset(&Asset {
            hash: hash.to_vec(),
            rel_path: rel_path.clone(),
            media_type: media_type_for(path),
            bytes: meta.len() as i64,
            taken_at: Some(ingest::taken_at_ms(path)?),
            width: None,
            height: None,
            src_device: device_of(&rel_path),
            added_at: unix_ms_now(),
            thumb_state: 0,
        })
        .await?;
        report.indexed += 1;
    }

    db.append_audit(&AuditEntry {
        ts: unix_ms_now(),
        actor: None,
        action: "index.rebuild".into(),
        target_hash: None,
        detail: Some(format!(
            "indexed={} duplicates={}",
            report.indexed, report.duplicates
        )),
    })
    .await?;
    Ok(report)
}

/// Depth-first listing of regular files, skipping hidden names.
fn collect_files(dir: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    let io_err = |source| IndexError::Io {
        path: dir.to_path_buf(),
        source,
    };
    for entry in fs::read_dir(dir).map_err(io_err)? {
        let entry = entry.map_err(io_err)?;
        if entry.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        let path = entry.path();
        let kind = entry.file_type().map_err(io_err)?;
        if kind.is_dir() {
            collect_files(&path, out)?;
        } else if kind.is_file() {
            out.push(path);
        }
    }
    Ok(())
}

/// Library-relative path with `/` separators on every platform — the form
/// stored in `asset.rel_path`.
fn rel_path_of(root: &Path, path: &Path) -> Result<String> {
    let rel = path.strip_prefix(root).map_err(|_| IndexError::Io {
        path: path.to_path_buf(),
        source: std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "file is outside the library root",
        ),
    })?;
    Ok(rel
        .components()
        .map(|c| c.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/"))
}

/// `src_device` back out of `originals/<deviceId>/…`: the full 64-hex-char
/// directory decodes to the 32-byte NodeId. Anything else (hand-dropped
/// files, foreign layouts) gets an empty id — unknown origin.
fn device_of(rel_path: &str) -> Vec<u8> {
    let dir = rel_path.split('/').nth(1).unwrap_or_default();
    if dir.len() != 64 {
        return Vec::new();
    }
    let mut id = Vec::with_capacity(32);
    let b = dir.as_bytes();
    for i in (0..64).step_by(2) {
        let Ok(byte) = u8::from_str_radix(std::str::from_utf8(&b[i..i + 2]).unwrap_or(""), 16)
        else {
            return Vec::new();
        };
        id.push(byte);
    }
    id
}

/// MIME from extension — the media types this product stores. Unknown
/// extensions are honest `application/octet-stream`, never a guess.
fn media_type_for(path: &Path) -> String {
    let ext = path
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "heic" | "heif" => "image/heic",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "mp4" => "video/mp4",
        "mov" => "video/quicktime",
        _ => "application/octet-stream",
    }
    .into()
}

fn unix_ms_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_of_decodes_full_node_id() {
        let hex = "ab".repeat(32);
        assert_eq!(
            device_of(&format!("originals/{hex}/2026/07/a.jpg")),
            vec![0xab; 32]
        );
    }

    #[test]
    fn device_of_rejects_non_canonical_dirs() {
        // Too short, not hex, or missing entirely → unknown origin.
        assert_eq!(device_of("originals/abcd/2026/07/a.jpg"), Vec::<u8>::new());
        let not_hex = "zz".repeat(32);
        assert_eq!(
            device_of(&format!("originals/{not_hex}/a.jpg")),
            Vec::<u8>::new()
        );
        assert_eq!(device_of("originals"), Vec::<u8>::new());
    }

    #[test]
    fn media_type_covers_product_formats() {
        assert_eq!(media_type_for(Path::new("a/B.JPG")), "image/jpeg");
        assert_eq!(media_type_for(Path::new("a/b.heic")), "image/heic");
        assert_eq!(media_type_for(Path::new("a/b.mov")), "video/quicktime");
        assert_eq!(
            media_type_for(Path::new("a/noext")),
            "application/octet-stream"
        );
    }
}
