//! Query plane (T-033): timeline pages, thumbnails, blob tickets.
//!
//! 契约: `timeline.page` 走 repo; `thumb.get` 缓存命中直读，未生成触发
//! 即时生成（**5 s 超时回内置占位图**，绝不让 UI 干等）; `asset.blob_ticket`
//! 发 iroh-blobs 票据供原图/视频拉取。

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use proto::{AssetMeta, BlobTicketResponse, ThumbGet, ThumbSize, TimelineQuery};
use storage::Db;
use transport::Blobs;

/// The 5 s thumb-generation budget (契约).
const THUMB_BUDGET: Duration = Duration::from_secs(5);

#[derive(Debug, thiserror::Error)]
pub enum QueryError {
    #[error("storage: {0}")]
    Storage(#[from] storage::StorageError),
    #[error("unknown asset")]
    NotFound,
    #[error("blob ticket: {0}")]
    Ticket(String),
}

/// Cloneable query engine; the router holds one.
#[derive(Clone)]
pub struct QueryEngine {
    db: Db,
    blobs: Arc<Blobs>,
    library_root: PathBuf,
    thumbs_root: PathBuf,
}

impl QueryEngine {
    pub fn new(db: Db, blobs: Arc<Blobs>, library_root: impl Into<PathBuf>) -> Self {
        let root = library_root.into();
        Self {
            db,
            blobs,
            thumbs_root: root.join(".ppf/thumbs"),
            library_root: root,
        }
    }

    /// `timeline.page`: keyset pagination straight off the repo.
    pub async fn timeline(&self, q: &TimelineQuery) -> Result<proto::TimelinePage, QueryError> {
        let page = self.db.timeline_page(q.cursor.as_deref(), q.limit).await?;
        Ok(proto::TimelinePage {
            items: page.assets.iter().map(asset_meta).collect(),
            next: page.next_cursor,
        })
    }

    /// `asset.meta`: one asset by hash.
    pub async fn asset_meta(&self, hash_hex: &str) -> Result<AssetMeta, QueryError> {
        let hash = parse_hash(hash_hex).ok_or(QueryError::NotFound)?;
        let asset = self
            .db
            .get_asset(&hash)
            .await?
            .ok_or(QueryError::NotFound)?;
        Ok(asset_meta(&asset))
    }

    /// `thumb.get`: cache hit reads the file; miss generates within the
    /// budget; over-budget (or unknown asset) answers the placeholder —
    /// a grid never blocks on a slow decode.
    pub async fn thumb(&self, t: &ThumbGet) -> Result<Vec<u8>, QueryError> {
        let size = t.size;
        let Some(hash) = parse_hash(&t.hash) else {
            return Ok(media_codec::placeholder_jpeg(size as u32));
        };
        let paths = media_codec::thumb_paths(&self.thumbs_root, &hash);
        let path = match size {
            ThumbSize::S256 => paths.t256.clone(),
            ThumbSize::S1024 => paths.t1024.clone(),
        };
        if let Ok(bytes) = tokio::fs::read(&path).await {
            return Ok(bytes);
        }

        // Miss: the asset must exist; generate on the spot, bounded.
        let Some(asset) = self.db.get_asset(&hash).await? else {
            return Ok(media_codec::placeholder_jpeg(size as u32));
        };
        let src = self.library_root.join(&asset.rel_path);
        let thumbs_root = self.thumbs_root.clone();
        let generate = tokio::task::spawn_blocking(move || {
            media_codec::make_thumbs(&hash, &src, &thumbs_root)
        });
        match tokio::time::timeout(THUMB_BUDGET, generate).await {
            Ok(Ok(result)) => {
                let state = match &result.outcome {
                    media_codec::ThumbOutcome::Generated => 1,
                    media_codec::ThumbOutcome::Placeholder { .. } => 2,
                };
                let _ = self.db.set_thumb_state(&hash, state).await;
                Ok(tokio::fs::read(&path)
                    .await
                    .unwrap_or_else(|_| media_codec::placeholder_jpeg(size as u32)))
            }
            // Budget blown or the task died: placeholder now; the file
            // may still land on disk for the next request.
            _ => Ok(media_codec::placeholder_jpeg(size as u32)),
        }
    }

    /// `asset.blob_ticket`: make the original fetchable and hand out a
    /// ticket. Import is idempotent (content-addressed store).
    pub async fn blob_ticket(&self, hash_hex: &str) -> Result<BlobTicketResponse, QueryError> {
        let hash = parse_hash(hash_hex).ok_or(QueryError::NotFound)?;
        let asset = self
            .db
            .get_asset(&hash)
            .await?
            .ok_or(QueryError::NotFound)?;
        let abs = self.library_root.join(&asset.rel_path);
        let ticket = self
            .blobs
            .push(hash, &abs)
            .await
            .map_err(|e| QueryError::Ticket(e.to_string()))?;
        Ok(BlobTicketResponse { ticket })
    }
}

/// storage 行 → 线上元数据: taken_at ms→s, MIME → "photo"/"video" 粗类.
fn asset_meta(a: &storage::Asset) -> AssetMeta {
    AssetMeta {
        hash: a.hash.iter().map(|b| format!("{b:02x}")).collect(),
        taken_at: a.taken_at.unwrap_or(0) / 1000,
        media_type: if a.media_type.starts_with("video/") {
            "video".into()
        } else {
            "photo".into()
        },
        width: a.width.unwrap_or(0) as u32,
        height: a.height.unwrap_or(0) as u32,
        bytes: a.bytes.max(0) as u64,
    }
}

fn parse_hash(hex: &str) -> Option<[u8; 32]> {
    let hex = hex.trim();
    if hex.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, chunk) in hex.as_bytes().chunks_exact(2).enumerate() {
        let hi = (chunk[0] as char).to_digit(16)?;
        let lo = (chunk[1] as char).to_digit(16)?;
        out[i] = ((hi << 4) | lo) as u8;
    }
    Some(out)
}
