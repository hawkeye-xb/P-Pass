//! Download plane (T-056): the phone asks for an asset's original
//! bytes (video playback, save-to-phone) over `ppf/download/1` — one
//! asset per bidirectional stream, gated by the same authz checkpoint
//! (viewer+: downloading IS browsing).
//!
//! Stream shape (header frame, then raw bytes; the old upload plane was removed in #988):
//!   client:  Req{method: "asset.download", params: {"hash": <hex64>}}
//!   daemon:  Resp{ok, result: {"bytes": n}}  — then the raw bytes, then EOF
//! Errors answer a Resp with ok=false and no bytes follow.
//!
//! #1070: the request header is read first so its protocol version is
//! checked before authz — an incompatible phone is told to update and
//! nothing is read or written.

use std::path::PathBuf;

use proto::msgs::methods;
use proto::{Reason, Req, Resp, RespError};
use storage::Db;
use transport::Incoming;

use crate::authz;
use crate::router::OutdatedPeers;

#[derive(Clone)]
pub struct DownloadPlane {
    db: Db,
    library_root: PathBuf,
}

impl DownloadPlane {
    pub fn new(db: Db, library_root: PathBuf) -> Self {
        Self { db, library_root }
    }

    /// `outdated` is the router's version-mismatch registry (#1070).
    pub async fn serve_conn(&self, conn: Incoming, outdated: &OutdatedPeers) {
        let peer = conn.peer();
        loop {
            let Ok(mut stream) = conn.accept_bi().await else {
                return;
            };
            let plane = self.clone();
            if !plane.serve_stream(peer, &mut stream, outdated).await {
                return;
            }
        }
    }

    async fn serve_stream(
        &self,
        peer: transport::NodeId,
        stream: &mut transport::BiStream,
        outdated: &OutdatedPeers,
    ) -> bool {
        // #1122：下载请求只带一个 hash，几百字节足够。
        let req = match stream
            .recv_frame_max(crate::frame_limits::PAIRING_FRAME_MAX)
            .await
        {
            Ok(Some(frame)) => match proto::codec::decode::<Req>(&frame) {
                Ok(req) => req,
                Err(_) => return self.reject(stream, Reason::BadRequest).await,
            },
            _ => return false,
        };
        if let Err(error) = outdated.check(peer, &req) {
            let _ = self.send(stream, &Resp::err(String::new(), error)).await;
            return false;
        }

        let pairing = self.db.active_pairing(&peer.0);
        if let authz::Decision::Deny { reason } =
            authz::check(pairing.as_ref(), methods::ASSET_DOWNLOAD)
        {
            return self.reject(stream, reason).await;
        }

        let hash_hex = req.params["hash"].as_str().unwrap_or_default().to_string();
        let Some(hash) = parse_hash(&hash_hex) else {
            return self.reject(stream, Reason::BadRequest).await;
        };

        let asset = match self.db.get_asset(&hash).await {
            Ok(Some(a)) => a,
            Ok(None) => return self.reject(stream, Reason::NotFound).await,
            Err(_) => return self.reject(stream, Reason::Internal).await,
        };
        let path = self.library_root.join(&asset.rel_path);
        let Ok(file) = std::fs::File::open(&path) else {
            tracing::warn!("download {hash_hex}: file missing at {path:?}");
            return self.reject(stream, Reason::NotFound).await;
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

    async fn reject(&self, stream: &mut transport::BiStream, reason: Reason) -> bool {
        let resp = Resp::err(String::new(), RespError::new(reason));
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
