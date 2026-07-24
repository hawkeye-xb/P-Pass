//! S-01: iroh probe CLI — verify iroh 1.0 connectivity and throughput.
//! Spike code: pragmatic, not production-quality.
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use anyhow::Context;
use clap::{Parser, Subcommand};
use iroh::{Endpoint, EndpointAddr, endpoint::presets};
use serde::Serialize;

const ALPN: &[u8] = b"ppf/probe/1";

#[derive(Parser)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Start listener: prints NodeId + ticket, waits for dial connections
    Listen,
    /// Dial a listener: connect N times, measure each
    Dial {
        /// Ticket (EndpointAddr postcard hex-encoded) from the listener
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
        Cmd::Listen => do_listen().await,
        Cmd::Dial {
            ticket,
            count,
            payload_mb,
            out,
        } => do_dial(&ticket, count, payload_mb, out).await,
    }
}

async fn do_listen() -> anyhow::Result<()> {
    let ep = Endpoint::builder(presets::N0)
        .alpns(vec![ALPN.to_vec()])
        .bind()
        .await?;

    let addr = ep.addr();
    eprintln!("NodeId:  {}", addr.id);
    let relays: Vec<_> = addr.relay_urls().cloned().collect();
    eprintln!("Relays:  {:?}", relays);

    // Serialize EndpointAddr as ticket (postcard + hex)
    let ticket_bytes = postcard::to_stdvec(&addr)?;
    let ticket = hex::encode(&ticket_bytes);
    eprintln!("Ticket:  {ticket}");
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
    let (mut send, mut recv) = conn.accept_bi().await.context("accept bi")?;

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
    eprintln!("Received {:.1}MB from client", total as f64 / 1_000_000.0);
    // Wait for the client to close so the ACK propagates
    let _ = conn.closed().await;
    Ok(())
}

async fn do_dial(
    ticket_hex: &str,
    count: u32,
    payload_mb: u32,
    out: Option<PathBuf>,
) -> anyhow::Result<()> {
    let ticket_bytes = hex::decode(ticket_hex)?;
    let addr: EndpointAddr = postcard::from_bytes(&ticket_bytes)?;
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
