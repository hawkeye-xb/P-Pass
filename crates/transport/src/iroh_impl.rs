//! iroh-backed implementation of the [`Transport`] trait (ADR-001).
//!
//! All iroh types stay private to this module; the public surface exposes
//! only opaque wrappers ([`PeerAddr`], [`Incoming`], [`BiStream`]).

use std::collections::HashMap;
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};

use iroh::endpoint::{presets, Connection, ReadExactError, RecvStream, SendStream};
use iroh::{Endpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, SecretKey, TransportAddr};

use crate::conninfo::{classify, ConnInfo, PathFacts};
use crate::{NodeId, Result, Transport, TransportError, MAX_FRAME};

/// Construction inputs, mapped from the daemon `Config` (T-004): the daemon
/// passes `Config.relay_urls` in here. Address lookup (发现) stays on n0
/// public infrastructure for MVP per ADR-009 (Phase 2: self-hosted pkarr);
/// `Config.rendezvous_url` belongs to the pairing flow (T-031), not here.
#[derive(Debug, Clone)]
pub struct TransportConfig {
    /// Custom relay servers. Empty = n0 default relays (when `n0_services`
    /// is on) or fully relay-less (when off).
    pub relay_urls: Vec<String>,
    /// Use n0 public infrastructure defaults (relays + address lookup).
    /// Off = offline mode: only peers registered via [`IrohTransport::add_peer`]
    /// are reachable — what tests and LAN-only setups need.
    pub n0_services: bool,
    /// Stable identity key (32 bytes). `None` = fresh ephemeral key.
    pub secret_key: Option<[u8; 32]>,
    /// ALPNs accepted when listening (e.g. [`crate::ALPN_CTRL`]).
    pub alpns: Vec<String>,
    /// UDP bind address. `None` = OS-assigned port.
    pub bind_addr: Option<SocketAddr>,
}

impl TransportConfig {
    /// Production shape: endpoints from the daemon config (T-004).
    pub fn from_endpoints(relay_urls: Vec<String>, alpns: Vec<String>) -> Self {
        Self {
            relay_urls,
            n0_services: true,
            secret_key: None,
            alpns,
            bind_addr: None,
        }
    }

    /// Offline loopback shape: no relays, no address lookup, random port.
    /// Fully self-contained — CI runs this without network access.
    pub fn loopback(alpns: Vec<String>) -> Self {
        Self {
            relay_urls: Vec::new(),
            n0_services: false,
            secret_key: None,
            alpns,
            bind_addr: None,
        }
    }
}

/// Opaque peer address bundle (identity key + direct addresses + relay URL).
/// Obtained from [`IrohTransport::local_addr`] and handed to the other side —
/// in-process for now; pairing tickets serialize this in T-031.
#[derive(Debug, Clone)]
pub struct PeerAddr(EndpointAddr);

impl PeerAddr {
    pub fn node_id(&self) -> NodeId {
        NodeId(*self.0.id.as_bytes())
    }
}

/// The iroh transport: one QUIC endpoint plus bookkeeping for
/// [`Transport::conn_info`] lookups.
#[derive(Clone)]
pub struct IrohTransport {
    ep: Endpoint,
    /// Peer address book, fed by [`Self::add_peer`] (pairing/tickets).
    peers: Arc<Mutex<HashMap<NodeId, EndpointAddr>>>,
    /// Live connections per peer — latest wins. Sole consumer: `conn_info`.
    conns: Arc<Mutex<HashMap<NodeId, Connection>>>,
}

impl IrohTransport {
    pub async fn bind(cfg: TransportConfig) -> Result<Self> {
        let mut builder = if cfg.n0_services {
            Endpoint::builder(presets::N0)
        } else {
            Endpoint::builder(presets::Minimal)
        };

        if !cfg.relay_urls.is_empty() {
            let urls = cfg
                .relay_urls
                .iter()
                .map(|u| u.parse::<RelayUrl>())
                .collect::<std::result::Result<Vec<_>, _>>()
                .map_err(|e| TransportError::Bind(format!("invalid relay url: {e}")))?;
            builder = builder.relay_mode(RelayMode::custom(urls));
        }
        if let Some(bytes) = cfg.secret_key {
            builder = builder.secret_key(SecretKey::from_bytes(&bytes));
        }
        if let Some(addr) = cfg.bind_addr {
            builder = builder
                .bind_addr(addr)
                .map_err(|e| TransportError::Bind(e.to_string()))?;
        }

        let alpns = cfg.alpns.iter().map(|a| a.as_bytes().to_vec()).collect();
        let ep = builder
            .alpns(alpns)
            .bind()
            .await
            .map_err(|e| TransportError::Bind(e.to_string()))?;

        Ok(Self {
            ep,
            peers: Arc::default(),
            conns: Arc::default(),
        })
    }

    pub fn node_id(&self) -> NodeId {
        NodeId(*self.ep.id().as_bytes())
    }

    /// Our address bundle, for handing to a peer.
    pub fn local_addr(&self) -> PeerAddr {
        PeerAddr(self.ep.addr())
    }

    /// Register a peer's address bundle; returns its [`NodeId`] for use
    /// with [`Transport::connect`].
    pub fn add_peer(&self, addr: PeerAddr) -> NodeId {
        let id = addr.node_id();
        self.peers.lock().expect("peers lock").insert(id, addr.0);
        id
    }

    /// Gracefully close the endpoint (flushes connection close frames).
    pub async fn close(&self) {
        self.ep.close().await;
    }
}

impl Transport for IrohTransport {
    /// Spawns an accept loop and yields handshake-complete connections.
    /// Intended to be called once by the daemon's serve loop.
    async fn listen(&self) -> impl futures_core::Stream<Item = Incoming> {
        let (tx, rx) = tokio::sync::mpsc::channel(16);
        let ep = self.ep.clone();
        let conns = Arc::clone(&self.conns);

        tokio::spawn(async move {
            while let Some(incoming) = ep.accept().await {
                let Ok(mut accepting) = incoming.accept() else {
                    continue;
                };
                let tx = tx.clone();
                let conns = Arc::clone(&conns);
                // Finish each handshake off the accept loop so one slow
                // client cannot stall the others.
                tokio::spawn(async move {
                    let Ok(alpn) = accepting.alpn().await else {
                        return;
                    };
                    let Ok(conn) = accepting.await else {
                        return;
                    };
                    let peer = NodeId(*conn.remote_id().as_bytes());
                    conns.lock().expect("conns lock").insert(peer, conn.clone());
                    let alpn = String::from_utf8_lossy(&alpn).into_owned();
                    let _ = tx.send(Incoming { peer, alpn, conn }).await;
                });
            }
        });

        IncomingStream { rx }
    }

    async fn connect(&self, peer: NodeId, alpn: &str) -> Result<BiStream> {
        let known = self.peers.lock().expect("peers lock").get(&peer).cloned();
        let addr = match known {
            Some(a) => a,
            // Not in the address book: fall back to identity-only dialing,
            // which needs address lookup services to resolve.
            None => EndpointAddr::from(endpoint_id(peer)?),
        };

        let conn =
            self.ep
                .connect(addr, alpn.as_bytes())
                .await
                .map_err(|e| TransportError::Connect {
                    peer,
                    reason: e.to_string(),
                })?;
        self.conns
            .lock()
            .expect("conns lock")
            .insert(peer, conn.clone());

        let (send, recv) = conn
            .open_bi()
            .await
            .map_err(|e| TransportError::Io(e.to_string()))?;
        Ok(BiStream { send, recv })
    }

    fn conn_info(&self, peer: NodeId) -> ConnInfo {
        let conns = self.conns.lock().expect("conns lock");
        let Some(conn) = conns.get(&peer) else {
            return ConnInfo::NONE;
        };
        if conn.close_reason().is_some() {
            return ConnInfo::NONE;
        }
        let facts: Vec<PathFacts> = conn
            .paths()
            .iter()
            .map(|p| PathFacts {
                selected: p.is_selected(),
                relay: p.is_relay(),
                remote_ip: match p.remote_addr() {
                    TransportAddr::Ip(sa) => Some(sa.ip()),
                    _ => None,
                },
                rtt: p.rtt(),
            })
            .collect();
        classify(&facts)
    }
}

fn endpoint_id(id: NodeId) -> Result<EndpointId> {
    EndpointId::from_bytes(&id.0).map_err(|_| TransportError::InvalidNodeId)
}

/// Stream of inbound connections, backed by the accept-loop channel.
pub struct IncomingStream {
    rx: tokio::sync::mpsc::Receiver<Incoming>,
}

impl futures_core::Stream for IncomingStream {
    type Item = Incoming;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Incoming>> {
        self.rx.poll_recv(cx)
    }
}

/// An inbound connection whose handshake (including ALPN) has completed.
pub struct Incoming {
    peer: NodeId,
    alpn: String,
    conn: Connection,
}

impl Incoming {
    pub fn peer(&self) -> NodeId {
        self.peer
    }

    pub fn alpn(&self) -> &str {
        &self.alpn
    }

    /// Accept the next bidirectional stream the dialer opens.
    /// QUIC streams are lazy: this resolves once the dialer sends data.
    pub async fn accept_bi(&self) -> Result<BiStream> {
        let (send, recv) = self
            .conn
            .accept_bi()
            .await
            .map_err(|e| TransportError::Io(e.to_string()))?;
        Ok(BiStream { send, recv })
    }
}

/// A bidirectional stream carrying length-prefixed frames (详细设计 §3.2
/// control plane). Frames are opaque bytes here — encoding/decoding lives
/// in `proto::codec`; the 4-byte LE length header is shared wire format.
pub struct BiStream {
    send: SendStream,
    recv: RecvStream,
}

impl BiStream {
    /// Send one complete frame, as produced by `proto::codec::encode`
    /// (the buffer already starts with its 4-byte LE length header).
    pub async fn send_frame(&mut self, frame: &[u8]) -> Result<()> {
        self.send
            .write_all(frame)
            .await
            .map_err(|e| TransportError::Io(e.to_string()))
    }

    /// Receive one complete frame (header + payload), ready for
    /// `proto::codec::decode`. `Ok(None)` = peer finished cleanly.
    pub async fn recv_frame(&mut self) -> Result<Option<Vec<u8>>> {
        let mut header = [0u8; 4];
        match self.recv.read_exact(&mut header).await {
            Ok(()) => {}
            Err(ReadExactError::FinishedEarly(0)) => return Ok(None),
            Err(e) => return Err(TransportError::Io(e.to_string())),
        }
        let len = u32::from_le_bytes(header);
        if len > MAX_FRAME {
            return Err(TransportError::FrameTooLarge(len));
        }
        let mut frame = vec![0u8; 4 + len as usize];
        frame[..4].copy_from_slice(&header);
        self.recv
            .read_exact(&mut frame[4..])
            .await
            .map_err(|e| match e {
                ReadExactError::FinishedEarly(got) => TransportError::TruncatedFrame {
                    expected: len as usize,
                    got,
                },
                e => TransportError::Io(e.to_string()),
            })?;
        Ok(Some(frame))
    }

    /// Finish the send side (graceful half-close). The peer's
    /// `recv_frame` then returns `Ok(None)`.
    pub fn finish(&mut self) -> Result<()> {
        self.send
            .finish()
            .map_err(|e| TransportError::Io(e.to_string()))
    }
}
