//! P-Pass storage daemon — production wiring (grows card by card).
//!
//! T-030: bind the endpoint, open the index, run the ctrl router with the
//! authz checkpoint. Pairing/IPC/tray integration land with T-031/T-034.

use daemon::{Config, Router};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // UX-07: --ephemeral — 测试/脚本模式：stdin EOF（写入端关闭）即整体
    // 退出（3 秒内），杜绝 A 类孤儿 daemon。生产/launchd 不带此 flag：
    // 那时 stdin 关闭只让配对确认退到 IPC-only（下方既有行为），常驻不变。
    let ephemeral = std::env::args().any(|a| a == "--ephemeral");
    // EOF 信号：stdin 循环在 EOF 时发；ephemeral 模式下 main 用 select
    // 竞争它，收到即优雅退出（oneshot 只消费一次）。
    let (eof_tx, eof_rx) = tokio::sync::oneshot::channel::<()>();
    let eof_tx = if ephemeral { Some(eof_tx) } else { None };

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

    // ── DAE-02: 单实例 claim 先于 transport bind ──────────────────
    // 固定端口 config 下，在位实例占着端口会让新实例 bind 直接失败；
    // 版本握手（接管/退位裁决）必须先于 bind 发生，否则接管永不发生
    // （验收人实锤：0.2.1 新实例 vs 0.1.0 在位，bind 先炸）。socket_name
    // 依赖 node_id——从 identity.key 直接派生，不必先 bind endpoint。
    let node_id = transport::node_id_from_secret_key(&secret);
    let socket_name = format!("ppf-{}", &node_id.to_string()[..8]);
    let daemon_version = daemon::daemon_version();
    println!(
        "IPC: {socket_name}（令牌在 {}/ipc.token）",
        data_dir.display()
    );

    // addr_provider 惰性填充：transport 在 claim 之后才 bind，配对二维码
    // 也在这之后生成（&a= 要带 live endpoint 的当前地址，见 Pairing）。
    let transport_slot: std::sync::Arc<std::sync::OnceLock<transport::IrohTransport>> =
        std::sync::Arc::new(std::sync::OnceLock::new());
    let slot = std::sync::Arc::clone(&transport_slot);
    let addr_provider: Option<std::sync::Arc<dyn Fn() -> String + Send + Sync>> =
        Some(std::sync::Arc::new(move || {
            slot.get()
                .map(|t| t.local_addr().to_string())
                .unwrap_or_default()
        }));

    // Pairing (T-031): issue one QR token at startup. Owner confirmation
    // is owned by the IPC layer (T-034) — tray UI and the interim console
    // prompt below both act through it. 绝不默认放行 (§2.2).
    let (pairing, pending_rx) = daemon::Pairing::new(db.clone(), node_id, addr_provider);

    // IPC (T-034): local socket + per-launch token in the data dir.
    let diag_agg = daemon::DiagAgg::new(db.clone());
    let ipc = std::sync::Arc::new(daemon::IpcServer::new(
        db.clone(),
        pairing.clone(),
        diag_agg.clone(),
        data_dir.clone(),
        pending_rx,
    ));
    // DAE-01 单实例纪律：先试连接、版本握手（newest wins）——旧逻辑
    // unlink-before-bind 会让后来者盲杀前任（用户机实锤：launchd 至今
    // 指向 7/31 开发构建路径，新 daemon 一直上不了岗）。
    // DAE-01b blocker①：claim 内部用前任 token（data_dir/ipc.token）
    // 握手——绝不用本实例的新随机 token 探测（生产必 auth 失败，
    // 被误判死 socket 而抢绑，前任变幽灵占库锁）。
    match ipc
        .claim_single_instance(&socket_name, &daemon_version)
        .await
    {
        daemon::Claim::StandDown => {
            println!("已有同版本或更新版本的 daemon 在值班（v{daemon_version}），本实例退出。");
            std::process::exit(0);
        }
        daemon::Claim::TookOver => {
            // 升级退位收尾：重装 autostart，让 launchd 指向本实例的稳定
            // 路径。守卫拒绝 target/、/tmp/ 等开发路径（不写坏 plist）。
            use platform::PlatformAdapter as _;
            if let Ok(exe) = std::env::current_exe() {
                if let Err(e) = platform::adapter().install_autostart(&exe) {
                    tracing::warn!("DAE-01: autostart re-install skipped: {e}");
                }
            }
        }
        daemon::Claim::Proceed => {}
    }

    // ── transport bind（claim 之后：固定端口此刻已被前任释放或确认无人占用）──
    let mut transport_cfg = transport::TransportConfig::from_endpoints(
        config.relay_urls.clone(),
        vec![
            transport::ALPN_CTRL.into(),
            transport::ALPN_BLOBS.into(),
            transport::ALPN_UPLOAD.into(),
            transport::ALPN_DOWNLOAD.into(),
        ],
    );
    transport_cfg.bind_addr = config.bind_addr;
    transport_cfg.secret_key = Some(secret);
    let transport = transport::IrohTransport::bind(transport_cfg).await?;
    // DAE-02 防漂移：bind 后的真实 node_id 必须与 claim 用的一致（同一
    // identity.key）。不一致说明身份文件被换，绝不能继续服务。
    if transport.node_id() != node_id {
        tracing::error!(
            "DAE-02: node id drift after bind (claim used {node_id}, bound {}) — aborting",
            transport.node_id()
        );
        std::process::exit(1);
    }
    let _ = transport_slot.set(transport.clone());
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

    // QR 在 transport bind 之后生成（&a= 需要 live endpoint 的地址）。
    let qr = pairing.start(rand_token()?, unix_ms_now());
    println!("配对二维码内容（10 分钟内有效）: {qr}");

    // DAE-01b blocker①：claim 成功后才生成/写入自己的 token（serve 写
    // 入 ipc.token）。claim 期间的探测用的是前任 token。
    let token = rand_token()?;
    tokio::spawn({
        let ipc = std::sync::Arc::clone(&ipc);
        async move {
            if let Err(e) = ipc.serve(&socket_name, token).await {
                tracing::error!("IPC 服务退出：{e}");
            }
        }
    });
    // Interim console confirmer (until the tray, T-041): y = 允许队首.
    // stdin EOF（后台运行）⇒ 退出这个循环，确认只走 IPC——绝不把
    // "没有输入" 当成任何决定（狗粮冒烟抓到的真 bug：EOF 曾被当 n 秒拒）.
    // UX-07: --ephemeral 模式下 EOF 同时发退出信号（main 的 select 收到
    // 即整体退出，3 秒内）——测试脚本关掉 stdin 写入端即可收掉 daemon。
    tokio::spawn({
        let ipc = std::sync::Arc::clone(&ipc);
        let eof_tx = eof_tx;
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
                    if let Some(tx) = eof_tx {
                        let _ = tx.send(());
                    }
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
                    ver: daemon::daemon_version(),
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
    let download = daemon::download::DownloadPlane::new(db.clone(), data_dir.clone());

    let router = Router::new(db, "P-Pass 存储端")
        .with_pairing(pairing)
        .with_backup(backup)
        .with_query(query)
        .with_upload(upload)
        .with_download(download);
    if ephemeral {
        // UX-07: --ephemeral — stdin EOF 即优雅退出（3 秒内），测试脚本
        // 用它杜绝 A 类孤儿。router.serve 跑到 transport 关闭为止；EOF
        // 信号一到，select 走退出分支，main 返回，进程干净结束。
        tokio::select! {
            _ = router.serve(&transport) => {}
            _ = eof_rx => {
                println!("--ephemeral: stdin 关闭，daemon 退出。");
                // 显式 close endpoint：flush 连接关闭帧，否则 drop 清理
                // 要数秒（验收限 3 秒内退出）。close 本身在部分环境下也
                // 可能慢——给它 2s 上限，超时即强制退出：close 已 flush
                // 协议层关闭帧，剩余 tokio 任务（定时循环）abort 无副作用。
                tokio::time::timeout(std::time::Duration::from_secs(2), transport.close())
                    .await
                    .ok();
                std::process::exit(0);
            }
        }
    } else {
        router.serve(&transport).await;
    }
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
