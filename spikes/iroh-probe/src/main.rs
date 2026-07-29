//! S-01: iroh probe CLI — verify iroh 1.0 connectivity and throughput.
//! Spike code: pragmatic, not production-quality.
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use anyhow::Context;
use clap::{Parser, Subcommand};
use iroh::{Endpoint, EndpointAddr, endpoint::presets};
use serde::Serialize;

// Must match the Android probe app's ALPN (IrohProbe.ALPN) for interop.
const ALPN: &[u8] = b"ppass-probe";

#[derive(Parser)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Start listener: prints NodeId + ticket, waits for dial connections
    Listen {
        /// File to persist the secret key — keeps NodeId (and ticket) stable across restarts.
        #[arg(long, default_value = "iroh-probe.key")]
        key_file: PathBuf,
    },
    /// Dial a listener: connect N times, measure each
    Dial {
        /// Ticket (standard iroh EndpointTicket string) from the listener
        ticket: String,
        /// Number of connection attempts
        #[arg(long, default_value = "5")]
        count: u32,
        /// Payload size in MB per attempt
        #[arg(long, default_value = "10")]
        payload_mb: u32,
        /// Write results to JSONL file
        #[arg(long)]
        out: Option<PathBuf>,
    },
}

#[derive(Serialize)]
struct ProbeResult {
    attempt: u32,
    path: String,
    ipver: String,
    connect_ms: u64,
    throughput_mbps: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();
    let cli = Cli::parse();

    match cli.cmd {
        Cmd::Listen { key_file } => do_listen(&key_file).await,
        Cmd::Dial {
            ticket,
            count,
            payload_mb,
            out,
        } => do_dial(&ticket, count, payload_mb, out).await,
    }
}

/// Load the secret key from `path`, or generate one and persist it there.
fn load_or_create_key(path: &std::path::Path) -> anyhow::Result<iroh::SecretKey> {
    if path.exists() {
        let hex_str = std::fs::read_to_string(path)?;
        let bytes: [u8; 32] = hex::decode(hex_str.trim())?
            .try_into()
            .map_err(|_| anyhow::anyhow!("key file must contain 32 hex-encoded bytes"))?;
        Ok(iroh::SecretKey::from_bytes(&bytes))
    } else {
        let key = iroh::SecretKey::generate();
        std::fs::write(path, hex::encode(key.to_bytes()))?;
        eprintln!("New key generated and saved to {}", path.display());
        Ok(key)
    }
}

async fn do_listen(key_file: &std::path::Path) -> anyhow::Result<()> {
    let secret = load_or_create_key(key_file)?;
    let ep = Endpoint::builder(presets::N0)
        .secret_key(secret)
        // Fixed UDP port so the ticket's direct addr survives restarts.
        .bind_addr("0.0.0.0:41145")
        .map_err(|e| anyhow::anyhow!("bind_addr: {e}"))?
        .alpns(vec![ALPN.to_vec()])
        .bind()
        .await?;

    // Wait for the relay connection so the ticket contains a relay URL —
    // a ticket generated before that only carries LAN addresses and is
    // unreachable from cellular/off-LAN dialers.
    let deadline = Instant::now() + std::time::Duration::from_secs(15);
    while ep.addr().relay_urls().next().is_none() && Instant::now() < deadline {
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }

    let addr = ep.addr();
    eprintln!("NodeId:  {}", addr.id);
    let relays: Vec<_> = addr.relay_urls().cloned().collect();
    eprintln!("Relays:  {:?}", relays);
    if relays.is_empty() {
        eprintln!("WARN: no relay attached after 15s — ticket is LAN-only");
    }

    // Standard iroh ticket — the Android app parses this via EndpointTicket.fromString().
    let std_ticket = iroh_tickets::endpoint::EndpointTicket::new(addr.clone());
    eprintln!("Ticket:  {std_ticket}");
    eprintln!("Listening for connections...");

    loop {
        match ep.accept().await {
            Some(incoming) => match incoming.accept() {
                Ok(mut accepting) => {
                    match accepting.alpn().await {
                        Ok(a) if a == ALPN => {
                            tokio::spawn(async move {
                                if let Err(e) = handle_incoming(accepting).await {
                                    eprintln!("Client error: {e:?}");
                                }
                            });
                        }
                        _ => continue,
                    }
                }
                Err(e) => eprintln!("Accept error: {e}"),
            },
            None => {
                eprintln!("Endpoint closed.");
                break;
            }
        }
    }
    Ok(())
}

async fn handle_incoming(accepting: iroh::endpoint::Accepting) -> anyhow::Result<()> {
    let conn = accepting.await?;
    // The listener authenticates the dialer too — log WHO, not just "client".
    let remote_id = conn.remote_id();
    let (mut send, mut recv) = conn.accept_bi().await.context("accept bi")?;

    let t0 = Instant::now();
    let mut buf = vec![0u8; 64 * 1024];
    let mut total = 0u64;
    loop {
        match recv.read(&mut buf).await? {
            Some(0) | None => break,
            Some(n) => total += n as u64,
        }
    }
    send.write_all(b"OK").await?;
    send.finish()?;

    let secs = t0.elapsed().as_secs_f64();
    let mbps = if secs > 0.0 {
        total as f64 * 8.0 / 1_000_000.0 / secs
    } else {
        0.0
    };
    // Path facts are symmetric — the accept side classifies independently.
    let (path, ipver) = classify_connection(&conn);
    let remote_addr = conn
        .paths()
        .iter()
        .filter(|p| p.is_ip())
        .find_map(|p| match p.remote_addr() {
            iroh::TransportAddr::Ip(a) => Some(a.to_string()),
            _ => None,
        });
    let remote_short = &remote_id.to_string()[..10];
    eprintln!(
        "Received {:.1}MB from {remote_short} ({path}/{ipver} {}) {mbps:.1} Mbps",
        total as f64 / 1_000_000.0,
        remote_addr.as_deref().unwrap_or("relay-only"),
    );
    // Listener-side JSONL so tests are analyzable without the dialer's log.
    let line = serde_json::json!({
        "ts_ms": std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0),
        "remote_id": remote_id.to_string(),
        "path": path,
        "ipver": ipver,
        "remote_addr": remote_addr,
        "mb": total as f64 / 1_000_000.0,
        "mbps": mbps,
    });
    if let Err(e) = append_jsonl("listen-log.jsonl", &line) {
        eprintln!("WARN: listen-log.jsonl write failed: {e}");
    }
    // Wait for the client to close so the ACK propagates
    let _ = conn.closed().await;
    Ok(())
}

fn append_jsonl(path: &str, line: &serde_json::Value) -> anyhow::Result<()> {
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    writeln!(f, "{line}")?;
    Ok(())
}

async fn do_dial(
    ticket_hex: &str,
    count: u32,
    payload_mb: u32,
    out: Option<PathBuf>,
) -> anyhow::Result<()> {
    let addr: EndpointAddr = ticket_hex
        .parse::<iroh_tickets::endpoint::EndpointTicket>()
        .map(|t| t.endpoint_addr().clone())
        .map_err(|e| anyhow::anyhow!("invalid ticket: {e}"))?;
    eprintln!("Dialing NodeId: {}", addr.id);
    eprintln!("Count: {count}, Payload: {payload_mb}MB");

    // Create a single endpoint for all attempts
    let ep = Endpoint::builder(presets::N0)
        .alpns(vec![ALPN.to_vec()])
        .bind()
        .await?;

    let mut results = Vec::new();
    let payload_mb = payload_mb.max(1);
    let payload = vec![0x42u8; (payload_mb as usize) * 1_000_000];
    let payload = Arc::new(payload);

    for i in 1..=count {
        eprintln!("\n--- Attempt {i}/{count} ---");
        let result = run_one_dial(&ep, &addr, &payload, i).await;
        match serde_json::to_string(&result) {
            Ok(line) => {
                println!("{line}");
                results.push(line);
            }
            Err(e) => eprintln!("serialize error: {e}"),
        }
    }

    // Graceful close
    ep.close().await;
    eprintln!("Endpoint closed.");

    if let Some(path) = &out {
        std::fs::write(path, results.join("\n") + "\n")?;
        eprintln!("Results written to {}", path.display());
    }

    Ok(())
}

async fn run_one_dial(
    ep: &Endpoint,
    addr: &EndpointAddr,
    payload: &[u8],
    attempt: u32,
) -> ProbeResult {
    let t0 = Instant::now();

    let conn = match ep.connect(addr.clone(), ALPN).await {
        Ok(conn) => conn,
        Err(e) => {
            return ProbeResult {
                attempt,
                path: "unknown".into(),
                ipver: "unknown".into(),
                connect_ms: t0.elapsed().as_millis() as u64,
                throughput_mbps: 0.0,
                error: Some(format!("connect: {e}")),
            };
        }
    };

    let connect_ms = t0.elapsed().as_millis() as u64;
    let (path, ipver) = classify_connection(&conn);

    let t1 = Instant::now();
    let send_result = send_and_ack(&conn, payload).await;
    let elapsed_s = t1.elapsed().as_secs_f64();

    let throughput_mbps = if elapsed_s > 0.0 {
        (payload.len() as f64 * 8.0 / 1_000_000.0) / elapsed_s
    } else {
        0.0
    };

    // Close this connection before the next attempt
    conn.close(0u32.into(), b"done");

    match send_result {
        Ok(_) => ProbeResult {
            attempt,
            path,
            ipver,
            connect_ms,
            throughput_mbps,
            error: None,
        },
        Err(e) => ProbeResult {
            attempt,
            path,
            ipver,
            connect_ms,
            throughput_mbps: if elapsed_s > 0.0 { throughput_mbps } else { 0.0 },
            error: Some(format!("xfer: {e}")),
        },
    }
}

/// Classify connection as lan/direct/relay and IPv4/IPv6.
fn classify_connection(conn: &iroh::endpoint::Connection) -> (String, String) {
    let paths = conn.paths();
    let mut path_type = "direct".to_string();
    let mut ipver = "v4".to_string();

    for path in paths.iter() {
        if path.is_selected() && path.is_relay() {
            path_type = "relay".into();
        }
        if path.is_ip() {
            if let iroh::TransportAddr::Ip(addr) = path.remote_addr() {
                match addr {
                    std::net::SocketAddr::V4(_) => ipver = "v4".into(),
                    std::net::SocketAddr::V6(_) => ipver = "v6".into(),
                }
            }
        }
        // Short RTT on selected path means LAN
        if path.is_selected() && path.rtt().as_micros() < 500 {
            path_type = "lan".into();
        }
    }
    (path_type, ipver)
}

async fn send_and_ack(conn: &iroh::endpoint::Connection, payload: &[u8]) -> anyhow::Result<()> {
    let (mut send, mut recv) = conn.open_bi().await.context("open bi")?;

    send.write_all(payload).await?;
    send.finish()?;

    let mut ack = [0u8; 2];
    recv.read_exact(&mut ack).await?;

    Ok(())
}
