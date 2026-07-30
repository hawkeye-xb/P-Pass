//! ALPN router (T-030): accept inbound ctrl streams, run every request
//! through the authz checkpoint (§2.3), dispatch what's allowed.
//!
//! Denials answer `Resp{err: NOT_AUTHORIZED}` with the precise msg_key,
//! close the stream, and record a `authz.denied` diag event — the
//! self-diagnosis UI and log export feed on those.

use std::time::{SystemTime, UNIX_EPOCH};

use futures_core::Stream;
use proto::msgs::methods;
use proto::{codes, Hello, Req, Resp, RespError, PROTO_VER};
use storage::{Db, DiagEvent};
use transport::{BiStream, Incoming, Transport};

use crate::authz::{self, Decision};

/// Capabilities this daemon ships. Grows with T-033 (thumbnail serving)
/// and later cards; hello advertises it from day one (决策 D 项).
pub const SERVER_CAPABILITIES: &[&str] = &["thumbnail.v1"];

/// The ctrl-plane router: one per daemon process.
#[derive(Clone)]
pub struct Router {
    db: Db,
    device_name: String,
    pairing: Option<crate::pairing::Pairing>,
}

impl Router {
    pub fn new(db: Db, device_name: impl Into<String>) -> Self {
        Self {
            db,
            device_name: device_name.into(),
            pairing: None,
        }
    }

    /// Attach the pairing engine (T-031). Without it, `pair.request`
    /// answers `err.unsupported`.
    pub fn with_pairing(mut self, pairing: crate::pairing::Pairing) -> Self {
        self.pairing = Some(pairing);
        self
    }

    /// Accept-loop over inbound connections. Runs until the transport
    /// closes. Each connection is served on its own task.
    pub async fn serve<T: Transport>(&self, transport: &T) {
        let incoming = transport.listen().await;
        tokio::pin!(incoming);
        while let Some(conn) = next_item(incoming.as_mut()).await {
            let router = self.clone();
            tokio::spawn(async move { router.serve_conn(conn).await });
        }
    }

    /// Serve one connection: streams arrive sequentially; each stream is
    /// one request/response exchange (MVP framing).
    pub async fn serve_conn(&self, conn: Incoming) {
        let peer = conn.peer();
        loop {
            let Ok(mut stream) = conn.accept_bi().await else {
                return; // peer went away — nothing to clean up
            };
            let router = self.clone();
            // Streams are independent; serve each to completion in turn.
            // (Parallel streams per connection can land later if a card
            // needs them — the protocol allows it.)
            if !router.serve_stream(peer, &mut stream).await {
                return;
            }
        }
    }

    /// One request/response on one stream. Returns `false` when the
    /// connection should be dropped (authz denial closes the door).
    async fn serve_stream(&self, peer: transport::NodeId, stream: &mut BiStream) -> bool {
        let req = match stream.recv_frame().await {
            Ok(Some(frame)) => match proto::codec::decode::<Req>(&frame) {
                Ok(req) => req,
                Err(_) => {
                    let resp = Resp::err(
                        String::new(),
                        RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
                    );
                    let _ = self.send(stream, &resp).await;
                    return false;
                }
            },
            _ => return false, // clean finish or broken stream
        };

        let device = match self.db.get_device(&peer.0).await {
            Ok(d) => d,
            Err(e) => {
                tracing::error!("device lookup failed: {e}");
                let resp = Resp::err(
                    req.id.clone(),
                    RespError::new(codes::INTERNAL, diag::keys::ERR_UNSUPPORTED),
                );
                let _ = self.send(stream, &resp).await;
                return false;
            }
        };

        match authz::check(device.as_ref(), &req.method) {
            Decision::Deny { msg_key } => {
                let resp = Resp::err(
                    req.id.clone(),
                    RespError::new(codes::NOT_AUTHORIZED, msg_key),
                );
                let _ = self.send(stream, &resp).await;
                self.record_denial(peer, &req.method, msg_key).await;
                false // 关流 (§2.3: deny closes the connection)
            }
            Decision::Allow => {
                let resp = self.dispatch(peer, &req).await;
                let _ = self.send(stream, &resp).await;
                true
            }
        }
    }

    /// Method dispatch for authorized requests. T-030 ships `hello`,
    /// T-031 adds `pair.request`; every later card plugs in here.
    async fn dispatch(&self, peer: transport::NodeId, req: &Req) -> Resp {
        match req.method.as_str() {
            methods::PAIR_REQUEST => self.handle_pair(peer, req).await,
            methods::HELLO => {
                let ours = Hello {
                    proto_ver: PROTO_VER,
                    capabilities: SERVER_CAPABILITIES.iter().map(|s| s.to_string()).collect(),
                    device_name: self.device_name.clone(),
                };
                match serde_json::to_value(&ours) {
                    Ok(v) => Resp::ok(req.id.clone(), v),
                    Err(_) => Resp::err(
                        req.id.clone(),
                        RespError::new(codes::INTERNAL, diag::keys::ERR_UNSUPPORTED),
                    ),
                }
            }
            // Authorized but not implemented yet (T-031..T-033 land them).
            _ => Resp::err(
                req.id.clone(),
                RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
            ),
        }
    }

    /// `pair.request` (T-031): token check → owner confirmation → device
    /// row → PairAccepted. Every rejection is the same NOT_AUTHORIZED —
    /// a prober learns nothing about which part failed.
    async fn handle_pair(&self, peer: transport::NodeId, req: &Req) -> Resp {
        let Some(pairing) = &self.pairing else {
            return Resp::err(
                req.id.clone(),
                RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
            );
        };
        let Ok(pair_req) = serde_json::from_value::<proto::PairRequest>(req.params.clone()) else {
            return Resp::err(
                req.id.clone(),
                RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
            );
        };
        match pairing.handle_request(peer, &pair_req, unix_ms_now()).await {
            Ok(()) => {
                let accepted = proto::PairAccepted {
                    storage_device_name: self.device_name.clone(),
                };
                match serde_json::to_value(&accepted) {
                    Ok(v) => Resp::ok(req.id.clone(), v),
                    Err(_) => Resp::err(
                        req.id.clone(),
                        RespError::new(codes::INTERNAL, diag::keys::ERR_UNSUPPORTED),
                    ),
                }
            }
            Err(_) => {
                self.record_denial(peer, methods::PAIR_REQUEST, diag::keys::ERR_NOT_AUTHORIZED)
                    .await;
                Resp::err(
                    req.id.clone(),
                    RespError::new(codes::NOT_AUTHORIZED, diag::keys::ERR_NOT_AUTHORIZED),
                )
            }
        }
    }

    async fn send(&self, stream: &mut BiStream, resp: &Resp) -> transport::Result<()> {
        let frame =
            proto::codec::encode(resp).map_err(|e| transport::TransportError::Io(e.to_string()))?;
        stream.send_frame(&frame).await?;
        stream.finish()
    }

    async fn record_denial(&self, peer: transport::NodeId, method: &str, msg_key: &str) {
        let detail =
            format!("{{\"peer\":\"{peer}\",\"method\":\"{method}\",\"msg_key\":\"{msg_key}\"}}",);
        let event = DiagEvent {
            ts: unix_ms_now(),
            kind: "authz.denied".into(),
            detail: Some(detail),
        };
        if let Err(e) = self.db.append_diag(&event).await {
            tracing::error!("diag append failed: {e}");
        }
    }
}

fn unix_ms_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Await one item from a pinned stream (futures-core only, no StreamExt).
async fn next_item<S: Stream>(mut stream: std::pin::Pin<&mut S>) -> Option<S::Item> {
    std::future::poll_fn(|cx| stream.as_mut().poll_next(cx)).await
}
