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

    // Default config file + data dir follow the platform convention
    // (~/Library/Application Support/P-Pass on macOS) — a first launch
    // with zero configuration must just work (T-042).
    let platform_dir = {
        use platform::PlatformAdapter as _;
        platform::adapter().data_dir()
    };
    let default_config = platform_dir.join("config.toml");
    let config = Config::load(Some(&default_config))?;
    let data_dir = config.data_dir.clone().unwrap_or(platform_dir);
    std::fs::create_dir_all(data_dir.join(".ppf"))?;

    let db = storage::Db::open(&data_dir.join(".ppf/index.sqlite")).await?;
    // ── Persistent daemon identity (真机 P0: 每次重启换 NodeId 会把
    // 所有已配对手机变成孤儿——配对绑的就是 NodeId). Keychain/DPAPI
    // first; headless platforms fall back to a 0600 file in the data
    // dir (same trust domain as ipc.token).
    let secret = load_or_mint_identity(&data_dir)?;

    let mut transport_cfg = transport::TransportConfig::from_endpoints(
        config.relay_urls.clone(),
        vec![
            transport::ALPN_CTRL.into(),
            transport::ALPN_BLOBS.into(),
            transport::ALPN_UPLOAD.into(),
        ],
    );
    transport_cfg.bind_addr = config.bind_addr;
    transport_cfg.secret_key = Some(secret);
    let transport = transport::IrohTransport::bind(transport_cfg).await?;
    // Wait for the home relay before announcing anything: a QR issued
    // in the first seconds otherwise carries a bare LAN address and
    // cross-network phones can never reach us (真机教训 T-054).
    if !transport
        .wait_online(std::time::Duration::from_secs(10))
        .await
    {
        println!("提示：中继未在 10 秒内就绪，二维码将只含直连地址。");
    }

    println!("P-Pass daemon 已启动");
    println!("NodeId: {}", transport.node_id());
    println!("库目录: {}", data_dir.display());

    // Pairing (T-031): issue one QR token at startup. Owner confirmation
    // is owned by the IPC layer (T-034) — tray UI and the interim console
    // prompt below both act through it. 绝不默认放行 (§2.2).
    let (pairing, pending_rx) = daemon::Pairing::new(
        db.clone(),
        transport.node_id(),
        Some(std::sync::Arc::new({
            let tp = transport.clone();
            move || tp.local_addr().to_string()
        })),
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
    let query = daemon::QueryEngine::new(db.clone(), blobs.clone(), &data_dir);
    let upload = daemon::upload::UploadPlane::new(db.clone(), blobs, data_dir.join(".ppf/staging"));

    Router::new(db, "P-Pass 存储端")
        .with_pairing(pairing)
        .with_backup(backup)
        .with_query(query)
        .with_upload(upload)
        .serve(&transport)
        .await;
    Ok(())
}

/// The daemon's stable identity key, in a 0600 file beside the index —
/// same trust domain as ipc.token. NOT the OS keychain for now: an
/// ad-hoc-signed binary re-triggers the Keychain authorization dialog
/// on every restart (live finding — an unattended service cannot answer
/// dialogs). Keychain migration lands with real release signing (T-071).
fn load_or_mint_identity(data_dir: &std::path::Path) -> anyhow::Result<[u8; 32]> {
    let key_file = data_dir.join(".ppf/identity.key");
    if let Ok(bytes) = std::fs::read(&key_file) {
        if bytes.len() == 32 {
            let mut k = [0u8; 32];
            k.copy_from_slice(&bytes);
            return Ok(k);
        }
    }
    let k = rand_token()?;
    std::fs::create_dir_all(data_dir.join(".ppf"))?;
    std::fs::write(&key_file, k)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&key_file, std::fs::Permissions::from_mode(0o600));
    }
    println!("身份密钥已铸造: {}", key_file.display());
    Ok(k)
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
