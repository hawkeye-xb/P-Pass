//! P-Pass storage daemon — production wiring (grows card by card).
//!
//! T-030: bind the endpoint, open the index, run the ctrl router with the
//! authz checkpoint. Pairing/IPC/tray integration land with T-031/T-034.

use daemon::{Config, Router};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // DAE-03 ①：参数解析最先——--help/--version 在任何 daemon 机制
    // （日志/配置/数据库/身份/claim/bind）之前短路退出。8/6 事故：daemon
    // 无解析，--help 被当普通启动一路走到单实例 claim 触发误接管、常驻
    // 停机数分钟。未知参数报错退出（exit 2），绝不静默忽略。
    let ephemeral = match daemon::cli::parse_cli(std::env::args().skip(1)) {
        Ok(daemon::cli::Cli::Help) => {
            print!("{}", daemon::cli::USAGE);
            return Ok(());
        }
        Ok(daemon::cli::Cli::Version) => {
            println!("P-Pass daemon {}", daemon::daemon_version());
            return Ok(());
        }
        Ok(daemon::cli::Cli::Run { ephemeral }) => ephemeral,
        Err(e) => {
            eprintln!("{e}");
            eprint!("{}", daemon::cli::USAGE);
            std::process::exit(2);
        }
    };
    // EOF 信号：stdin 循环在 EOF 时发；ephemeral 模式下 main 用 select
    // 竞争它，收到即优雅退出（oneshot 只消费一次）。
    let (eof_tx, eof_rx) = tokio::sync::oneshot::channel::<()>();
    let eof_tx = if ephemeral { Some(eof_tx) } else { None };

    // Log to stderr; level via RUST_LOG (default info). 狗粮机排障的眼睛.
    // NET-02: DedupGuard 折叠重复行 + 给这次运行的写入量设上限——
    // 8/26 真机实锤 relay 握手失败 7 分钟写了 92211 行/73MB，见
    // log_guard.rs 顶部注释。with_ansi(false) 是顺带的：ANSI 控制码在
    // 落盘的 `.err` 里只会添乱，也让折叠的行匹配不必绕过颜色码。
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_ansi(false)
        .with_writer(daemon::log_guard::DedupGuard::new())
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
    // H-10b: QR 只带 relay（&r=）——relay_provider 同样惰性，从
    // local_addr() 的 addrs 里取 Relay 变体。
    let transport_slot: std::sync::Arc<std::sync::OnceLock<transport::IrohTransport>> =
        std::sync::Arc::new(std::sync::OnceLock::new());
    let slot = std::sync::Arc::clone(&transport_slot);
    let addr_provider: Option<std::sync::Arc<dyn Fn() -> String + Send + Sync>> =
        Some(std::sync::Arc::new(move || {
            slot.get()
                .map(|t| t.local_addr().to_string())
                .unwrap_or_default()
        }));
    let relay_slot = std::sync::Arc::clone(&transport_slot);
    let relay_provider: Option<std::sync::Arc<dyn Fn() -> Option<String> + Send + Sync>> =
        Some(std::sync::Arc::new(move || {
            relay_slot.get().and_then(|t| t.local_addr().relay_url())
        }));

    // Pairing (T-031): issue one QR token at startup. Owner confirmation
    // is owned by the IPC layer (T-034) — tray UI and the interim console
    // prompt below both act through it. 绝不默认放行 (§2.2).
    // IPC-02: 事件总线在此创建——配对落定/备份落地/设备变化沿订阅通道
    // 即时通知桌面壳。
    let (event_bus, _event_probe) = daemon::events::bus();
    // SYNC-03: 一份订阅登记表，Router（QUIC 订阅入口）和 IpcServer
    // （device.revoke 在此发起主动断连）共用同一个实例。
    let subscriptions = daemon::subscriptions::SubscriptionRegistry::new();
    let (pairing, pending_rx) =
        daemon::Pairing::new(db.clone(), node_id, addr_provider, relay_provider);
    let pairing = pairing.with_events(event_bus.clone());

    // IPC (T-034): local socket + per-launch token in the data dir.
    let diag_agg = daemon::DiagAgg::new(db.clone());
    let mut ipc = daemon::IpcServer::new(
        db.clone(),
        pairing.clone(),
        diag_agg.clone(),
        data_dir.clone(),
        pending_rx,
        event_bus.clone(),
    );
    // T-090: devices.list connection 字段的实况来源——同样走惰性 slot
    // （transport 在 claim 之后才 bind）。bind 之前如实报 unknown，
    // 绝不用 last_seen 推断在线（卡片契约）。
    {
        let slot = std::sync::Arc::clone(&transport_slot);
        ipc.set_conn_status_provider(move |node_id| {
            let (Some(t), Ok(bytes)) = (slot.get(), <[u8; 32]>::try_from(node_id)) else {
                return transport::ConnectionStatus::Unknown;
            };
            t.connection_status(transport::NodeId(bytes))
        });
    }
    ipc.set_subscriptions(subscriptions.clone());
    let ipc = std::sync::Arc::new(ipc);
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
            // DAE-03 ②：autostart 安装决策收敛在
            // cli::autostart_install_required（单测钉死）——只有 TookOver
            // 装；Proceed（纯新启动）与 StandDown（退位）绝不碰。
            if daemon::cli::autostart_install_required(&daemon::Claim::TookOver) {
                use platform::PlatformAdapter as _;
                if let Ok(exe) = std::env::current_exe() {
                    if let Err(e) = platform::adapter().install_autostart(&exe) {
                        tracing::warn!("DAE-01: autostart re-install skipped: {e}");
                    }
                }
            }
        }
        daemon::Claim::Proceed => {
            // DAE-03 ②：纯新启动绝不装 autostart——手动/开发构建启动
            // 不得篡改用户的开机自启配置（决策见 cli.rs 单测）。
        }
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
    let transport = match transport::IrohTransport::bind(transport_cfg).await {
        Ok(t) => t,
        Err(e) => {
            // DAE-03 ③：固定端口被异身份实例/其它程序占用 → 人话报错。
            // 原始错误照常留日志；文案与占用识别见 cli.rs 单测。同身份
            // 冲突走不到这里（claim 已裁决），到这里的都是异身份/第三方。
            let msg = daemon::cli::humanize_bind_error(config.bind_addr, &e.to_string());
            tracing::error!("{msg}");
            println!("启动失败：{msg}");
            std::process::exit(1);
        }
    };
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

    // QR 在 transport bind 之后生成（&r= 需要 live endpoint 的中继）。
    let qr = pairing.start(rand_pair_token()?, unix_ms_now());
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
                if let Some(name) = ipc.confirm(None, accept, None) {
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

    // BLOB-01: 启动时把收件箱清空。
    //
    // blob store 现在只服务回退路径（T-032 主动拉取），而**启动这一刻不可能
    // 有传输在飞**——所以 `.ppf/blobs` 里剩的一定是上个会话的垃圾。这同时是
    // 老用户的迁移路径：升级前积累的那几百 MB（用户机器实测 554M）在这里
    // 一次性归零，不依赖 iroh 的 GC（它的 `gc_run_once` 是 crate 私有的，
    // 单个 blob 的 delete 也是 pub(crate)，官方只让走定时 GC）。
    //
    // 代价：回退路径若被打断，已拉到一半的部分数据不能跨重启续传。可以接受
    // ——那条路是按 commit 批次重试的，最多重拉一个文件。
    let blobs_dir = transport::Blobs::store_dir(&data_dir.join(".ppf"));
    // MOB-32：同一趟顺手收走 staging 里的孤儿——已校验落地但没人认领的
    // 裸文件。启动这一刻会话表必空（内存态），所以保护集为空；宽限期仍然
    // 给足，崩溃重启后刚落地那几个不至于白传。真机上这里要清的存量是 547MB。
    let reclaimed = daemon::reclaim_inbox(
        &blobs_dir,
        &data_dir.join(".ppf/staging"),
        daemon::STAGING_ORPHAN_GRACE,
    );
    if reclaimed > 0 {
        tracing::info!("BLOB-01: 收件箱回收 {} 字节", reclaimed);
    }

    // One blob store handle, shared by backup (pulls) and query
    // (tickets); also serves fetches through the listen loop (T-033).
    let blobs = std::sync::Arc::new(
        transport::Blobs::open(&transport, &data_dir.join(".ppf/blobs")).await?,
    );
    blobs.attach_to_listener();
    // REBUILD-02: independent retained store for new Flow pulls. The legacy
    // inbox cleanup intentionally clears `.ppf/blobs`; this store must keep
    // iroh-blobs partials so interrupted one-item fetches resume after restart.
    let flow_blobs = std::sync::Arc::new(
        transport::Blobs::open(&transport, &data_dir.join(".ppf/flow-blobs")).await?,
    );
    let flow_delivery = daemon::flow_delivery::FlowDelivery::new(db.clone(), flow_blobs, &data_dir);
    let backup = daemon::BackupEngine::new(db.clone(), blobs.clone(), &data_dir)
        .with_events(event_bus.clone());
    let query = daemon::QueryEngine::new(db.clone(), blobs.clone(), &data_dir);
    // DESK-03: 本地 IPC 也注入查询平面——桌面壳照片墙走同一 QueryEngine
    // （与手机同一数据源），timeline/thumb/asset.* 双平面可答。
    ipc.set_query(query.clone());
    // MOB-30：上传平面拿同一个 BackupEngine——收完一张就走它入库，
    // 单条入库的实现只有一份（BackupEngine::ingest_one）。
    let upload =
        daemon::upload::UploadPlane::new(db.clone(), data_dir.join(".ppf/staging"), backup.clone());
    let download = daemon::download::DownloadPlane::new(db.clone(), data_dir.clone());

    // ── SYNC-01 外部删除对账 ──────────────────────────────
    // 磁盘（originals）↔ 索引（asset 表）diff：磁盘上没了的条目 = 外部
    // 删除（Finder/终端手动删），清 asset 行 + thumb 文件 + 审计
    // asset.removed_external（actor=NULL）。启动即跑一轮（重启即收敛），
    // 之后每小时 re-diff——低频轮询而非目录监听的理由见 reconcile.rs
    // 模块注释（收敛延迟最多 1 小时 vs FSEvents/inotify 双平台复杂度）。
    let reconcile = daemon::Reconcile::new(db.clone(), &data_dir).with_events(event_bus.clone());
    let startup = reconcile.run_once().await;
    tracing::info!(
        "SYNC-01: 启动对账完成（移除幽灵资产 {} 条）",
        startup.removed
    );
    {
        let reconcile = reconcile.clone();
        let backup = backup.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(3600)).await;
                let r = reconcile.run_once().await;
                if r.removed > 0 {
                    tracing::info!("SYNC-01: 每小时对账移除幽灵资产 {} 条", r.removed);
                }
                // MOB-32 janitor：`begin` 不再重置会话之后，总得有人收走
                // 中途死掉的那一轮（否则上一轮声明过、手机再也不会提供的
                // 「幽灵 item」会一直留在 items 里）。会话收走了，它保护的
                // staging 孤儿也就跟着能回收了——顺序有意如此。
                let dropped = backup.sweep_sessions(daemon::SESSION_IDLE_TTL);
                if dropped > 0 {
                    tracing::info!("MOB-32: 清理空闲备份会话 {dropped} 个");
                }
                let freed = backup.reclaim_staging(daemon::STAGING_ORPHAN_GRACE);
                if freed > 0 {
                    tracing::info!("MOB-32: 回收 staging 孤儿 {freed} 字节");
                }
            }
        });
    }

    // ── WATCH-01 本地目录监听（秒级增量同步）────────────────────
    // 库目录变化 → 增量 ingest/清理 → timeline.invalidated（SYNC-02 节流
    // 合并 → SYNC-03 订阅 → 手机刷新）。启动失败降级为每小时对账兜底，
    // 不阻塞 daemon（策略与理由见 watcher.rs 模块注释 + WATCH-01 卡）。
    let watcher = daemon::LibraryWatcher::new(db.clone(), &data_dir, node_id.0, event_bus.clone());
    if let Err(e) = watcher.spawn() {
        tracing::warn!("WATCH-01: 目录监听启动失败，降级为每小时对账兜底: {e}");
    }

    let router = Router::new(db, "P-Pass 存储端")
        .with_events(event_bus.clone())
        .with_subscriptions(subscriptions)
        .with_pairing(pairing)
        .with_backup(backup)
        .with_flow_delivery(flow_delivery)
        .with_query(query)
        .with_upload(upload)
        .with_download(download);
    // IPC-02: 启动就绪——订阅者（桌面壳）收到后即时刷新一次状态。
    daemon::events::emit(
        &event_bus,
        daemon::events::STATUS_CHANGED,
        serde_json::json!({}),
    );
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

/// 12 random bytes for a pairing token (H-10b v2: 96-bit entropy is
/// plenty for one-shot pairing + 10-min TTL; keeps the QR short).
fn rand_pair_token() -> anyhow::Result<[u8; 12]> {
    let mut token = [0u8; 12];
    getrandom::fill(&mut token).map_err(|e| anyhow::anyhow!("系统随机数不可用：{e}"))?;
    Ok(token)
}

fn unix_ms_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
