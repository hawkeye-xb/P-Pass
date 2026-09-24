//! DEV-05 (#276): 待确认的配对请求在 daemon 侧永不过期——手机早放弃了，
//! 业主后点的「允许」照样生效。
//!
//! 本文件钉住**队列侧**的修复（`ipc.rs`：TTL 清扫、失效行如实报失败、
//! 同一手机新的顶掉旧的）。**请求侧**的修复（`pairing.rs`：等待有界、
//! 审计取决定时刻）见 `pairing_flow.rs` 末尾的 DEV-05 用例。

use std::sync::Arc;

use daemon::{ConfirmOutcome, DiagAgg, IpcServer, PairRejection, Pairing};
use storage::Db;

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Harness like ipc_flow's `start`, but returns the `IpcServer` handle
/// and overrides BOTH TTL seams: queue-side (`ipc_ttl_ms`, via
/// `set_pending_ttl_for_test`) and request-side (`req_ttl_ms`, via
/// `with_pending_ttl`). Two different values are what let a test
/// construct the nasty corner — a row the queue still considers fresh
/// while the request behind it already timed out — without sleeping
/// production's 110 s.
async fn start_pairing_harness(
    dir: &std::path::Path,
    _tag: &str,
    ipc_ttl_ms: i64,
    req_ttl_ms: i64,
) -> (Db, Pairing, Arc<IpcServer>) {
    let db = Db::open_in_memory().await.unwrap();
    let (event_bus, _probe) = daemon::events::bus();
    let (pairing, pending_rx) = Pairing::new(db.clone(), transport::NodeId([0xCC; 32]), None, None);
    let pairing = pairing
        .with_events(event_bus.clone())
        .with_pending_ttl(req_ttl_ms);
    let diag = DiagAgg::new(db.clone());
    let mut ipc = IpcServer::new(
        db.clone(),
        pairing.clone(),
        diag,
        dir.to_path_buf(),
        pending_rx,
        event_bus,
    );
    ipc.set_pending_ttl_for_test(ipc_ttl_ms);
    let ipc = Arc::new(ipc);
    // IpcServer::new spawns the queue drainer; nothing to serve here —
    // the tests drive confirm() the way the console confirmer in main
    // does (same shared entry point the IPC dispatch calls).
    (db, pairing, ipc)
}

/// One inbound scan parked in the queue; returns the request handle.
fn knock(
    pairing: &Pairing,
    token: [u8; 12],
    peer: u8,
    name: &str,
) -> tokio::task::JoinHandle<Result<String, PairRejection>> {
    let pairing = pairing.clone();
    let name = name.to_string();
    tokio::spawn(async move {
        let qr = pairing.start(token, now());
        let token_hex = qr.rsplit("&t=").next().unwrap().to_string();
        pairing
            .handle_request(
                transport::NodeId([peer; 32]),
                &proto::PairRequest {
                    token: token_hex,
                    device_name: name,
                    role: "member".into(),
                },
                now(),
            )
            .await
    })
}

async fn wait_pending(ipc: &Arc<IpcServer>, want: usize) {
    for _ in 0..300 {
        if ipc.pending_names().len() == want {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    panic!(
        "pending queue never reached {want}: {:?}",
        ipc.pending_names()
    );
}

/// 验收标准 1（队列侧）：超过 TTL 的行不能被批准——confirm 返回失败，
/// 不写 device 行、不轮换 pairing_epoch。
/// 反证靶子：去掉 confirm 的过期判定（`let stale = …` 恒 false），
/// 本用例在 matches!(NotFound) 处变红。
#[tokio::test(flavor = "multi_thread")]
async fn confirm_after_queue_ttl_fails_and_writes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    // queue TTL 80ms; the request side waits 30s so only the queue ages.
    let (db, pairing, ipc) = start_pairing_harness(dir.path(), "dev05-prune", 80, 30_000).await;

    let handle = knock(&pairing, [0xA1; 12], 0xD5, "超时未点的手机");
    wait_pending(&ipc, 1).await;

    tokio::time::sleep(std::time::Duration::from_millis(250)).await;
    let outcome = ipc.confirm(None, Some("超时未点的手机"), true);
    assert!(
        matches!(outcome, ConfirmOutcome::Expired(_)),
        "过期行不得还能被批准（应报 Expired=点了个死请求）: {outcome:?}"
    );
    assert!(db.get_device(&[0xD5; 32]).await.unwrap().is_none());

    // The abandoned request resolves denied on its own side; no hang,
    // no writes.
    let verdict = tokio::time::timeout(std::time::Duration::from_secs(5), handle)
        .await
        .expect("request must resolve once its queue-side peer is gone…")
        .unwrap();
    assert!(verdict.is_err(), "对端请求必须落败: {verdict:?}");
    assert!(db.get_device(&[0xD5; 32]).await.unwrap().is_none());
    assert!(
        db.pairing_epoch(&[0xD5; 32]).await.unwrap().is_none(),
        "不轮换 pairing_epoch"
    );
}

/// 简报四：行还在 TTL 内、但请求侧已经超时放弃（oneshot 接收端没了）
/// ——业主这一下点的是一个不存在的请求。必须如实失败（Expired），
/// 不再显示成功。
/// 反证靶子：旧写法 `let _ = send(…)` 吞掉 Err → confirm 返回
/// Decided → 本用例变红。
#[tokio::test(flavor = "multi_thread")]
async fn click_on_dead_request_reports_expired_not_success() {
    let dir = tempfile::tempdir().unwrap();
    // queue TTL 10 min (row stays "fresh"), request TTL 80ms — the
    // phone-side wait ends first: exactly the 竞态 window.
    let (db, pairing, ipc) = start_pairing_harness(dir.path(), "dev05-dead", 600_000, 80).await;

    let handle = knock(&pairing, [0xA2; 12], 0xD6, "先放弃的手机");
    wait_pending(&ipc, 1).await;

    // 等请求侧超时落定（pairing.rs 的 timeout 触发 → rx 被 drop）。
    let verdict = tokio::time::timeout(std::time::Duration::from_secs(5), handle)
        .await
        .expect("request-side TTL must fire")
        .unwrap();
    assert!(verdict.is_err(), "请求侧超时=拒绝: {verdict:?}");

    // 队列侧那行还在 TTL 内、还"看得见"——但点它必须失败。
    assert_eq!(ipc.pending_names(), vec!["先放弃的手机".to_string()]);
    let outcome = ipc.confirm(None, Some("先放弃的手机"), true);
    assert!(
        matches!(outcome, ConfirmOutcome::Expired(_)),
        "send 的 Err 必须暴露成失败，不许假成功: {outcome:?}"
    );
    assert!(db.get_device(&[0xD6; 32]).await.unwrap().is_none());
    assert!(ipc.pending_names().is_empty(), "失效行被这次点击带走");
}

/// 设计要点 3「新的顶掉旧的」：同一台手机连扫两次，队列只留最新一行；
/// confirm 命中的是后一次——卡面「未查实的线索」里"点到陈旧行"的歧义
/// 从根上不存在了。
/// 反证靶子：去掉入队时的同-peer 顶替，pending 会是两行、第一个断言变红。
#[tokio::test(flavor = "multi_thread")]
async fn second_scan_replaces_the_stale_row_of_the_same_phone() {
    let dir = tempfile::tempdir().unwrap();
    let (db, pairing, ipc) =
        start_pairing_harness(dir.path(), "dev05-replace", 600_000, 30_000).await;

    // 同一 peer（0xD7）扫两次（两个一次性 token）。
    let first = knock(&pairing, [0xA3; 12], 0xD7, "第一次扫码");
    wait_pending(&ipc, 1).await;
    let second = knock(&pairing, [0xA4; 12], 0xD7, "第二次扫码");
    // 顶替后队列仍是一行——等内容换成第二次。
    let mut swapped = false;
    for _ in 0..300 {
        if ipc.pending_names() == vec!["第二次扫码".to_string()] {
            swapped = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert!(
        swapped,
        "同一 node_id 只留最新一行（新的顶掉旧的）: {:?}",
        ipc.pending_names()
    );

    // 旧的那条请求：接收端被顶替时 drop → 自己落败，不悬空。
    let v1 = tokio::time::timeout(std::time::Duration::from_secs(5), first)
        .await
        .expect("被顶掉的旧请求应即时落败（channel 关闭），不许挂到 TTL")
        .unwrap();
    assert!(v1.is_err(), "被顶掉的旧请求必须落败: {v1:?}");

    // 批准命中第二次。
    let outcome = ipc.confirm(None, Some("第二次扫码"), true);
    assert!(matches!(outcome, ConfirmOutcome::Decided(_)), "{outcome:?}");
    let v2 = tokio::time::timeout(std::time::Duration::from_secs(5), second)
        .await
        .expect("眼前这次扫码应落定")
        .unwrap();
    assert!(v2.is_ok(), "眼前这次扫码正常批准成功: {v2:?}");
    let row = db.get_device(&[0xD7; 32]).await.unwrap().expect("row");
    assert_eq!(row.name, "第二次扫码");
}

/// 验收标准 2 的另一半：按 node_id 定位在多行队列里精确命中那一台
/// （不同手机并存时不串台）。
#[tokio::test(flavor = "multi_thread")]
async fn confirm_by_node_id_hits_the_right_row_among_two_phones() {
    let dir = tempfile::tempdir().unwrap();
    let (db, pairing, ipc) = start_pairing_harness(dir.path(), "dev05-two", 600_000, 30_000).await;

    let a = knock(&pairing, [0xA5; 12], 0xE5, "爸爸的手机");
    let b = knock(&pairing, [0xA6; 12], 0xE6, "妈妈的手机");
    wait_pending(&ipc, 2).await;

    let outcome = ipc.confirm(Some(&[0xE6; 32]), None, true);
    assert!(
        matches!(&outcome, ConfirmOutcome::Decided(n) if n == "妈妈的手机"),
        "{outcome:?}"
    );
    let vb = tokio::time::timeout(std::time::Duration::from_secs(5), b)
        .await
        .expect("b resolves")
        .unwrap();
    assert!(vb.is_ok());
    assert!(db.get_device(&[0xE6; 32]).await.unwrap().is_some());
    assert!(
        db.get_device(&[0xE5; 32]).await.unwrap().is_none(),
        "另一台不受影响"
    );

    // 收尾：第一条拒绝掉，任务不悬空。
    let outcome = ipc.confirm(Some(&[0xE5; 32]), None, false);
    assert!(matches!(outcome, ConfirmOutcome::Decided(_)), "{outcome:?}");
    let va = tokio::time::timeout(std::time::Duration::from_secs(5), a)
        .await
        .expect("a resolves")
        .unwrap();
    assert!(va.is_err());
}

/// 设计要点 2（daemon 侧的数据面）：pending_summary 带 requested_at /
/// expired——桌面才能把陈旧行标「已失效」而不是静默消失。
#[tokio::test(flavor = "multi_thread")]
async fn pending_summary_carries_request_time_and_expired_flag() {
    let dir = tempfile::tempdir().unwrap();
    let (_db, pairing, ipc) =
        start_pairing_harness(dir.path(), "dev05-summary", 500_000, 30_000).await;

    let handle = knock(&pairing, [0xA7; 12], 0xE7, "等待标记的手机");
    wait_pending(&ipc, 1).await;

    let rows = ipc.pending_summary().await;
    assert_eq!(rows.len(), 1);
    let row = &rows[0];
    assert!(row["requested_at"].is_i64(), "入队时刻必须上传: {row}");
    assert_eq!(row["expired"], false, "新鲜行不得标失效");

    // 收尾：拒绝掉，任务不悬空。
    let outcome = ipc.confirm(Some(&[0xE7; 32]), None, false);
    assert!(matches!(outcome, ConfirmOutcome::Decided(_)), "{outcome:?}");
    let v = tokio::time::timeout(std::time::Duration::from_secs(5), handle)
        .await
        .expect("resolves")
        .unwrap();
    assert!(v.is_err());
}

/// 简报五：三个定位分支——(None, None) 取队首的回退同样过 TTL 清扫，
/// 不许成为绕过新口径的后门。多机并存时队首=最早那台（既有语义不动），
/// 同一手机连扫两次时队首=最新那行（顶替后队列只有一行）。
#[tokio::test(flavor = "multi_thread")]
async fn queue_head_fallback_respects_sweep_and_replacement() {
    let dir = tempfile::tempdir().unwrap();
    let (_db, pairing, ipc) =
        start_pairing_harness(dir.path(), "dev05-head", 600_000, 30_000).await;

    let a = knock(&pairing, [0xA8; 12], 0xE8, "队首手机A");
    // A 先入队再放 B：两个 spawn 并发时入队先后由调度决定（Windows CI 上实测会倒过来）。
    wait_pending(&ipc, 1).await;
    let b = knock(&pairing, [0xA9; 12], 0xE9, "队首手机B");
    wait_pending(&ipc, 2).await;

    // 无参 confirm → 队首（A）——既有语义。
    let outcome = ipc.confirm(None, None, false);
    assert!(
        matches!(&outcome, ConfirmOutcome::Decided(n) if n == "队首手机A"),
        "{outcome:?}"
    );
    let va = tokio::time::timeout(std::time::Duration::from_secs(5), a)
        .await
        .expect("resolves")
        .unwrap();
    assert!(va.is_err());

    // 同一手机（B, 0xE9）连扫两次 → 队列回到一行，且是第二次那行；
    // 无参 confirm 走队首分支也只会命中新行（后门不存在）。
    let b2 = knock(&pairing, [0xAA; 12], 0xE9, "第二次扫码的B");
    let mut swapped = false;
    for _ in 0..300 {
        if ipc.pending_names() == vec!["第二次扫码的B".to_string()] {
            swapped = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert!(
        swapped,
        "顶替后队首分支面对的应是新行: {:?}",
        ipc.pending_names()
    );
    let outcome = ipc.confirm(None, None, true);
    assert!(
        matches!(&outcome, ConfirmOutcome::Decided(n) if n == "第二次扫码的B"),
        "{outcome:?}"
    );
    let vb = tokio::time::timeout(std::time::Duration::from_secs(5), b)
        .await
        .expect("b resolves")
        .unwrap();
    assert!(vb.is_err(), "被顶掉的旧行落败");
    let vb2 = tokio::time::timeout(std::time::Duration::from_secs(5), b2)
        .await
        .expect("b2 resolves")
        .unwrap();
    assert!(vb2.is_ok(), "新行走队首分支正常批准: {vb2:?}");
}
