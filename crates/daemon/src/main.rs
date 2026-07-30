//! P-Pass storage daemon — production wiring (grows card by card).
//!
//! T-030: bind the endpoint, open the index, run the ctrl router with the
//! authz checkpoint. Pairing/IPC/tray integration land with T-031/T-034.

use daemon::{Config, Router};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Log to stderr; level via RUST_LOG (default info). 狗粮机排障的眼睛.
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .init();

    let config = Config::load(None)?;
    let data_dir = config
        .data_dir
        .clone()
        .ok_or_else(|| anyhow::anyhow!("data_dir 未配置：请在 config.toml 设置 data_dir"))?;
    std::fs::create_dir_all(data_dir.join(".ppf"))?;

    let db = storage::Db::open(&data_dir.join(".ppf/index.sqlite")).await?;
    let mut transport_cfg = transport::TransportConfig::from_endpoints(
        config.relay_urls.clone(),
        vec![transport::ALPN_CTRL.into(), transport::ALPN_BLOBS.into()],
    );
    transport_cfg.bind_addr = config.bind_addr;
    let transport = transport::IrohTransport::bind(transport_cfg).await?;

    println!("P-Pass daemon 已启动");
    println!("NodeId: {}", transport.node_id());
    println!("库目录: {}", data_dir.display());

    // Pairing (T-031): issue one QR token at startup. Owner confirmation
    // is owned by the IPC layer (T-034) — tray UI and the interim console
    // prompt below both act through it. 绝不默认放行 (§2.2).
    let (pairing, pending_rx) = daemon::Pairing::new(
        db.clone(),
        transport.node_id(),
        Some(transport.local_addr().to_string()),
    );
    let qr = pairing.start(rand_token()?, unix_ms_now());
    println!("配对二维码内容（10 分钟内有效）: {qr}");

    // IPC (T-034): local socket + per-launch token in the data dir.
    let diag_agg = daemon::DiagAgg::new(db.clone());
    let ipc = std::sync::Arc::new(daemon::IpcServer::new(
        db.clone(),
        pairing.clone(),
        diag_agg.clone(),
        data_dir.clone(),
        pending_rx,
    ));
    let socket_name = format!("ppf-{}", &transport.node_id().to_string()[..8]);
    println!(
        "IPC: {socket_name}（令牌在 {}/ipc.token）",
        data_dir.display()
    );
    tokio::spawn({
        let ipc = std::sync::Arc::clone(&ipc);
        let token = rand_token()?;
        async move {
            if let Err(e) = ipc.serve(&socket_name, token).await {
                tracing::error!("IPC 服务退出：{e}");
            }
        }
    });
    // Interim console confirmer (until the tray, T-041): y = 允许队首.
    // stdin EOF（后台运行）⇒ 退出这个循环，确认只走 IPC——绝不把
    // "没有输入" 当成任何决定（狗粮冒烟抓到的真 bug：EOF 曾被当 n 秒拒）.
    tokio::spawn({
        let ipc = std::sync::Arc::clone(&ipc);
        async move {
            loop {
                let line = tokio::task::spawn_blocking(|| {
                    let mut line = String::new();
                    let n = std::io::stdin().read_line(&mut line).unwrap_or(0);
                    (n, line)
                })
                .await
                .unwrap_or((0, String::new()));
                let (bytes_read, line) = line;
                if bytes_read == 0 {
                    tracing::info!("stdin closed — pairing confirmation is IPC-only from here");
                    return;
                }
                if ipc.pending_names().is_empty() {
                    continue;
                }
                let accept = line.trim().eq_ignore_ascii_case("y");
                if let Some(name) = ipc.confirm(None, accept) {
                    println!("「{name}」：{}", if accept { "已允许" } else { "已拒绝" });
                }
            }
        }
    });
    // 30-day diag ring housekeeping.
    tokio::spawn({
        let diag_agg = diag_agg.clone();
        async move {
            loop {
                let _ = diag_agg.prune_ring(unix_ms_now()).await;
                tokio::time::sleep(std::time::Duration::from_secs(6 * 3600)).await;
            }
        }
    });

    // Telemetry (T-035): opt-out respected at the root — with the switch
    // off the client never mints an id, never spawns a timer.
    let telemetry = daemon::Telemetry::new(
        config.telemetry.enabled,
        config.telemetry.url.clone(),
        &data_dir,
    );
    if telemetry.enabled() {
        tokio::spawn(telemetry.clone().run());
        let heartbeat = telemetry.clone();
        let started = std::time::Instant::now();
        tokio::spawn(async move {
            loop {
                heartbeat.record(daemon::TelemetryEvent::DaemonAlive {
                    uptime_h: started.elapsed().as_secs() / 3600,
                    os: std::env::consts::OS.to_string(),
                    ver: env!("CARGO_PKG_VERSION").to_string(),
                });
                tokio::time::sleep(std::time::Duration::from_secs(24 * 3600)).await;
            }
        });
    }

    // One blob store handle, shared by backup (pulls) and query
    // (tickets); also serves fetches through the listen loop (T-033).
    let blobs = std::sync::Arc::new(
        transport::Blobs::open(&transport, &data_dir.join(".ppf/blobs")).await?,
    );
    blobs.attach_to_listener();
    let backup = daemon::BackupEngine::new(db.clone(), blobs.clone(), &data_dir);
    let query = daemon::QueryEngine::new(db.clone(), blobs, &data_dir);

    Router::new(db, "P-Pass 存储端")
        .with_pairing(pairing)
        .with_backup(backup)
        .with_query(query)
        .serve(&transport)
        .await;
    Ok(())
}

/// 32 random bytes from the OS (via std's RandomState hashing entropy is
/// NOT enough — use getrandom through the `rand`-free std path).
fn rand_token() -> anyhow::Result<[u8; 32]> {
    let mut token = [0u8; 32];
    getrandom::fill(&mut token).map_err(|e| anyhow::anyhow!("系统随机数不可用：{e}"))?;
    Ok(token)
}

fn unix_ms_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
