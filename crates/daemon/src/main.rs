// DEVLOG-02: Windows release 产物必须是 GUI 子系统。CONSOLE 子系统的进程被
// 计划任务（#957；更早的版本是 HKCU Run 键）登录拉起时，Windows 会自动给它
// 分配一个控制台窗口——创建进程的是 Windows，`spawn_windowless` 的
// CREATE_NO_WINDOW 只管桌面壳自己那一次 spawn，管不到登录自启这条路径。
// `not(debug_assertions)` 保住开发体验：`just dev-daemon` 是 debug 构建，
// 终端照样有输出。与 `apps/desktop/src-tauri/src/main.rs` 同构。
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

//! P-Pass storage daemon — production wiring (grows card by card).
//!
//! T-030: bind the endpoint, open the index, run the ctrl router with the
//! authz checkpoint. Pairing/IPC/tray integration land with T-031/T-034.

use daemon::{Config, Router, SHUTDOWN_DEADLINE};
use std::io::IsTerminal;

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
            println!(
                "{} {}",
                daemon::cli::VERSION_PRODUCT,
                daemon::daemon_version()
            );
            return Ok(());
        }
        Ok(daemon::cli::Cli::VersionJson) => {
            println!("{}", daemon::cli::version_json(&daemon::daemon_version()));
            return Ok(());
        }
        // #1042：诊断包的唯一写者。同样在一切 daemon 机制之前短路：不开库
        // （常驻服务在线时经 IPC logs.export 要那三份，不在线就不要）。契约：
        // 成功 exit 0，stdout 一行 {"zip","daemon_reachable"}；写不出 zip 时
        // exit 1，stderr 一行错误。常驻服务不在线不算失败。
        Ok(daemon::cli::Cli::DiagExport { out, app_version }) => {
            let env = daemon::diag_bundle::ExportEnv::from_process(out.into(), app_version);
            match daemon::diag_bundle::export(&env).await {
                Ok(v) => {
                    println!("{v}");
                    std::process::exit(0);
                }
                Err(e) => {
                    eprintln!("{e}");
                    std::process::exit(1);
                }
            }
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

    // #1115：--ephemeral = 测试沙盒，一整套配置在这里一次选定（见 daemon::sandbox）：
    // 自建临时存储根、内存身份、令牌 IPC、不连常驻 daemon、不接受任何路径输入。
    // 常驻 daemon 反过来**不认**这些运行时输入（`PPF_DATA_DIR` 不再生效）：库位置只来自
    // 平台 config。两条路在这之后不会再交叉。
    let sandbox = if ephemeral {
        let env: std::collections::HashMap<String, String> = std::env::vars().collect();
        let given = daemon::sandbox::forbidden_inputs(&env);
        if !given.is_empty() {
            eprintln!("{}", daemon::sandbox::rejection(&given));
            std::process::exit(2);
        }
        match daemon::sandbox::Sandbox::create() {
            Ok(sb) => {
                // 机读契约：脚本从这一行拿到沙盒目录（令牌文件、库都在里面）。
                println!("{}", sb.stdout_line());
                Some(sb)
            }
            Err(e) => {
                eprintln!("{e}");
                std::process::exit(1);
            }
        }
    } else {
        None
    };

    // DESK-24 (#173)：数据目录搬家必须排在**所有**读 data dir 的动作之前，
    // 包括下面这段日志初始化——平台默认日志文件的路径就是从 data dir 算出
    // 来的。此刻 tracing 还没起来，所以这里只拿结果，等它起来再记
    // （见 `.init()` 之后那几行）。
    //
    // 沙盒不搬：一个临时实例顺手把用户真实的 Roaming 目录搬走属于越权。
    let pinned_data_dir = sandbox.as_ref().map(|sb| sb.root().to_path_buf());
    let data_dir_migration = match pinned_data_dir {
        Some(_) => None,
        None => {
            use platform::PlatformAdapter as _;
            Some(platform::adapter().migrate_legacy_data_dir())
        }
    };

    // DESK-58 (#875)：stderr 没人接（Windows 计划任务登录拉起 / 壳一次性 spawn）时改接
    // 到 `logs\daemon.err`。必须排在搬家**之后**（文件在 data dir 里，开着句柄
    // 目录就搬不动）、日志初始化与库目录检查**之前**（那几处的报错只走 stderr，
    // 向导读的就是它们）。目录与平台默认日志同源：`PPF_DATA_DIR` 优先。
    {
        use platform::PlatformAdapter as _;
        let base = pinned_data_dir
            .clone()
            .unwrap_or_else(|| platform::adapter().data_dir());
        let _ = platform::adapter().capture_unattached_stderr(&base);
    }

    // Log to stderr; level via RUST_LOG (default info). 狗粮机排障的眼睛.
    // NET-02: DedupGuard 折叠重复行 + 给这次运行的写入量设上限——
    // 8/26 真机实锤 relay 握手失败 7 分钟写了 92211 行/73MB，见
    // log_guard.rs 顶部注释。with_ansi(false) 是顺带的：ANSI 控制码在
    // 落盘的 `.err` 里只会添乱，也让折叠的行匹配不必绕过颜色码。
    // DEVLOG-01：`PPF_LOG_FILE` 设了就把这同一个折叠器接到持久文件上
    // （开发期前台起 daemon 没有 launchd 托管，日志只在终端一闪而过）。
    // 不设 = 原行为，只写 stderr，生产 launchd 路径一行未变。
    // 打不开就照 DAE-03 那条「绝不静默忽略」的先例报错退出——用户显式
    // 指定了日志文件，悄悄退回 stderr 等于让他以为日志在写而其实没有。
    let log_writer = match daemon::log_guard::persistent_log_path_from_env() {
        Some(path) => match daemon::log_guard::DedupGuard::for_file(&path) {
            Ok(guard) => guard,
            Err(e) => {
                eprintln!("PPF_LOG_FILE={} 打不开：{e}", path.display());
                std::process::exit(2);
            }
        },
        // DEVLOG-02：env 没设时退到**平台默认**日志文件（Windows 有，macOS
        // 是 None、继续走 launchd 的 StandardErrorPath，一行未变）。
        // 两种来源的失败处理**故意不同**：env 是用户显式指定，打不开就
        // exit(2)（上面那条 DAE-03 先例）；平台默认是我们自己选的路径，
        // 打不开只警告并退回 stderr——不能因为日志目录有问题就让 daemon
        // 起不来。
        // DEVLOG-02 ①：debug 构建不落盘。`just dev-daemon` 时终端就在眼前，
        // 落盘等于让日志「消失」。门槛与顶部 windows_subsystem **刻意用同一
        // 个条件**——不分配控制台的那种构建，才需要文件兜底。
        None if cfg!(debug_assertions) => daemon::log_guard::DedupGuard::new(),
        None => {
            use platform::PlatformAdapter as _;
            // DEVLOG-02 ②：日志必须在读 config **之前**就位（config 自己出错
            // 也得记下来），所以这里只能用不需要解析 config 的两样东西：
            // 测试沙盒目录（#1115：沙盒的日志不许写进用户真实日志文件）与平台约定。
            // config.toml 里的 data_dir **无法**在这里被尊重，是鸡生蛋，
            // 属已知限制。
            let base = pinned_data_dir
                .clone()
                .unwrap_or_else(|| platform::adapter().data_dir());
            // DIAG-B1：macOS 文件 + stderr 双写——stderr 在 launchd 托管时是
            // `.err`，桌面向导读它的最后一行报启动失败（DESK-09）；被一次性
            // spawn 时 stderr 是 /dev/null，文件是唯一留痕。
            // #1046：launchd 接的 `.err` 在 `<logs>/` 里，容量由 daemon 管——stderr
            // 那份的计数从现有文件大小起算（跨运行封顶，同 daemon.log）。
            let paths = platform::adapter().daemon_log_paths(&base);
            let tees = platform::adapter().default_log_tees_stderr();
            let service_stderr = paths
                .stdio_by_service_manager
                .then_some(paths.stderr.as_deref())
                .flatten();
            let open = |path: &std::path::Path| {
                if tees {
                    daemon::log_guard::DedupGuard::for_file_and_stderr(path, service_stderr)
                } else {
                    daemon::log_guard::DedupGuard::for_file(path)
                }
            };
            match paths.log_file.clone() {
                Some(path) => match open(&path) {
                    Ok(guard) => guard,
                    Err(e) => {
                        eprintln!(
                            "平台默认日志文件 {} 打不开，退回 stderr：{e}",
                            path.display()
                        );
                        daemon::log_guard::DedupGuard::new()
                    }
                },
                None => daemon::log_guard::DedupGuard::new(),
            }
        }
    };
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                // #544：第三方 target 里会直接打印本机公网地址的，源头压级
                // （见 transport::QUIET_LOG_DIRECTIVES）；写入器另有脱敏兜底。
                .unwrap_or_else(|_| {
                    tracing_subscriber::EnvFilter::new(format!(
                        "info,{}",
                        transport::QUIET_LOG_DIRECTIVES
                    ))
                }),
        )
        .with_ansi(false)
        .with_writer(log_writer)
        .init();

    // DESK-24 (#173)：搬家发生在日志之前，到这儿才有地方记它。
    // **用户的数据换过位置**这件事必须在日志里留痕，否则事后查「我的配置
    // 哪去了」只能靠猜。没搬成 / 只搬了一半是 warn，不是 info。
    if let Some(outcome) = data_dir_migration {
        if outcome.is_warning() {
            tracing::warn!("{outcome}");
        } else if !outcome.is_quiet() {
            tracing::info!("{outcome}");
        }
    }

    // Default config file + data dir follow the platform convention
    // (~/Library/Application Support/P-Pass on macOS) — a first launch
    // with zero configuration must just work (T-042).
    let platform_dir = {
        use platform::PlatformAdapter as _;
        platform::adapter().data_dir()
    };
    let default_config = platform_dir.join("config.toml");
    // #1115：沙盒不读平台 config（不接受配置文件里的路径），库就是沙盒目录；
    // 常驻 daemon 读平台 config，且不认 PPF_DATA_DIR。
    let config = match &sandbox {
        Some(_) => Config::load(None)?,
        None => Config::load_resident(&default_config)?,
    };
    // #1115：常驻 daemon 的库位置只认正本（macOS 钥匙串；没有安全存储的平台是 config），
    // config.toml 里的 data_dir 有正本时只给人看。正本里还没有 ⇒ 未配置状态。
    let library_location =
        std::sync::Arc::new(daemon::library_location::LibraryLocation::for_platform());
    let _ = &platform_dir;
    let (data_dir, explicitly_configured) = match &sandbox {
        Some(sb) => (sb.root().to_path_buf(), false),
        None => match library_location.resident_library(&config) {
            Ok(daemon::library_location::ResidentLibrary::At { dir, configured }) => {
                (dir, configured)
            }
            Ok(daemon::library_location::ResidentLibrary::Unconfigured) => {
                run_unconfigured(std::sync::Arc::clone(&library_location)).await
            }
            Err(e) => {
                let msg = format!("读不出照片库位置（{e}）——后台服务无法启动（#1115）");
                eprintln!("{msg}");
                tracing::error!("启动失败：{msg}");
                std::process::exit(1);
            }
        },
    };
    // DESK-46 (#638)：config.toml 显式配置的库目录不存在 ⇒ 大声报错退出，
    // 绝不 create_dir_all 静默造——外置盘未挂载时会在 /Volumes 下造出同名
    // 真目录，照片写进内置盘（挂载点阴影）。默认平台目录（首启向导前）与
    // 测试沙盒目录保持旧行为。
    if let Err(msg) = library_root_check(explicitly_configured, data_dir.is_dir(), &data_dir) {
        // 文件日志此刻还没初始化（init_file_logging 在更后面）——走 stderr：
        // launchd 的 StandardErrorPath 会接住，DESK-09 诊断链（壳读 plist
        // stderr 尾行）照样能看到这句话；Windows 上落 logs\daemon.err（DESK-58）。KeepAlive 节流重拉，盘插回即自愈。
        eprintln!("{msg}");
        std::process::exit(1);
    }
    std::fs::create_dir_all(data_dir.join(".ppf"))?;
    // #949：清掉旧版遥测遗留的 anon_id（尽力而为，失败只 warn）。
    daemon::stats::purge_legacy_anon_id(&data_dir);

    // #1044：打不开索引库时输出 keyed 错误行（cli::startup_error_line），
    // 桌面按 key 出指引，不再用正则猜 stderr 原文。
    // #1115：有平台安全存储（macOS 钥匙串）时，配对记录正本在那里，库里的 pairing
    // 表只是镜像：打开时先以正本对齐镜像（库里被直接写进去的行不作数），读正本失败
    // 就拒绝启动。--ephemeral 是一次性测试实例，不碰钥匙串（与 #1109 身份同口径）。
    let pairing_store = if ephemeral {
        None
    } else {
        use platform::PlatformAdapter as _;
        platform::adapter().pairing_store()
    };
    let index_path = data_dir.join(".ppf/index.sqlite");
    let opened = match pairing_store {
        Some(store) => {
            let vault = std::sync::Arc::new(daemon::pairing_store::SecretPairingVault::new(store));
            storage::Db::open_with_vault(&index_path, vault)
                .await
                .map(|(db, aligned)| {
                    if !aligned.is_noop() {
                        // 镜像与正本不一致 = 崩溃残留或库被改过：按正本修正，并留痕。
                        tracing::warn!(
                            "#1115: 配对记录镜像已按正本对齐：删除 {} 条、补回 {} 条",
                            aligned.removed_from_mirror.len(),
                            aligned.restored_to_mirror.len()
                        );
                    }
                    db
                })
        }
        None => storage::Db::open(&index_path).await,
    };
    let db = match opened {
        Ok(db) => db,
        Err(e) => {
            eprintln!(
                "{}",
                daemon::cli::startup_error_line(daemon::cli::startup_error_key(&e), &e.to_string())
            );
            std::process::exit(1);
        }
    };
    // ── Persistent daemon identity (真机 P0: 每次重启换 NodeId 会把
    // 所有已配对手机变成孤儿——配对绑的就是 NodeId). #1109：macOS 存
    // data protection 钥匙串，Windows / Linux 仍是数据目录里的 identity.key；
    // 读不出来 / 内容不合法就拒绝启动；新身份先删全部配对记录，见 daemon::identity。
    let secret = load_or_mint_identity(ephemeral, &data_dir, &db).await;

    // ── DAE-02: 单实例 claim 先于 transport bind ──────────────────
    // 固定端口 config 下，在位实例占着端口会让新实例 bind 直接失败；
    // 版本握手（接管/退位裁决）必须先于 bind 发生，否则接管永不发生
    // （验收人实锤：0.2.1 新实例 vs 0.1.0 在位，bind 先炸）。socket_name
    // 依赖 node_id——从身份私钥直接派生，不必先 bind endpoint。
    let node_id = transport::node_id_from_secret_key(&secret);
    let socket_name = format!("ppf-{}", &node_id.to_string()[..8]);
    let daemon_version = daemon::daemon_version();
    // #1115：常驻 daemon 的 IPC 形态由平台决定。macOS：仅本用户可访问目录里的 socket，
    // 按对端代码签名认人，没有令牌；其余：命名空间端点 + 令牌文件。测试沙盒恒为令牌。
    let resident_ipc = if ephemeral {
        platform::ResidentIpc::NamespacedWithToken
    } else {
        use platform::PlatformAdapter as _;
        platform::adapter().resident_ipc()
    };
    if let platform::ResidentIpc::SignedSocket(path) = &resident_ipc {
        let prepared = daemon::ipc::check_socket_path(path).and_then(|()| {
            use platform::PlatformAdapter as _;
            let dir = path.parent().unwrap_or(path);
            platform::adapter()
                .prepare_private_dir(dir)
                .map_err(|e| format!("IPC 目录 {} 不可用：{e}", dir.display()))
        });
        if let Err(msg) = prepared {
            eprintln!("{msg}");
            tracing::error!("启动失败：{msg}");
            std::process::exit(1);
        }
    }
    // DEVLOG-03：改走 tracing，否则这行在 Windows release 上无处可去
    // （#163 之后不再分配控制台，stdout 没有去处）。只含 socket 名与令牌
    // **路径**，不含令牌内容，进日志是安全的。
    match &resident_ipc {
        platform::ResidentIpc::SignedSocket(path) => {
            tracing::info!("IPC: {}（按代码签名认证）", path.display())
        }
        platform::ResidentIpc::NamespacedWithToken => tracing::info!(
            "IPC: {socket_name}（令牌在 {}/ipc.token）",
            data_dir.display()
        ),
    }

    // relay_provider 惰性填充：transport 在 claim 之后才 bind，配对二维码
    // 也在这之后生成。H-10b: QR 只带 relay（&r=），从 local_addr() 的 addrs
    // 里取 Relay 变体。
    let transport_slot: std::sync::Arc<std::sync::OnceLock<transport::IrohTransport>> =
        std::sync::Arc::new(std::sync::OnceLock::new());
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
    // #1070: version-mismatch registry — Router writes, IPC device list reads.
    let outdated = daemon::router::OutdatedPeers::new();
    let (pairing, pending_rx) = daemon::Pairing::new(db.clone(), node_id, relay_provider);
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
    ipc.set_outdated_peers(outdated.clone());
    // #1118：配对时给手机看的电脑名（系统里的名字）。可能含用户真名：不写日志。
    let desktop_name = platform::adapter()
        .computer_name()
        .unwrap_or_else(|| daemon::router::GENERIC_DEVICE_NAME.to_owned());
    ipc.set_desktop_name(desktop_name.clone());
    // #1115：常驻 daemon 开放 config.set_library（只有签名窗口程序调得到）；测试沙盒不开放。
    if sandbox.is_none() {
        ipc.set_library_location(std::sync::Arc::clone(&library_location));
    }
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
    // NET-05: Flow's data provider can have a different NodeId from the paired
    // control peer. The delivery adapter maps that exact ALPN_BLOBS snapshot
    // back to this device-keyed registry; IPC exposes null when no fetch lives.
    let flow_paths = daemon::flow_delivery::FlowPathRegistry::default();
    {
        let paths = flow_paths.clone();
        ipc.set_flow_connection_provider(move |node_id| {
            let Ok(bytes) = <[u8; 32]>::try_from(node_id) else {
                return None;
            };
            paths.get(transport::NodeId(bytes))
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
    let claim = match &resident_ipc {
        // #1115：沙盒不连常驻 daemon——socket 名由随机身份派生，不会撞名，没有交接可做。
        _ if sandbox.is_some() => daemon::Claim::Proceed,
        platform::ResidentIpc::SignedSocket(path) => {
            ipc.claim_single_instance_signed(path, &daemon_version)
                .await
        }
        platform::ResidentIpc::NamespacedWithToken => {
            ipc.claim_single_instance(&socket_name, &daemon_version)
                .await
        }
    };
    match claim {
        daemon::Claim::StandDown => {
            // DEVLOG-03：退位理由必须在日志里留痕——Windows 上这曾是唯一
            // 的线索，而它打在一个不再存在的控制台里。
            tracing::info!(
                "已有同版本或更新版本的 daemon 在值班（v{daemon_version}），本实例退出。"
            );
            std::process::exit(0);
        }
        daemon::Claim::TookOver | daemon::Claim::Proceed => {
            // #1046（S-11）：核心不管托管——接管旧实例后不再碰开机自启登记。
            // 登记的校正（含 #604 不覆盖备份副本、#732 已指向自己不重装、DESK-68
            // 不在正式安装位置不写）由桌面发行层在新壳启动时对账完成
            // （apps/desktop/src-tauri/src/distribution.rs）。
        }
    }

    // ── transport bind（claim 之后：固定端口此刻已被前任释放或确认无人占用）──
    let mut transport_cfg = transport::TransportConfig::from_endpoints(
        config.relay_urls.clone(),
        vec![
            transport::ALPN_CTRL.into(),
            transport::ALPN_BLOBS.into(),
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
            // DEVLOG-03：启动失败是最需要留痕的一条。
            tracing::error!("启动失败：{msg}");
            std::process::exit(1);
        }
    };
    // DAE-02 防漂移：bind 后的真实 node_id 必须与 claim 用的一致（同一
    // 身份私钥）。不一致说明身份被换，绝不能继续服务。
    if transport.node_id() != node_id {
        tracing::error!(
            "DAE-02: node id drift after bind (claim used {node_id}, bound {}) — aborting",
            transport.node_id()
        );
        std::process::exit(1);
    }
    let _ = transport_slot.set(transport.clone());
    // #1122：配对入口按需开放。握手完成即按 NodeId 判定（iroh after_handshake）：
    // 有配对记录的设备放行；没有的，只在配对窗口内（二维码显示中，或它自己的申请
    // 未结束）放行控制面。其余在读任何请求之前就被拒（关闭码 401 not_paired）。
    transport.set_admission(daemon::admission::predicate(
        db.clone(),
        pairing.clone(),
        unix_ms_now,
    ));
    // Wait for the home relay before announcing anything: a QR issued
    // in the first seconds otherwise carries a bare LAN address and
    // cross-network phones can never reach us (真机教训 T-054).
    if !transport
        .wait_online(std::time::Duration::from_secs(10))
        .await
    {
        tracing::info!("提示：中继未在 10 秒内就绪，二维码将只含直连地址。");
    }

    tracing::info!("P-Pass daemon 已启动");
    // DEVLOG-03：`NodeId:` 这一行**必须留在 stdout**——它是机读契约：
    // tools/dogfood-smoke.sh 把两条流分开收（`> daemon.log 2> daemon.err`）
    // 然后 `grep -o 'NodeId: .*' daemon.log`。搬到 tracing（stderr）会让
    // 脚本拿到空串（tools/scenarios/*.sh 已在 #1115 改写为进程内测试）。所以这里刻意打两遍：stdout 那条给脚本，日志那条给事后
    // 排障（Windows release 上 stdout 无处可去，见 #163）。
    // #1122：完整 NodeId 只给测试沙盒（--ephemeral）的脚本；正式模式下 stdout
    // 由 launchd 接进 logs/daemon.out，同样只记前缀（全长可被任何人拨号）。
    println!(
        "NodeId: {}",
        daemon::cli::node_id_stdout(&transport.node_id().to_string(), ephemeral)
    );
    // #544：日志里只记前缀——全长 NodeId 可被任何人拨号，建连即可换来本机
    // 当前的直连地址（含公网 IP）。
    tracing::info!("NodeId: {:?}", transport.node_id());
    tracing::info!("库目录: {}", data_dir.display());

    // QR 在 transport bind 之后生成（&r= 需要 live endpoint 的中继）。
    let qr = pairing.start(rand_pair_token()?, unix_ms_now());
    // DEVLOG-03 / SEC-11 (#496)：配对链接**绝不进任何持久文件**。它带着
    // 10 分钟内有效的配对令牌（红线 4：凭据不落任何持久文件）。
    // DEVLOG-03 当初的做法是「只进 stdout」，但 stdout 不等于屏幕：macOS
    // launchd 的 StandardOutPath 就是 <数据目录>/logs/daemon.out（#1046 前是 ~/Library/Logs），
    // systemd/nohup/脚本重定向同理。所以只在 stdout 是终端时才打印链接，
    // 否则打一句不含链接的提示（见 cli::pair_link_stdout_line）。
    // 机读契约随之改为 IPC `pairing.start`：tools/ipc-lib.sh 的
    // `ipc_pair_qr`（dogfood-smoke / scenarios / android-*.sh）与
    // tools/win-smoke.ps1 都走它，不再 grep stdout。
    // 日志里只记「配对已开始」这件事实，不记内容。
    println!(
        "{}",
        daemon::cli::pair_link_stdout_line(&qr, std::io::stdout().is_terminal())
    );
    tracing::info!("配对二维码已生成（10 分钟内有效；内容含令牌，刻意不入日志）");

    // DAE-01b blocker①：claim 成功后才生成/写入自己的 token（serve 写
    // 入 ipc.token）。claim 期间的探测用的是前任 token。
    let token = rand_token()?;
    tokio::spawn({
        let ipc = std::sync::Arc::clone(&ipc);
        async move {
            let served = match &resident_ipc {
                platform::ResidentIpc::SignedSocket(path) => ipc.serve_signed(path).await,
                platform::ResidentIpc::NamespacedWithToken => ipc.serve(&socket_name, token).await,
            };
            if let Err(e) = served {
                tracing::error!("IPC 服务退出：{e}");
            }
        }
    });
    // stdin 只剩一个用途：EOF = 退出信号。
    // 托盘审批早已落地（配对确认只走 IPC）；终端里敲 y/n 批准配对的临时确认器
    // （T-041 之前的过渡物）已在 #1041 删除——所有脚本都只用 stdin EOF 收掉 daemon。
    // stdin EOF（后台运行）⇒ 退出这个循环；绝不把「没有输入」当成任何决定。
    // UX-07: --ephemeral 模式下 EOF 同时发退出信号（main 的 select 收到
    // 即整体退出，3 秒内）——测试脚本关掉 stdin 写入端即可收掉 daemon。
    tokio::spawn({
        let eof_tx = eof_tx;
        async move {
            loop {
                let bytes_read = tokio::task::spawn_blocking(|| {
                    let mut line = String::new();
                    std::io::stdin().read_line(&mut line).unwrap_or(0)
                })
                .await
                .unwrap_or(0);
                if bytes_read == 0 {
                    tracing::info!("stdin closed — pairing confirmation is IPC-only from here");
                    if let Some(tx) = eof_tx {
                        let _ = tx.send(());
                    }
                    return;
                }
                // 读到的行一律丢弃：配对确认只走 IPC。
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

    // #949: 运行统计只写本地日志（不联网）。daemon_alive 每 24h 一行。
    {
        let started = std::time::Instant::now();
        tokio::spawn(async move {
            loop {
                daemon::stats::record(daemon::stats::Event::DaemonAlive {
                    uptime_h: started.elapsed().as_secs() / 3600,
                    // #1043（G5）：平台名由适配器回答（与 consts::OS 同值）。
                    os: {
                        use platform::PlatformAdapter as _;
                        platform::adapter().platform_name().to_string()
                    },
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
    // NET-20: `.ppf/flow-staging` 同样该在启动时收一遍存量孤儿——与旧
    // 收件箱不同，Flow 的保护集（`active_flow_content_hashes`）是持久表
    // 而非内存态会话，启动这一刻查到的就是真值，不必像旧路径那样在
    // 启动时把保护集当成空集。
    match db.active_flow_content_hashes().await {
        Ok(protected) => {
            let freed = daemon::sweep_flow_staging_orphans(
                &data_dir.join(".ppf/flow-staging"),
                &protected,
                daemon::STAGING_ORPHAN_GRACE,
            );
            if freed > 0 {
                tracing::info!("NET-20: 启动时回收 flow-staging 孤儿 {} 字节", freed);
            }
        }
        Err(error) => {
            tracing::warn!("NET-20: 查询活跃 Flow 哈希失败，跳过启动时 flow-staging 回收: {error}");
        }
    }

    // One blob store handle, shared by backup (pulls) and query
    // (tickets); also serves fetches through the listen loop (T-033).
    let blobs = std::sync::Arc::new(
        transport::Blobs::open(&transport, &data_dir.join(".ppf/blobs")).await?,
    );
    // #546: the blobs data plane passes the same authz gate as ctrl /
    // upload / download — per connection and per request, device row read
    // fresh each time (revocation is immediate).
    blobs.attach_to_listener(daemon::blobs_gate::gate(db.clone()));
    // REBUILD-02: independent retained store for new Flow pulls. The legacy
    // inbox cleanup intentionally clears `.ppf/blobs`; this store must keep
    // iroh-blobs partials so interrupted one-item fetches resume after restart.
    let flow_gc_db = db.clone();
    let flow_gc_protected = move || {
        let db = flow_gc_db.clone();
        Box::pin(async move {
            db.active_flow_content_hashes().await.map_err(|error| {
                transport::TransportError::Io(format!(
                    "query active Flow hashes for GC protection: {error}"
                ))
            })
        })
            as std::pin::Pin<
                Box<
                    dyn std::future::Future<
                            Output = transport::Result<std::collections::HashSet<[u8; 32]>>,
                        > + Send,
                >,
            >
    };
    let flow_blobs = std::sync::Arc::new(
        transport::Blobs::open_with_periodic_gc(
            &transport,
            &data_dir.join(".ppf/flow-blobs"),
            std::time::Duration::from_secs(60),
            flow_gc_protected,
        )
        .await?,
    );
    let query = daemon::QueryEngine::new(db.clone(), blobs.clone(), &data_dir);
    // IDX-06 (#442): 入库后的缩略图预生成——低优先级线程池，与 thumb.get
    // 共用同一个 gate（同一 hash 只生成一次）。三条入库路径（Flow 交付、
    // 旧备份管线的 upload/commit、目录监听）都接同一个句柄；adopt 收编的
    // 行由下面的启动补齐 + 每小时对账后的补齐覆盖。
    let thumb_pregen = query.start_thumb_pregen(daemon::PREGEN_WORKERS);
    // NET-26 (#419) + DAE-11 (#804)：传输期间与插电期间共用同一份「别睡」声明。
    let awake = daemon::awake::AwakeHold::platform();
    // DAE-11 (#804)：daemon 在跑且插着电 ⇒ 一直挡住空闲睡眠（屏幕照常熄灭、
    // 锁屏）；用电池 / 不知道 ⇒ 释放，按用户自己的设置睡。电源变化由平台推送，
    // 不轮询。句柄要活到 main 结束：drop 即退订。
    let _power_watch = {
        use platform::PlatformAdapter as _;
        let power = std::sync::Arc::new(daemon::awake::ExternalPowerHold::new(awake.clone()));
        let watch = platform::adapter().watch_external_power(Box::new(move |on_ac| {
            match power.on_power(on_ac) {
                Some(true) => tracing::info!("DAE-11: 插着电——保持唤醒（屏幕照常熄灭、锁屏）"),
                Some(false) => {
                    tracing::info!("DAE-11: 用电池或电源未知（{on_ac:?}）——不再阻止睡眠")
                }
                None => {}
            }
        }));
        if watch.is_none() {
            tracing::info!("DAE-11: 本平台不支持电源变化通知——只在传输期间保持唤醒");
        }
        watch
    };
    let flow_delivery = daemon::flow_delivery::FlowDelivery::new(db.clone(), flow_blobs, &data_dir)
        .with_thumb_pregen(thumb_pregen.clone())
        .with_path_registry(flow_paths)
        .with_events(event_bus.clone())
        // NET-25: 同一张按 NodeId 登记的订阅表（Router 也拿同一份）——
        // 只读，只为推送日志里那句 peer_subscribed= 服务。
        .with_subscriptions(subscriptions.clone())
        // NET-26 (#419): keep the machine awake while any fetch runs.
        .with_awake(awake.clone());
    let backup = daemon::BackupEngine::new(db.clone(), blobs.clone(), &data_dir)
        .with_events(event_bus.clone())
        .with_thumb_pregen(thumb_pregen.clone());
    // DESK-03: 本地 IPC 也注入查询平面——桌面壳照片墙走同一 QueryEngine
    // （与手机同一数据源），timeline/thumb/asset.* 双平面可答。
    ipc.set_query(query.clone());
    // #563: device.revoke cancels the removed device's in-flight fetches.
    ipc.set_flow_delivery(flow_delivery.clone());
    ipc.set_backup(backup.clone());
    let download = daemon::download::DownloadPlane::new(db.clone(), data_dir.clone());

    // ── SYNC-01 外部删除对账 ──────────────────────────────
    // 磁盘（originals）↔ 索引（asset 表）diff：磁盘上没了的条目 = 外部
    // 删除（Finder/终端手动删），清 asset 行 + thumb 文件 + 审计
    // asset.removed_external（actor=NULL）。启动即跑一轮（重启即收敛），
    // 之后每小时 re-diff——目录监听（WATCH-01）为主，本循环兜底，监听起不来时
    // 收敛延迟退回最多 1 小时（见 reconcile.rs 模块注释）。
    // IDX-01: `with_local_node_id` 是「收孤儿」方向的开关——不接就只剩
    // SYNC-01 的删幽灵那一半，索引一丢照片就永远回不来。
    // #851: 补完上次崩溃时停在「索引已改指原图、文件还没换过去」的替换——必须在启动对账之前，
    // 否则对账会拿磁盘上的旧副本去比索引里的新指纹。
    use platform::PlatformAdapter as _;
    match core_index::Ingestor::new(db.clone(), &data_dir)
        .with_file_name_sanitizer(platform::adapter().ingest_file_name_sanitizer())
        .finish_pending_swaps()
        .await
    {
        Ok(0) => {}
        Ok(n) => tracing::info!("#851: 补完 {n} 条未换完的原图替换"),
        Err(e) => tracing::warn!("#851: 补完原图替换失败，下次启动再试: {e}"),
    }
    // #1047：清掉上次入库被打断（kill -9 / 断电）留下的临时文件。必须在启动
    // 对账之前、且在 watcher / router / IPC 能触发入库之前——运行期正在写的
    // 临时文件与残留长得一模一样，只有此刻能确定没有入库在进行。判据见
    // `core_index::sweep_ingest_residue`（文件名严格匹配 + 没有索引行；
    // 绝不按内容特征猜，免得误删用户自己放进库里的文件）。
    match core_index::sweep_ingest_residue(&db, &data_dir).await {
        Ok(0) => {}
        Ok(n) => tracing::info!("#1047: 清理入库中断残留的临时文件 {n} 个"),
        Err(e) => tracing::warn!("#1047: 清理入库残留失败，下次启动再试: {e}"),
    }
    let reconcile = daemon::Reconcile::new(db.clone(), &data_dir)
        .with_events(event_bus.clone())
        .with_local_node_id(node_id.0);
    let startup = reconcile.run_once().await;
    tracing::info!(
        "SYNC-01/IDX-01: 启动对账完成（移除幽灵资产 {} 条，收编孤儿文件 {} 条）",
        startup.removed,
        startup.adopted
    );
    // IDX-06 (#442): 启动补齐——存量库里 thumb_state=0 的行（含刚收编的
    // 孤儿）后台低优先级补齐；DESK-35 (#441)：thumb_state=2 的行每次启动
    // 重试一次（旧版本留在最终路径的占位图由此被真图覆盖或清掉）。
    // 延后片刻再开扫：启动这一刻桌面壳正要拉第一屏，不跟它抢。
    {
        let thumb_pregen = thumb_pregen.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_secs(10)).await;
            thumb_pregen.backfill(true);
        });
    }
    // #413 §6: 3 天没人续传的 active grant 取消，半截交给 flow-blobs GC。
    // 启动先扫一轮（daemon 可能停过好几天），之后跟每小时巡检一起跑。
    match flow_delivery.expire_stale_grants().await {
        Ok(0) => {}
        Ok(n) => tracing::info!("#413: 启动时取消超期未续传的 Flow grant {n} 个"),
        Err(error) => tracing::warn!("#413: 超期 grant 巡检失败，下一轮再试: {error}"),
    }
    {
        let reconcile = reconcile.clone();
        let backup = backup.clone();
        let flow_expiry = flow_delivery.clone();
        let thumb_pregen = thumb_pregen.clone();
        // NET-20: flow-staging 孤儿回收复用同一份 db/data_dir——
        // 保护集判据与 flow-blobs 的 iroh GC 回调（上面的
        // `flow_gc_protected`）同一张表（`active_flow_content_hashes`），
        // 两个装卸台该有的巡检不能只给旧管线接上。
        let flow_staging_db = db.clone();
        let flow_staging_dir = data_dir.join(".ppf/flow-staging");
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(3600)).await;
                let r = reconcile.run_once().await;
                if r.removed > 0 {
                    tracing::info!("SYNC-01: 每小时对账移除幽灵资产 {} 条", r.removed);
                }
                // IDX-01: 稳态是一条不收，所以只在真收编了才记——与
                // `adopt_orphans` 里那条审计同一条噪声纪律（WATCH-07）。
                if r.adopted > 0 {
                    tracing::info!("IDX-01: 每小时对账收编孤儿文件 {} 条", r.adopted);
                    // IDX-06 (#442): 收编的行 thumb_state=0，补一轮预生成。
                    thumb_pregen.backfill(false);
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
                // NET-20: `.ppf/flow-staging` 是 Flow 单通道自己的装卸台，
                // 不在 `backup.reclaim_staging` 的职责范围内——查询失败就
                // 跳过本轮（宁可漏收，不可在保护集不可信时误删）。
                match flow_expiry.expire_stale_grants().await {
                    Ok(0) => {}
                    Ok(n) => tracing::info!("#413: 取消超期未续传的 Flow grant {n} 个"),
                    Err(error) => tracing::warn!("#413: 超期 grant 巡检失败，下一轮再试: {error}"),
                }
                match flow_staging_db.active_flow_content_hashes().await {
                    Ok(protected) => {
                        let freed = daemon::sweep_flow_staging_orphans(
                            &flow_staging_dir,
                            &protected,
                            daemon::STAGING_ORPHAN_GRACE,
                        );
                        if freed > 0 {
                            tracing::info!("NET-20: 回收 flow-staging 孤儿 {freed} 字节");
                        }
                    }
                    Err(error) => {
                        tracing::warn!(
                            "NET-20: 查询活跃 Flow 哈希失败，跳过本轮 flow-staging 回收: {error}"
                        );
                    }
                }
            }
        });
    }

    // ── WATCH-01 本地目录监听（秒级增量同步）────────────────────
    // 库目录变化 → 增量 ingest/清理 → timeline.invalidated（SYNC-02 节流
    // 合并 → SYNC-03 订阅 → 手机刷新）。启动失败降级为每小时对账兜底，
    // 不阻塞 daemon（策略与理由见 watcher.rs 模块注释 + WATCH-01 卡）。
    let watcher = daemon::LibraryWatcher::new(db.clone(), &data_dir, node_id.0, event_bus.clone())
        .with_thumb_pregen(thumb_pregen.clone());
    if let Err(e) = watcher.spawn() {
        tracing::warn!("WATCH-01: 目录监听启动失败，降级为每小时对账兜底: {e}");
    }

    // #1119：删配对记录时关掉与那台设备的全部连接（电脑撤销走 IPC，手机断开走 Router）。
    let peer_closer: daemon::unpair::PeerCloser = {
        let t = transport.clone();
        std::sync::Arc::new(move |peer| t.close_peer(peer))
    };
    ipc.set_peer_closer(peer_closer.clone());
    let router = Router::new(db, desktop_name)
        .with_peer_closer(peer_closer)
        .with_events(event_bus.clone())
        .with_subscriptions(subscriptions)
        .with_outdated_peers(outdated)
        .with_pairing(pairing)
        .with_backup(backup)
        .with_flow_delivery(flow_delivery)
        .with_query(query)
        .with_download(download);
    // IPC-02: 启动就绪——订阅者（桌面壳）收到后即时刷新一次状态。
    daemon::events::emit(
        &event_bus,
        daemon::events::STATUS_CHANGED,
        serde_json::json!({}),
    );
    // #1047：停止信号（SIGTERM / Windows 控制台事件）与 --ephemeral 的 stdin
    // EOF 走同一条收尾路径。离开 `router.serve` 即停止接新连接；之后只剩
    // 收尾 + 退出，整体死线 SHUTDOWN_DEADLINE（Docker 默认 10s 后 SIGKILL，
    // launchd 20s）。
    //
    // 这里只能保证「收得到信号时体面地走」；SIGKILL / 断电 / TerminateProcess
    // 谁也收不到，那一类的安全由落盘侧兜底（入库不留占位文件 + 启动清残留，
    // 见 core_index::sweep_ingest_residue）。
    let stop = if ephemeral {
        // UX-07: --ephemeral — stdin EOF 即优雅退出（3 秒内），测试脚本
        // 用它杜绝 A 类孤儿。
        tokio::select! {
            _ = router.serve(&transport) => None,
            req = platform::stop_signal() => {
                tracing::info!("#1047: 收到 {}，开始收尾退出", req.name());
                Some(Some(req))
            }
            _ = eof_rx => {
                println!("--ephemeral: stdin 关闭，daemon 退出。");
                Some(None)
            }
        }
    } else {
        tokio::select! {
            _ = router.serve(&transport) => None,
            req = platform::stop_signal() => {
                tracing::info!("#1047: 收到 {}，开始收尾退出", req.name());
                Some(Some(req))
            }
        }
    };
    if let Some(req) = stop {
        shutdown(&transport, req).await;
    }
    Ok(())
}

/// 收尾并退出（不返回）。`req` 为 `Some` = 由停止信号触发：收尾后以「被该信号
/// 终止」的方式离开（见 `platform::StopRequest::finish`，保持服务管理器看到
/// 的退出状态不变）；`None` = `--ephemeral` 的 stdin EOF，`exit(0)`。
///
/// 做的事：显式 close endpoint（flush 连接关闭帧，否则 drop 清理要数秒），
/// 整体受 `SHUTDOWN_DEADLINE` 限制；收尾期间再收到一次停止信号 = 别等了，
/// 立刻走。close 已 flush 协议层关闭帧，剩余 tokio 任务（定时循环）abort
/// 无副作用；SQLite 是 WAL + synchronous=FULL，被中断的事务回滚，下次打开
/// 自动恢复。
async fn shutdown(transport: &transport::IrohTransport, req: Option<platform::StopRequest>) -> ! {
    let graceful = tokio::time::timeout(SHUTDOWN_DEADLINE, transport.close());
    tokio::select! {
        r = graceful => {
            if r.is_err() {
                tracing::warn!("#1047: 收尾超过 {SHUTDOWN_DEADLINE:?}，强制退出");
            }
        }
        again = platform::stop_signal() => {
            tracing::warn!("#1047: 收尾期间又收到 {}，立即退出", again.name());
        }
    }
    match req {
        Some(req) => req.finish(),
        None => std::process::exit(0),
    }
}

/// #1109：落定身份私钥；失败即拒绝启动——经 stderr 最后一行（keyed JSON，
/// 桌面壳读它显示原因）说明，不回退明文、不静默换身份。
/// `--ephemeral` 用只在内存里的临时身份（见 `daemon::identity::for_run`）。
async fn load_or_mint_identity(
    ephemeral: bool,
    data_dir: &std::path::Path,
    db: &storage::Db,
) -> [u8; 32] {
    use platform::PlatformAdapter as _;
    let adapter = platform::adapter();
    match daemon::identity::for_run(
        ephemeral,
        adapter.identity_key_home(),
        data_dir,
        |p| adapter.restrict_to_owner(p),
        rand_token,
        // #1117：新身份 = 新设备，先删全部配对记录（档案与审计保留）。
        || async {
            Ok(db
                .remove_all_pairings(storage::DepartedBy::Identity, unix_ms_now())
                .await?
                .len())
        },
    )
    .await
    {
        Ok(k) => k,
        Err(e) => {
            tracing::error!("启动失败：{e}");
            eprintln!("{}", daemon::cli::startup_error_line(None, &e.to_string()));
            std::process::exit(1);
        }
    }
}

/// DESK-46 (#638)：库目录的启动判据（纯函数——文件系统与 env 探测都在
/// 调用点完成，判据只由传入的事实决定，好做单测与反证）。
///
/// `configured_in_file` = data_dir 来自 config.toml 显式配置（PPF_DATA_DIR
/// 环境变量指定的不算——场景脚本/tools 依赖自动建一次性临时库）。
/// 显式配置的库目录不存在 ⇒ Err（人话，给 stderr / launchd 诊断链）；
/// 默认平台目录或目录已存在 ⇒ Ok。
fn library_root_check(
    configured_in_file: bool,
    exists: bool,
    data_dir: &std::path::Path,
) -> Result<(), String> {
    if configured_in_file && !exists {
        return Err(format!(
            "库目录不存在：{}——外置盘未挂载，或文件夹被移动/删除了。\
             请挂载/恢复后重试，或修正 config.toml 里的 data_dir。",
            data_dir.display()
        ));
    }
    Ok(())
}

/// #1115：未配置状态——正本里还没有库位置（macOS 钥匙串里没有；Windows / Linux 平台目录里
/// 没有 config.toml）。单实例交接照做，然后只答 `status` 与 `config.set_library`，写好后以
/// `EXIT_CONFIGURED_RESTART` 退出、带着库重新启动。
async fn run_unconfigured(
    location: std::sync::Arc<daemon::library_location::LibraryLocation>,
) -> ! {
    use platform::PlatformAdapter as _;
    let version = daemon::daemon_version();
    tracing::info!("#1115: 照片库位置未配置——只开放配置方法，等窗口程序的首启向导");
    let served = match platform::adapter().resident_ipc() {
        platform::ResidentIpc::SignedSocket(path) => {
            let prepared = daemon::ipc::check_socket_path(&path).and_then(|()| {
                let dir = path.parent().unwrap_or(&path);
                platform::adapter()
                    .prepare_private_dir(dir)
                    .map_err(|e| format!("IPC 目录 {} 不可用：{e}", dir.display()))
            });
            if let Err(msg) = prepared {
                eprintln!("{msg}");
                std::process::exit(1);
            }
            stand_down_unless_claimed(&daemon::ipc::PeerEndpoint::Signed(path.clone()), &version)
                .await;
            daemon::ipc::serve_unconfigured_signed(&path, version, location).await
        }
        platform::ResidentIpc::NamespacedWithToken => {
            // 前任（另一个未配置实例）的令牌在平台目录里；没有就是第一个。
            let platform_dir = location.platform_dir().to_path_buf();
            if let Some(token_hex) = predecessor_token(&platform_dir) {
                stand_down_unless_claimed(
                    &daemon::ipc::PeerEndpoint::Token {
                        socket_name: daemon::ipc::UNCONFIGURED_SOCKET_NAME.to_string(),
                        token_hex,
                    },
                    &version,
                )
                .await;
            }
            let token = match rand_token() {
                Ok(t) => t,
                Err(e) => {
                    eprintln!("{e}");
                    std::process::exit(1);
                }
            };
            daemon::ipc::serve_unconfigured_token(&platform_dir, token, version, location).await
        }
    };
    if let Err(e) = served {
        tracing::error!("IPC 服务退出：{e}");
    }
    std::process::exit(1);
}

/// 单实例交接（newest wins）：在位者同版本或更新 ⇒ 本实例退出。
async fn stand_down_unless_claimed(peer: &daemon::ipc::PeerEndpoint, version: &str) {
    if let daemon::Claim::StandDown = daemon::ipc::claim_endpoint(peer, version).await {
        tracing::info!("已有同版本或更新版本的 daemon 在值班（v{version}），本实例退出。");
        std::process::exit(0);
    }
}

/// 平台目录里 ipc.token 的令牌行，且 socket 名是未配置状态的那个（配置好的前任写在库里）。
fn predecessor_token(platform_dir: &std::path::Path) -> Option<String> {
    let raw = std::fs::read_to_string(platform_dir.join("ipc.token")).ok()?;
    let mut lines = raw.lines();
    (lines.next()?.trim() == daemon::ipc::UNCONFIGURED_SOCKET_NAME)
        .then(|| lines.next().map(|t| t.trim().to_string()))
        .flatten()
        .filter(|t| !t.is_empty())
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    // DESK-46 (#638)：显式配置的库目录不存在 ⇒ 拒绝启动（人话消息），
    // 不再 create_dir_all 造假目录。反证：把 library_root_check 改成永远
    // Ok，本测试必须变红。
    #[test]
    fn desk46_configured_library_missing_is_refused() {
        let err = library_root_check(true, false, Path::new("/Volumes/My Passport"))
            .expect_err("显式配置的库目录不存在时必须拒绝启动");
        assert!(err.contains("库目录不存在"), "消息要有人话：{err}");
        assert!(
            err.contains("/Volumes/My Passport"),
            "消息要带具体路径，用户才知道挂哪块盘：{err}"
        );
    }

    // DESK-46 (#638)：默认平台目录（首启向导前）与 PPF_DATA_DIR 场景目录
    // 不在守卫范围内——configured_in_file=false 时即使目录不存在也放行，
    // 由后面的 create_dir_all 自动建（tools/ 脚本契约）。
    #[test]
    fn desk46_default_or_env_library_may_be_created() {
        assert!(library_root_check(false, false, Path::new("/tmp/ppf-scene/library")).is_ok());
    }

    #[test]
    fn desk46_existing_configured_library_passes() {
        assert!(library_root_check(true, true, Path::new("/anywhere")).is_ok());
    }
}
