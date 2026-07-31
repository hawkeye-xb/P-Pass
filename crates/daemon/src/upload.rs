//! Upload plane (T-054): the phone pushes file bytes over
//! `ppf/upload/1`, one file per bidirectional stream — an
//! [`UploadHeader`] frame, then raw bytes, then a [`Resp`] frame back.
//!
//! Security shape: this is a GATED push. Every connection passes the
//! same authz checkpoint as the ctrl plane (pseudo-method
//! `backup.upload`, granted to member+ via the `backup.` prefix). The
//! received bytes must hash to the declared BLAKE3 before the blob
//! store accepts them — a lying uploader gets an error, not storage.

use std::path::PathBuf;
use std::sync::Arc;

use proto::msgs::{methods, UploadHeader};
use proto::{codes, Req, Resp, RespError};
use storage::Db;
use transport::{Blobs, Incoming};

use crate::authz;

/// Upper bound per file — matches the design's "4 GB video" hardening
/// scenario (T-070 exercises the edge).
const MAX_UPLOAD_BYTES: u64 = 8 * 1024 * 1024 * 1024;

#[derive(Clone)]
pub struct UploadPlane {
    db: Db,
    blobs: Arc<Blobs>,
    staging: PathBuf,
}

impl UploadPlane {
    pub fn new(db: Db, blobs: Arc<Blobs>, staging: PathBuf) -> Self {
        Self { db, blobs, staging }
    }

    /// Serve one upload connection: streams arrive sequentially, one
    /// file each. Authz is checked per stream (revocation mid-batch
    /// slams the door on the next file).
    pub async fn serve_conn(&self, conn: Incoming) {
        let peer = conn.peer();
        loop {
            let Ok(mut stream) = conn.accept_bi().await else {
                return;
            };
            let plane = self.clone();
            if !plane.serve_stream(peer, &mut stream).await {
                return;
            }
        }
    }

    async fn serve_stream(
        &self,
        peer: transport::NodeId,
        stream: &mut transport::BiStream,
    ) -> bool {
        // ── Authz checkpoint (same gate as ctrl) ──
        let device = match self.db.get_device(&peer.0).await {
            Ok(d) => d,
            Err(_) => return false,
        };
        if let authz::Decision::Deny { msg_key } =
            authz::check(device.as_ref(), methods::BACKUP_UPLOAD)
        {
            let resp = Resp::err(
                String::new(),
                RespError::new(codes::NOT_AUTHORIZED, msg_key),
            );
            let _ = self.send(stream, &resp).await;
            return false;
        }

        // ── Header frame ──
        let header: UploadHeader = match stream.recv_frame().await {
            Ok(Some(frame)) => match proto::codec::decode::<Req>(&frame) {
                // The phone wraps the header in the Req envelope so the
                // stream opens with the same shape as every other plane.
                Ok(req) => match serde_json::from_value(req.params) {
                    Ok(h) => h,
                    Err(_) => return self.reject(stream, "err.unsupported").await,
                },
                Err(_) => return self.reject(stream, "err.unsupported").await,
            },
            _ => return false, // clean finish or broken stream
        };
        if header.bytes > MAX_UPLOAD_BYTES || header.hash.len() != 64 {
            return self.reject(stream, "err.unsupported").await;
        }

        // ── Raw bytes → staging file (streamed, never in memory) ──
        std::fs::create_dir_all(&self.staging).ok();
        let staged = self.staging.join(format!("{}.upload", header.hash));
        let outcome = self.receive_file(stream, &header, &staged).await;

        match outcome {
            Ok(()) => {
                let resp = Resp::ok(String::new(), serde_json::json!({"stored": header.hash}));
                let _ = self.send(stream, &resp).await;
                true
            }
            Err(msg_key) => {
                let _ = std::fs::remove_file(&staged);
                self.reject(stream, msg_key).await
            }
        }
    }

    /// Stream bytes to disk, verify BLAKE3, hand to the blob store.
    async fn receive_file(
        &self,
        stream: &mut transport::BiStream,
        header: &UploadHeader,
        staged: &std::path::Path,
    ) -> Result<(), &'static str> {
        use std::io::Write;
        let mut file = std::fs::File::create(staged).map_err(|_| "err.internal")?;
        let mut hasher = blake3::Hasher::new();
        let mut received: u64 = 0;
        loop {
            match stream.recv_chunk(256 * 1024).await {
                Ok(Some(chunk)) => {
                    received += chunk.len() as u64;
                    if received > header.bytes {
                        return Err("err.unsupported"); // more than declared
                    }
                    hasher.update(&chunk);
                    file.write_all(&chunk).map_err(|_| "err.internal")?;
                }
                Ok(None) => break,
                Err(_) => return Err("err.internal"),
            }
        }
        file.flush().map_err(|_| "err.internal")?;
        drop(file);

        if received != header.bytes {
            tracing::warn!(
                "upload {}: declared {} bytes, received {received}",
                header.hash,
                header.bytes
            );
            return Err("err.unsupported");
        }
        let got = hasher.finalize();
        let Some(expected) = parse_hash(&header.hash) else {
            return Err("err.unsupported");
        };
        if got.as_bytes() != &expected {
            tracing::warn!("upload {}: content hash mismatch", header.hash);
            return Err("err.unsupported");
        }

        // Into the blob store (push re-verifies the hash internally).
        self.blobs
            .push(expected, staged)
            .await
            .map_err(|_| "err.internal")?;
        let _ = std::fs::remove_file(staged);
        tracing::info!(
            "upload accepted: {} ({} bytes, {})",
            header.hash,
            header.bytes,
            header.file_name
        );
        Ok(())
    }

    async fn reject(&self, stream: &mut transport::BiStream, msg_key: &'static str) -> bool {
        let resp = Resp::err(
            String::new(),
            RespError::new(codes::INVALID_REQUEST, msg_key),
        );
        let _ = self.send(stream, &resp).await;
        false
    }

    async fn send(&self, stream: &mut transport::BiStream, resp: &Resp) -> bool {
        match proto::codec::encode(resp) {
            Ok(frame) => stream.send_frame(&frame).await.is_ok(),
            Err(_) => false,
        }
    }
}

fn parse_hash(hex: &str) -> Option<[u8; 32]> {
    if hex.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(out)
}
