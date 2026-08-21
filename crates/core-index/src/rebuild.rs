//! Rebuild: ADR-006 made executable — wipe the asset table and re-derive
//! every row from the files under `originals/` alone.
//!
//! 契约 (T-012): `rebuild(db, library_root, local_node_id)` 清 asset 表 →
//! 全量重扫入库。
//! Every field of an asset row is recomputed from the tree:
//! `src_device` from the `<deviceId>` directory (full NodeId hex), falling
//! back to **本机** for anything outside that layout,
//! `taken_at` from EXIF with mtime fallback (same rules as ingest),
//! `media_type` from the file extension.
//!
//! 用户手放的文件（不在 canonical `<deviceId>/<yyyy>/<mm>/` 布局里）照样
//! 入索引，`src_device` = **本机**（2026-08-21 用户裁决）。
//!
//! 为什么是本机而不是空：这类文件没有走过我们的上传协议，它出现在库里
//! 只能是有人用本机的文件系统权限放进去的——归本机是诚实的推断，而且
//! **这条规则目录树自己就能重现**（重建总在本机上跑，本机身份现成），
//! 所以 ADR-006「光靠目录树就能完整重建索引」这条铁律不用破。空值更
//! 保守，但会让「只看我的 / 只看家人的」筛选器算不出归属、把照片藏起来
//! ——对家庭相册来说那是更坏的结果。
//!
//! ⚠️ 要记账的漂移：把整个库搬到**新机器**上重建，这些文件会被归到新
//! 机器名下。内容与时间线不受影响，只影响「谁的照片」这一栏。
//!
//! 归属口径必须与 `ingest` 一致（watcher 发现库内文件时传的 src_device
//! 就是本机 node_id）——严格入库 + 宽容重建的话，重建一次库的语义就变了。
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
pub async fn rebuild(db: &Db, library_root: &Path, local_node_id: &[u8]) -> Result<RebuildReport> {
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
            src_device: device_of(&rel_path, local_node_id),
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
/// directory decodes to the 32-byte NodeId. Anything else（用户手放的文件、
/// 外来布局）归 **本机**——见模块注释的裁决与理由。
fn device_of(rel_path: &str, local_node_id: &[u8]) -> Vec<u8> {
    let dir = rel_path.split('/').nth(1).unwrap_or_default();
    if dir.len() != 64 {
        return local_node_id.to_vec();
    }
    let mut id = Vec::with_capacity(32);
    let b = dir.as_bytes();
    for i in (0..64).step_by(2) {
        let Ok(byte) = u8::from_str_radix(std::str::from_utf8(&b[i..i + 2]).unwrap_or(""), 16)
        else {
            return local_node_id.to_vec();
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

    const LOCAL: [u8; 32] = [0xcc; 32];

    #[test]
    fn device_of_decodes_full_node_id() {
        let hex = "ab".repeat(32);
        assert_eq!(
            device_of(&format!("originals/{hex}/2026/07/a.jpg"), &LOCAL),
            vec![0xab; 32],
            "canonical 布局：设备身份从目录名解码，不受本机身份影响"
        );
    }

    #[test]
    fn device_of_falls_back_to_local_outside_the_canonical_layout() {
        // 太短、非 hex、或压根没有子目录 → 归本机（2026-08-21 裁决）。
        for rel in [
            "originals/abcd/2026/07/a.jpg",
            "originals/我的婚礼/a.jpg",
            "originals/dropped.jpg",
            "originals",
        ] {
            assert_eq!(device_of(rel, &LOCAL), LOCAL.to_vec(), "rel = {rel}");
        }
        let not_hex = "zz".repeat(32);
        assert_eq!(
            device_of(&format!("originals/{not_hex}/a.jpg"), &LOCAL),
            LOCAL.to_vec(),
            "长度对但不是 hex 也归本机"
        );
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
