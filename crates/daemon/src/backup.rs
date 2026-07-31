//! Backup receive pipeline (T-032, 详细设计 §5.1 服务端半边):
//! manifest 查重回 missing → blobs 接收 → ingest → commit 更新水位。
//!
//! Transfer direction is PULL: the storage side fetches exactly the
//! hashes it declared missing, from the announcing device, over the
//! blobs ALPN (施工裁决 — iroh-blobs push is disabled by default and
//! would bypass the ctrl-plane authz; pulling keeps every write under
//! this daemon's control). The client simply serves its files.
//!
//! Idempotency: a manifest can repeat or arrive out of order — missing
//! is always computed against the current index. A commit can be re-run
//! after any interruption: already-ingested content dedups to
//! `Duplicate`, partially fetched blobs resume (iroh-blobs), and the
//! staging file + `create_new` landing in core-index never leave a
//! half-written original.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use core_index::{IncomingFile, Ingestor};
use proto::{BackupItem, BackupManifest, BackupMissing};
use storage::Db;
use transport::Blobs;

/// One device's announced-but-not-yet-committed manifest items.
#[derive(Default)]
struct Session {
    /// hash hex → metadata needed for ingest.
    items: HashMap<String, BackupItem>,
    /// Self-declared dialable address of the uploading device.
    provider: Option<String>,
}

/// The storage-side backup engine. Cloneable; the router holds one.
#[derive(Clone)]
pub struct BackupEngine {
    db: Db,
    ingestor: Ingestor,
    blobs: Arc<Blobs>,
    staging: PathBuf,
    sessions: Arc<Mutex<HashMap<transport::NodeId, Session>>>,
}

/// What a commit did (also serialized into the audit detail).
#[derive(Debug, PartialEq, Eq)]
pub struct CommitOutcome {
    pub ingested: u32,
    pub duplicates: u32,
}

#[derive(Debug, thiserror::Error)]
pub enum BackupError {
    #[error("fetch {hash}: {msg}")]
    Fetch { hash: String, msg: String },
    #[error("ingest {hash}: {msg}")]
    Ingest { hash: String, msg: String },
    #[error("storage: {0}")]
    Storage(#[from] storage::StorageError),
}

impl BackupEngine {
    /// `library_root` is the same root core-index lands originals under;
    /// staging lives beside the index in `.ppf/staging`. `blobs` is the
    /// daemon's ONE store handle — shared with the query engine (two
    /// handles on one store dir would fight over the redb lock).
    pub fn new(db: Db, blobs: Arc<Blobs>, library_root: impl Into<PathBuf>) -> Self {
        let root = library_root.into();
        Self {
            ingestor: Ingestor::new(db.clone(), &root),
            db,
            blobs,
            staging: root.join(".ppf/staging"),
            sessions: Arc::default(),
        }
    }

    /// `backup.begin`: reset the device's session. Idempotent.
    pub fn begin(&self, peer: transport::NodeId) {
        self.sessions
            .lock()
            .expect("sessions lock")
            .insert(peer, Session::default());
    }

    /// `backup.manifest`: record metadata, answer with what's missing.
    /// Repeats and reordering are safe — missing always reflects the
    /// index as it is now.
    pub async fn manifest(
        &self,
        peer: transport::NodeId,
        m: &BackupManifest,
    ) -> Result<BackupMissing, BackupError> {
        let mut missing = Vec::new();
        for item in &m.items {
            let Some(hash) = parse_hash(&item.hash) else {
                continue; // unparseable hash: not fetchable, not missing
            };
            if self.db.get_asset(&hash).await?.is_none() {
                missing.push(item.hash.clone());
            }
        }
        // Bare hashes (no metadata) still get a dedup answer — a client
        // may probe before preparing files. They are not fetchable until
        // a manifest with items arrives.
        for hex in &m.hashes {
            if m.items.iter().any(|i| &i.hash == hex) {
                continue;
            }
            if let Some(hash) = parse_hash(hex) {
                if self.db.get_asset(&hash).await?.is_none() {
                    missing.push(hex.clone());
                }
            }
        }

        let mut sessions = self.sessions.lock().expect("sessions lock");
        let session = sessions.entry(peer).or_default();
        for item in &m.items {
            session.items.insert(item.hash.clone(), item.clone());
        }
        if m.provider.is_some() {
            session.provider = m.provider.clone();
        }
        Ok(BackupMissing { hashes: missing })
    }

    /// `backup.commit`: pull every announced-and-still-missing blob from
    /// the device, ingest it, then advance the device's watermark.
    /// Fully idempotent — re-running after a crash converges.
    pub async fn commit(
        &self,
        peer: transport::NodeId,
        generation: Option<i64>,
    ) -> Result<CommitOutcome, BackupError> {
        let (items, provider): (Vec<BackupItem>, Option<String>) = {
            let sessions = self.sessions.lock().expect("sessions lock");
            sessions
                .get(&peer)
                .map(|s| (s.items.values().cloned().collect(), s.provider.clone()))
                .unwrap_or_default()
        };
        // Self-declared address beats observation — register it so every
        // fetch below dials the uploader directly.
        if let Some(addr) = &provider {
            if let Err(e) = self.blobs.register_peer(addr) {
                tracing::warn!("bad provider address from {peer:?}: {e}");
            }
        }

        std::fs::create_dir_all(&self.staging).ok();
        let mut outcome = CommitOutcome {
            ingested: 0,
            duplicates: 0,
        };
        for item in items {
            let Some(hash) = parse_hash(&item.hash) else {
                continue;
            };
            if self.db.get_asset(&hash).await?.is_some() {
                outcome.duplicates += 1;
                continue; // already in the library — idempotent re-run
            }
            let staged = self.staging.join(&item.hash);
            // Local-first: a phone that pushed over the upload plane
            // (T-054) already put the blob in the store — export straight
            // from disk, zero reverse dials. Fall back to the T-032 pull.
            if self.blobs.export_to(hash, &staged).await.is_err() {
                self.blobs
                    .fetch_from(peer, hash)
                    .await
                    .map_err(|e| BackupError::Fetch {
                        hash: item.hash.clone(),
                        msg: e.to_string(),
                    })?;
                self.blobs
                    .export_to(hash, &staged)
                    .await
                    .map_err(|e| BackupError::Fetch {
                        hash: item.hash.clone(),
                        msg: e.to_string(),
                    })?;
            }
            let incoming = IncomingFile {
                src_path: staged.clone(),
                file_name: item.file_name.clone(),
                media_type: item.media_type.clone(),
                src_device: peer.0.to_vec(),
            };
            match self.ingestor.ingest(&incoming).await {
                Ok(core_index::IngestOutcome::New(_)) => outcome.ingested += 1,
                Ok(core_index::IngestOutcome::Duplicate) => {
                    outcome.duplicates += 1;
                    let _ = std::fs::remove_file(&staged);
                }
                Err(e) => {
                    let _ = std::fs::remove_file(&staged);
                    return Err(BackupError::Ingest {
                        hash: item.hash.clone(),
                        msg: e.to_string(),
                    });
                }
            }
        }

        if let Some(generation) = generation {
            self.db
                .set_watermark(&peer.0, generation, unix_ms_now())
                .await?;
        }
        self.sessions.lock().expect("sessions lock").remove(&peer);
        Ok(outcome)
    }
}

fn unix_ms_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_parsing_rejects_garbage() {
        assert!(parse_hash("short").is_none());
        assert!(parse_hash(&"zz".repeat(32)).is_none());
        assert_eq!(parse_hash(&"0f".repeat(32)), Some([0x0f; 32]));
    }
}
