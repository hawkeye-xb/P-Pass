//! Download plane (T-056): the phone asks for an asset's original
//! bytes (video playback, save-to-phone) over `ppf/download/1` — one
//! asset per bidirectional stream, gated by the same authz checkpoint
//! (viewer+: downloading IS browsing).
//!
//! Stream shape (mirror of the upload plane):
//!   client:  Req{method: "asset.download", params: {"hash": <hex64>}}
//!   daemon:  Resp{ok, result: {"bytes": n}}  — then the raw bytes, then EOF
//! Errors answer a Resp with ok=false and no bytes follow.

use std::path::PathBuf;

use proto::msgs::methods;
use proto::{codes, Req, Resp, RespError};
use storage::Db;
use transport::Incoming;

use crate::authz;

#[derive(Clone)]
pub struct DownloadPlane {
    db: Db,
    library_root: PathBuf,
}

impl DownloadPlane {
    pub fn new(db: Db, library_root: PathBuf) -> Self {
        Self { db, library_root }
    }

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
        let device = match self.db.get_device(&peer.0).await {
            Ok(d) => d,
            Err(_) => return false,
        };
        if let authz::Decision::Deny { msg_key } =
            authz::check(device.as_ref(), methods::ASSET_DOWNLOAD)
        {
            let resp = Resp::err(
                String::new(),
                RespError::new(codes::NOT_AUTHORIZED, msg_key),
            );
            let _ = self.send(stream, &resp).await;
            return false;
        }

        let hash_hex = match stream.recv_frame().await {
            Ok(Some(frame)) => match proto::codec::decode::<Req>(&frame) {
                Ok(req) => req.params["hash"].as_str().unwrap_or_default().to_string(),
                Err(_) => return self.reject(stream, "err.unsupported").await,
            },
            _ => return false,
        };
        let Some(hash) = parse_hash(&hash_hex) else {
            return self.reject(stream, "err.unsupported").await;
        };

        let asset = match self.db.get_asset(&hash).await {
            Ok(Some(a)) => a,
            Ok(None) => return self.reject(stream, "err.not_found").await,
            Err(_) => return self.reject(stream, "err.internal").await,
        };
        let path = self.library_root.join(&asset.rel_path);
        let Ok(file) = std::fs::File::open(&path) else {
            tracing::warn!("download {hash_hex}: file missing at {path:?}");
            return self.reject(stream, "err.not_found").await;
        };
        let bytes = file.metadata().map(|m| m.len()).unwrap_or(0);

        let head = Resp::ok(String::new(), serde_json::json!({ "bytes": bytes }));
        if !self.send(stream, &head).await {
            return false;
        }

        // Stream the file in chunks; a broken pipe just ends this stream.
        use std::io::Read;
        let mut reader = std::io::BufReader::new(file);
        let mut buf = vec![0u8; 256 * 1024];
        loop {
            let n = match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => n,
                Err(_) => return false,
            };
            if stream.send_frame(&buf[..n]).await.is_err() {
                return false; // peer went away mid-stream
            }
        }
        let _ = stream.finish();
        tracing::info!("download served: {hash_hex} ({bytes} bytes)");
        true
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
