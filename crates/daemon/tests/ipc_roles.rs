//! #1115：IPC 连接方身份决定能调哪些方法；诊断导出经常驻端点要来三份 JSON。
//!
//! 签名 socket 上的真实对端校验要签名二进制，单测里只能走令牌模式（令牌客户端 = 窗口
//! 程序）；「对端是 daemon 自身时能调什么」直接测 [`IpcClient::may_call`] 的判据，
//! 真机签名验收在卡评论里另记。

use std::sync::Arc;
use std::time::{Duration, Instant};

use daemon::diag_bundle::{collect_from_daemon, DaemonCollection};
use daemon::ipc::{IpcClient, PeerEndpoint, DAEMON_CLIENT_METHODS};
use daemon::{DiagAgg, IpcServer, Pairing};
use storage::Db;

/// daemon 自身作为客户端只有交接与诊断导出要用的三个方法；配对、授权、改名、撤销都不行。
/// 反证：DAEMON_CLIENT_METHODS 里加上 `pairing.confirm`，或 may_call 对 Daemon 恒真 ⇒ 红。
#[test]
fn a_daemon_client_may_only_hand_over_and_export_logs() {
    assert_eq!(
        DAEMON_CLIENT_METHODS,
        ["status", "daemon.step_down", "logs.export"]
    );
    for m in DAEMON_CLIENT_METHODS {
        assert!(IpcClient::Daemon.may_call(m), "{m}");
    }
    for m in [
        "pairing.start",
        "pairing.confirm",
        "pairing.pending",
        "device.revoke",
        "device.rename",
        "devices.list",
        "events.subscribe",
        "asset.original",
        "config.set_library",
    ] {
        assert!(!IpcClient::Daemon.may_call(m), "daemon 自身不许调 {m}");
        assert!(IpcClient::Shell.may_call(m), "窗口程序可以调 {m}");
    }
}

async fn server(dir: &std::path::Path) -> (Arc<IpcServer>, String, String) {
    let db = Db::open(&dir.join("index.sqlite")).await.unwrap();
    let (event_bus, _probe) = daemon::events::bus();
    let (pairing, pending_rx) = Pairing::new(db.clone(), transport::NodeId([0xAB; 32]), None);
    let diag = DiagAgg::new(db.clone());
    let ipc = Arc::new(IpcServer::new(
        db,
        pairing,
        diag,
        dir.to_path_buf(),
        pending_rx,
        event_bus,
    ));
    // 每次调用一个名字：同一进程里并行的测试共用一个名字时，后起的 serve 会把前一个的
    // socket 当残留清掉（cargo test 同进程多线程跑，前一个的 connect 随之失败）。
    static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let socket = format!("ppf-test-{}-1115-{n}", std::process::id());
    let token = [0x15; 32];
    let token_hex: String = token.iter().map(|b| format!("{b:02x}")).collect();
    tokio::spawn({
        let ipc = Arc::clone(&ipc);
        let socket = socket.clone();
        async move {
            let _ = ipc.serve(&socket, token).await;
        }
    });
    (ipc, socket, token_hex)
}

/// 常驻服务在线：诊断导出经端点要来三份 JSON；它在库目录里写的中间产物读完即删
/// （导出位置只由 `--out` 决定）。以前这条是起一个 `--ephemeral` 子进程再用 `PPF_DATA_DIR`
/// 指过去——#1115 之后沙盒不收路径输入、导出也不认 `PPF_DATA_DIR`，改成进程内。
#[tokio::test(flavor = "multi_thread")]
async fn online_export_collects_three_files_and_leaves_no_second_copy() {
    let dir = tempfile::tempdir().unwrap();
    let (_ipc, socket_name, token_hex) = server(dir.path()).await;
    let endpoint = PeerEndpoint::Token {
        socket_name,
        token_hex,
    };
    let out = dir.path().join("out").join("bundle.zip");
    std::fs::create_dir_all(out.parent().unwrap()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let (status, entries) = loop {
        match collect_from_daemon(std::slice::from_ref(&endpoint), &out).await {
            DaemonCollection::Complete {
                status, entries, ..
            } => break (status, entries),
            other if Instant::now() > deadline => panic!("10 秒内没连上：{}", describe(&other)),
            _ => tokio::time::sleep(Duration::from_millis(100)).await,
        }
    };
    let names: Vec<&str> = entries.iter().map(|(k, _)| k.as_str()).collect();
    for want in ["diag_events.json", "devices.json", "audit.json"] {
        assert!(names.contains(&want), "缺 {want}：{names:?}");
    }
    // #1115：回归经 `diag export` 取状态——status 那几项随包带回，只有白名单字段。
    let status = status.expect("在线时要带回 status");
    assert_eq!(status["photo_count"], 0, "{status}");
    assert!(status["version"].is_string(), "{status}");
    assert_eq!(
        status.as_object().unwrap().len(),
        daemon::diag_bundle::STATUS_FIELDS.len(),
        "{status}"
    );
    assert!(
        !dir.path().join("ppf-logs.zip").exists(),
        "库目录里不得留下第二份包"
    );
}

/// 令牌不对：拿不到任何东西（连接被丢弃），诊断导出如实报「连不上 / 不应答」。
#[tokio::test(flavor = "multi_thread")]
async fn a_wrong_token_gets_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let (_ipc, socket_name, _) = server(dir.path()).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    let endpoint = PeerEndpoint::Token {
        socket_name,
        token_hex: "00".repeat(32),
    };
    let out = dir.path().join("bundle.zip");
    match collect_from_daemon(&[endpoint], &out).await {
        DaemonCollection::Unreachable(_) => {}
        other => panic!("错令牌不该拿到东西：{}", describe(&other)),
    }
}

fn describe(c: &DaemonCollection) -> String {
    match c {
        DaemonCollection::Unreachable(e) => format!("Unreachable({e})"),
        DaemonCollection::LogsUnavailable { reason, .. } => format!("LogsUnavailable({reason})"),
        DaemonCollection::Complete { .. } => "Complete".into(),
    }
}

// ── #1115：照片库位置的写入口 ──────────────────────────────────────────

use daemon::ipc::unconfigured_dispatch;
use daemon::library_location::LibraryLocation;
use proto::Req;
use std::sync::Mutex;

#[derive(Default, Clone)]
struct MemStore(Arc<Mutex<Option<Vec<u8>>>>);
impl platform::SecretBlobStore for MemStore {
    fn read(&self) -> platform::Result<Option<Vec<u8>>> {
        Ok(self.0.lock().unwrap().clone())
    }
    fn write(&self, b: &[u8]) -> platform::Result<()> {
        *self.0.lock().unwrap() = Some(b.to_vec());
        Ok(())
    }
    fn delete(&self) -> platform::Result<()> {
        *self.0.lock().unwrap() = None;
        Ok(())
    }
    fn location(&self) -> String {
        "mem".into()
    }
}

fn req(method: &str, params: serde_json::Value) -> Req {
    serde_json::from_value(serde_json::json!({ "id": "t", "method": method, "params": params }))
        .unwrap()
}

/// 未配置状态只答 `status`（报 unconfigured）、`config.set_library` 与不推事件的 `events.subscribe`；其余一律「还没有库」。
/// 窗口程序写得进库位置；daemon 自身（被借用的代理）写不进。
/// 反证：unconfigured_dispatch 去掉 may_call 检查 ⇒ daemon 那条变 ok，红；兜底分支放行别的方法 ⇒ 红。
#[tokio::test]
async fn unconfigured_state_answers_only_status_and_set_library() {
    let tmp = tempfile::tempdir().unwrap();
    let store = MemStore::default();
    let loc = Arc::new(LibraryLocation::with(
        Some(Box::new(store.clone())),
        tmp.path().join("platform"),
    ));
    let s = unconfigured_dispatch(
        &req("status", serde_json::json!({})),
        IpcClient::Shell,
        "1.0.0",
        0,
        &loc,
    )
    .await;
    assert!(s.ok);
    assert_eq!(s.result.unwrap()["unconfigured"], true);

    // 订阅照常成立：壳把它判成「运行中」，不会当成服务挂了去自愈。
    // 反证：去掉 unconfigured_dispatch 的 events.subscribe 分支 ⇒ 这里回 library_unavailable，红。
    let sub = unconfigured_dispatch(
        &req("events.subscribe", serde_json::json!({})),
        IpcClient::Shell,
        "1.0.0",
        0,
        &loc,
    )
    .await;
    assert!(sub.ok, "{:?}", sub.error);
    assert_eq!(sub.result.unwrap()["subscribed"], true);

    for m in [
        "pairing.start",
        "devices.list",
        "timeline.page",
        "logs.export",
    ] {
        let r = unconfigured_dispatch(
            &req(m, serde_json::json!({})),
            IpcClient::Shell,
            "1.0.0",
            0,
            &loc,
        )
        .await;
        assert!(!r.ok, "未配置状态不许答 {m}");
        assert_eq!(
            r.error.unwrap().reason().to_string(),
            "library_unavailable",
            "{m}"
        );
    }

    let lib = tmp.path().join("lib");
    let params = serde_json::json!({ "library": lib.to_str().unwrap() });
    let by_daemon = unconfigured_dispatch(
        &req("config.set_library", params.clone()),
        IpcClient::Daemon,
        "1.0.0",
        0,
        &loc,
    )
    .await;
    assert!(!by_daemon.ok, "daemon 自身不许写库位置");
    assert_eq!(
        by_daemon.error.unwrap().reason().to_string(),
        "role_forbidden"
    );
    assert!(store.0.lock().unwrap().is_none(), "被拒时正本不许被写");

    let by_shell = unconfigured_dispatch(
        &req("config.set_library", params),
        IpcClient::Shell,
        "1.0.0",
        0,
        &loc,
    )
    .await;
    assert!(by_shell.ok, "{:?}", by_shell.error);
    assert_eq!(
        store.0.lock().unwrap().as_deref(),
        Some(lib.to_str().unwrap().as_bytes())
    );
}

/// 令牌连接上调 `config.set_library`：测试沙盒（没有 library_location）拒绝；常驻 daemon
/// （令牌模式 = Windows / Linux 的窗口程序）照写。
#[tokio::test(flavor = "multi_thread")]
async fn set_library_is_closed_in_the_sandbox_and_open_to_the_window_program() {
    use interprocess::local_socket::tokio::prelude::*;
    use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _, BufReader};

    async fn call(endpoint: &PeerEndpoint, line: &str) -> serde_json::Value {
        let (conn, preamble) = endpoint.connect().await.unwrap();
        let (rx, mut tx) = conn.split();
        tx.write_all(format!("{}\n{line}\n", preamble.unwrap()).as_bytes())
            .await
            .unwrap();
        let mut out = String::new();
        BufReader::new(rx).read_line(&mut out).await.unwrap();
        serde_json::from_str(out.trim()).unwrap()
    }

    let dir = tempfile::tempdir().unwrap();
    let lib = dir.path().join("lib");
    let line = serde_json::json!({
        "id": "x", "method": "config.set_library", "params": { "library": lib.to_str().unwrap() }
    })
    .to_string();

    // 沙盒形状：IpcServer 不注入 library_location。
    let (_ipc, socket_name, token_hex) = server(dir.path()).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    let sandbox = PeerEndpoint::Token {
        socket_name,
        token_hex,
    };
    let r = call(&sandbox, &line).await;
    assert_eq!(r["ok"], false, "{r}");
    assert_eq!(r["error"]["reason"], "role_forbidden", "{r}");
    assert!(!lib.exists(), "被拒时什么都不建");

    // 常驻形状：注入 library_location（无安全存储 ⇒ config.toml 即正本）。
    let platform_dir = dir.path().join("platform");
    let dir2 = dir.path().join("resident");
    std::fs::create_dir_all(&dir2).unwrap();
    let db = Db::open(&dir2.join("index.sqlite")).await.unwrap();
    let (event_bus, _probe) = daemon::events::bus();
    let (pairing, pending_rx) = Pairing::new(db.clone(), transport::NodeId([0xAC; 32]), None);
    let mut ipc = IpcServer::new(
        db.clone(),
        pairing,
        DiagAgg::new(db),
        dir2.clone(),
        pending_rx,
        event_bus,
    );
    ipc.set_library_location(Arc::new(LibraryLocation::with(None, platform_dir.clone())));
    let ipc = Arc::new(ipc);
    let socket = format!("ppf-test-{}-1115r", std::process::id());
    tokio::spawn({
        let socket = socket.clone();
        async move {
            let _ = ipc.serve(&socket, [0x16; 32]).await;
        }
    });
    tokio::time::sleep(Duration::from_millis(300)).await;
    let resident = PeerEndpoint::Token {
        socket_name: socket,
        token_hex: "16".repeat(32),
    };
    let r = call(&resident, &line).await;
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(r["result"]["restart_required"], true);
    assert!(lib.is_dir() && platform_dir.join("config.toml").is_file());

    // 校验失败：原因原样带回（params.ui_error 是 keyed JSON）。
    let bad = serde_json::json!({
        "id": "y", "method": "config.set_library", "params": { "library": dir.path().join("nope").to_str().unwrap() }
    })
    .to_string();
    let r = call(&resident, &bad).await;
    assert_eq!(r["ok"], false);
    assert!(
        r["error"]["params"]["ui_error"]
            .as_str()
            .unwrap()
            .contains("ui.err_library_target_missing"),
        "{r}"
    );
}

/// #1115 方案 A：令牌端点上的未配置状态（Windows / Linux 没有 config.toml 时）。令牌文件写在
/// 平台目录、socket 名是固定的 `ppf-unconfigured`；持令牌只答 status / events.subscribe，库相关
/// 方法回 library_unavailable；令牌不对什么都不答。写库位置会让进程以 75 退出，不在进程内测
/// （见 cli_flow.rs 的非 macOS 进程级测试）。
/// 反证：serve_unconfigured_token 去掉首行令牌比对 ⇒「令牌不对」那条读到应答，红。
#[tokio::test(flavor = "multi_thread")]
async fn unconfigured_token_endpoint_answers_only_config_methods() {
    use interprocess::local_socket::tokio::prelude::*;
    use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _, BufReader};

    let tmp = tempfile::tempdir().unwrap();
    let platform_dir = tmp.path().join("platform");
    let loc = Arc::new(LibraryLocation::with(None, platform_dir.clone()));
    tokio::spawn({
        let platform_dir = platform_dir.clone();
        async move {
            let _ = daemon::ipc::serve_unconfigured_token(
                &platform_dir,
                [0x75; 32],
                "9.9.9".into(),
                loc,
            )
            .await;
        }
    });
    let token_file = platform_dir.join("ipc.token");
    let deadline = Instant::now() + Duration::from_secs(5);
    while !token_file.exists() {
        assert!(Instant::now() < deadline, "5 秒内没写出令牌文件");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let raw = std::fs::read_to_string(&token_file).unwrap();
    let mut lines = raw.lines();
    assert_eq!(lines.next(), Some(daemon::ipc::UNCONFIGURED_SOCKET_NAME));
    assert_eq!(lines.next(), Some("75".repeat(32).as_str()));
    tokio::time::sleep(Duration::from_millis(200)).await;

    async fn call(token: &str, method: &str) -> Option<serde_json::Value> {
        let endpoint = PeerEndpoint::Token {
            socket_name: daemon::ipc::UNCONFIGURED_SOCKET_NAME.into(),
            token_hex: token.into(),
        };
        let (conn, _) = endpoint.connect().await.unwrap();
        let (rx, mut tx) = conn.split();
        let line = serde_json::json!({ "id": "x", "method": method, "params": {} });
        tx.write_all(format!("{token}\n{line}\n").as_bytes())
            .await
            .unwrap();
        let mut out = String::new();
        let read = tokio::time::timeout(
            Duration::from_secs(1),
            BufReader::new(rx).read_line(&mut out),
        )
        .await;
        match read {
            Ok(Ok(n)) if n > 0 => Some(serde_json::from_str(out.trim()).unwrap()),
            _ => None,
        }
    }

    let token = "75".repeat(32);
    let s = call(&token, "status").await.expect("status 要答");
    assert_eq!(s["result"]["unconfigured"], true, "{s}");
    assert_eq!(s["result"]["version"], "9.9.9", "{s}");
    let sub = call(&token, "events.subscribe").await.expect("订阅要成立");
    assert_eq!(sub["ok"], true, "{sub}");
    for m in ["pairing.start", "devices.list", "logs.export"] {
        let r = call(&token, m).await.expect("要答");
        assert_eq!(r["error"]["reason"], "library_unavailable", "{m}: {r}");
    }
    assert!(
        call(&"00".repeat(32), "status").await.is_none(),
        "令牌不对不许答"
    );
    assert!(!platform_dir.join("config.toml").exists());
}

/// #1253：库找不到状态。`status` 报 `library_missing` 与路径，**不**报 `unconfigured`（那会把人
/// 送进首启向导，向导预填的正是这个找不到的路径）；订阅照常成立（壳判「运行中」，不去自愈拉起）；
/// 这一状态不改库位置，其余方法一律「库不可用」。
/// 反证：status 改回报 unconfigured ⇒ 第一组断言红；放行 config.set_library ⇒ 末组红。
#[test]
fn library_missing_state_reports_the_path_and_opens_nothing() {
    use daemon::ipc::library_missing_dispatch;
    let dir = std::path::Path::new("/Volumes/My Passport/P-Pass Library");
    let s = library_missing_dispatch(
        &req("status", serde_json::json!({})),
        IpcClient::Shell,
        "1.0.0",
        0,
        dir,
    );
    assert!(s.ok);
    let r = s.result.unwrap();
    assert_eq!(r["library_missing"], true);
    assert_eq!(r["library_dir"], "/Volumes/My Passport/P-Pass Library");
    assert!(r.get("unconfigured").is_none(), "{r}");

    let sub = library_missing_dispatch(
        &req("events.subscribe", serde_json::json!({})),
        IpcClient::Shell,
        "1.0.0",
        0,
        dir,
    );
    assert!(sub.ok, "{:?}", sub.error);

    for m in [
        "config.set_library",
        "pairing.start",
        "devices.list",
        "timeline.page",
    ] {
        let r = library_missing_dispatch(
            &req(m, serde_json::json!({ "library": "/tmp/x" })),
            IpcClient::Shell,
            "1.0.0",
            0,
            dir,
        );
        assert!(!r.ok, "{m} 不该在库找不到时被答");
        assert_eq!(
            r.error.unwrap().reason().to_string(),
            "library_unavailable",
            "{m}"
        );
    }
}

/// #1253：「重新检查」只看库标记——库标记回来了答 `found: true`（会话据此应答后带着库重启），
/// 只有同名空目录不算回来。反证：判据改成「目录存在」⇒ 第二段红。
#[test]
fn library_recheck_answers_from_the_library_marker() {
    use daemon::ipc::library_missing_dispatch;
    let parent = tempfile::tempdir().unwrap();
    let dir = parent.path().join("lib");
    let recheck = || {
        let r = library_missing_dispatch(
            &req("library.recheck", serde_json::json!({})),
            IpcClient::Shell,
            "1.0.0",
            0,
            &dir,
        );
        assert!(r.ok, "{:?}", r.error);
        r.result.unwrap()["found"].as_bool().unwrap()
    };
    assert!(!recheck(), "目录都不在");
    std::fs::create_dir_all(&dir).unwrap();
    assert!(!recheck(), "只有同名空目录不算回来");
    std::fs::create_dir_all(dir.join(".ppf")).unwrap();
    assert!(recheck(), "库标记回来了");
}
