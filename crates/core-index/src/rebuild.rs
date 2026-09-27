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

/// IDX-01: what one orphan-adoption pass did. Deliberately **not**
/// [`RebuildReport`]: after a wipe, "skipped" can only mean "a second
/// on-disk copy of content this very run already indexed"; incrementally
/// it overwhelmingly means "already in the index, nothing to do". Same
/// number, different fact — reusing the field name would make every
/// reader of the hourly report draw the wrong conclusion.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdoptReport {
    /// Files on disk that had no index row and now have one.
    pub adopted: u64,
    /// Files whose content was already indexed — the healthy steady state.
    pub already_indexed: u64,
}

/// Clear the asset table and re-index everything under
/// `<library_root>/originals`. A missing `originals/` yields an empty
/// index, not an error (a fresh library is a valid library). Hidden
/// entries (`.DS_Store`, dotdirs) are skipped. One audit row records the
/// reconciliation with `actor = None` — the filesystem cannot say who.
pub async fn rebuild(db: &Db, library_root: &Path, local_node_id: &[u8]) -> Result<RebuildReport> {
    db.clear_assets().await?;

    let (indexed, duplicates) = index_missing_files(db, library_root, local_node_id).await?;
    let report = RebuildReport {
        indexed,
        duplicates,
    };

    db.append_audit(&AuditEntry::local(
        unix_ms_now(),
        None,
        "index.rebuild",
        None,
        Some(
            serde_json::json!({
                "indexed": report.indexed,
                "duplicates": report.duplicates,
            })
            .to_string(),
        ),
    ))
    .await?;
    Ok(report)
}

/// IDX-01: adopt files that are on disk under `originals/` but have no
/// index row — **without touching the rows that are already there**.
///
/// 这是 ADR-006「originals 是真相」缺失的那一半。`Reconcile`（SYNC-01）
/// 早就在做另一半（行在、文件没了 → 删行），但没有人做「文件在、行没了
/// → 补行」，于是索引一旦丢失，照片就永久看不见——真实事故见 IDX-01 卡。
///
/// 与 [`rebuild`] 共用同一个扫描循环，唯一的差别就是**不清表**：
/// `added_at` / `width` / `height` / `thumb_state` 对现存行一字不动，
/// 所以这个函数可以每小时跑、可以开机跑，而 `rebuild` 不行。
///
/// ⚠️ 安全前提（IDX-01 卡里逐条核实过）：本仓**没有**任何「删索引行但把
/// 文件留在 `originals/` 里」的产品路径——三处删除全部先确认文件已消失。
/// 哪天新增了这种功能（产品级删除/隐藏），这个函数会在下次收编时把它
/// 复活，届时必须先给它接上墓碑判据再继续自动跑。
pub async fn adopt_orphans(
    db: &Db,
    library_root: &Path,
    local_node_id: &[u8],
) -> Result<AdoptReport> {
    let (adopted, already_indexed) = index_missing_files(db, library_root, local_node_id).await?;
    let report = AdoptReport {
        adopted,
        already_indexed,
    };

    // WATCH-07 的噪声纪律：这个函数每小时跑一轮，稳态就是「一条没收」——
    // 那种情况写审计等于每小时刷一行屏。只有真收编了才记。
    if report.adopted > 0 {
        db.append_audit(&AuditEntry::local(
            unix_ms_now(),
            None,
            "index.adopted",
            None,
            Some(
                serde_json::json!({
                    "adopted": report.adopted,
                    "already_indexed": report.already_indexed,
                })
                .to_string(),
            ),
        ))
        .await?;
    }
    Ok(report)
}

/// The scan shared by [`rebuild`] and [`adopt_orphans`]: walk
/// `<library_root>/originals` and insert a row for every file whose
/// content is not indexed yet. Returns `(inserted, skipped)`.
async fn index_missing_files(
    db: &Db,
    library_root: &Path,
    local_node_id: &[u8],
) -> Result<(u64, u64)> {
    let originals = library_root.join("originals");
    let mut files = Vec::new();
    if originals.is_dir() {
        collect_files(&originals, &mut files)?;
    }
    // Lexicographic order makes the duplicate-content winner deterministic.
    files.sort();

    let mut inserted = 0u64;
    let mut skipped = 0u64;
    for path in &files {
        let hash = crate::hash_file(path)?;
        if db.get_asset(&hash).await?.is_some() {
            skipped += 1;
            continue;
        }
        let meta = fs::metadata(path).map_err(|source| IndexError::Io {
            path: path.clone(),
            source,
        })?;
        let rel_path = rel_path_of(library_root, path)?;
        // IDX-03: 与 `ingest.rs` 逐字同一口径的 header-only probe。这里曾经
        // 硬写 `None`，而同一个插入块里的 `taken_at` 是实算的——于是所有经
        // adopt/rebuild 入库的行（手放进 originals/ 的文件、索引丢失后被重新
        // 收编的文件）尺寸永远是 NULL，UI 一路兜成 `0×0`。
        //
        // ⚠️ 这里只补上了两条入库路径中的一条。`ingest` 那条另有一处独立
        // 缺陷：它探的是 `f.src_path`，而 flow 投递给它的是 staging 里那个
        // **没有扩展名**的文件（`flow_delivery.rs` 的 `staged_path`），
        // `image::image_dimensions` 只按扩展名认格式，于是手机推上来的照片
        // 在 ingest 侧同样恒为 NULL。那处不在 IDX-03 范围内，另开卡。
        //
        // 开销（卡面判断 ①）：只在**新插入行**上跑，已在册的行连这段都到不了
        // （上面 `get_asset` 就 continue 了）。而这个循环对每个文件本来就已经
        // 付了一次全文件 `hash_file`，新行还要再付一次 EXIF 解析；只读文件头的
        // probe 比两者都便宜。每小时那一轮的稳态是「一条没收」= 零次 probe。
        let (width, height) = match image::image_dimensions(path) {
            Ok((w, h)) => (Some(i64::from(w)), Some(i64::from(h))),
            // 视频与异体编码本来就没有 header-only 尺寸，诚实记 None——
            // 绝不拿 0 充数：那是个看起来像真数据的假数据。
            Err(_) => (None, None),
        };
        let insert = db
            .insert_asset(&Asset {
                hash: hash.to_vec(),
                rel_path: rel_path.clone(),
                media_type: media_type_for(path),
                bytes: meta.len() as i64,
                taken_at: Some(ingest::taken_at_ms(path, None)?),
                width,
                height,
                src_device: device_of(&rel_path, local_node_id),
                added_at: unix_ms_now(),
                thumb_state: 0,
            })
            .await;
        match insert {
            Ok(()) => inserted += 1,
            // IDX-01: `insert_asset` 撞主键就报错（它的契约是"重复 = 逻辑
            // bug"），对一次性的 rebuild 成立，但 adopt 要和 ingest 长期
            // 并存——`get_asset` 与 insert 之间真有窗口。窗口输了不是错误，
            // 是"别人先落库了"，按跳过处理；**只有确认对方真的落了行才
            // 咽下这个错**，否则原样上抛，不拿竞态当万能借口。
            Err(_) if db.get_asset(&hash).await?.is_some() => skipped += 1,
            Err(e) => return Err(e.into()),
        }
    }
    Ok((inserted, skipped))
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
