//! DAE-01/DAE-01b acceptance: single-instance discipline (newest wins).
//!
//! Two IpcServer instances share one socket name; a newer claimant takes
//! over (the older one is asked to step down), an equal/older claimant
//! stands down. step_down side effects are injected no-ops so the harness
//! survives (production exits the process, launchd relaunches).
//!
//! DAE-01b blocker① regression: each instance mints its OWN independent
//! token, and the predecessor's token is what lands in `data_dir/ipc.token`
//! (reproducing the production timeline). `claim_single_instance` reads
//! that file to authenticate — it never probes with a token of its own,
//! and a live socket it cannot authenticate is NEVER unlinked.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use daemon::{Claim, DiagAgg, IpcServer, Pairing};
use storage::Db;

fn socket_name(tag: &str) -> String {
    format!("ppf-dae-{}-{}", std::process::id(), tag)
}

// ── 版本相对推导（TAG-01 事故回归）────────────────────────────────
// 在位实例的 status 自报 CARGO_PKG_VERSION，测试里的“更新/相同/更旧”
// 必须相对它推导——此前写死 "0.2.0"/"0.1.0" 字面量，bump 0.1.0→0.2.1
// 后“newer”反而比在位旧，main 直接红（每次版本 bump 必炸的脆性）。

/// 与在位实例相同的版本（= 本 crate 编译时版本）。
fn same_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// 严格大于在位实例的版本（patch +1）。
fn newer_version() -> String {
    let mut parts: Vec<u64> = env!("CARGO_PKG_VERSION")
        .split('.')
        .map(|p| p.parse().expect("CARGO_PKG_VERSION 是纯数字三段"))
        .collect();
    *parts.last_mut().expect("非空") += 1;
    parts
        .iter()
        .map(u64::to_string)
        .collect::<Vec<_>>()
        .join(".")
}

/// 严格小于任何真实发布版本。
fn older_version() -> String {
    "0.0.1".to_string()
}

fn hex(t: &[u8; 32]) -> String {
    t.iter().map(|b| format!("{b:02x}")).collect()
}

/// Build an IpcServer whose step_down only sets a flag (no exit).
async fn mk_server(dir: &Path) -> (Arc<IpcServer>, Arc<AtomicBool>) {
    let db = Db::open_in_memory().await.unwrap();
    let (pairing, pending_rx) = Pairing::new(db.clone(), transport::NodeId([0xCC; 32]), None);
    let diag = DiagAgg::new(db.clone());
    let mut ipc = IpcServer::new(db, pairing, diag, dir.to_path_buf(), pending_rx);
    let flag = Arc::new(AtomicBool::new(false));
    let f2 = Arc::clone(&flag);
    ipc.set_step_down_exit(move || {
        f2.store(true, Ordering::SeqCst);
    });
    (Arc::new(ipc), flag)
}

#[tokio::test]
async fn newer_claimant_takes_over_older_steps_down() {
    let dir = std::env::temp_dir().join(format!("ppf-dae-t1-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let sock = socket_name("t1");

    // 老实例（v0.1.0）在岗，用**它自己的** token 服务；serve() 把该
    // token 写进 data_dir/ipc.token（生产时序：前任 token 落文件）。
    let old_token = [7u8; 32];
    let (old, old_stepped_down) = mk_server(&dir).await;
    let old_task = tokio::spawn({
        let old = Arc::clone(&old);
        let s = sock.clone();
        async move {
            let _ = old.serve(&s, old_token).await;
        }
    });
    tokio::time::sleep(Duration::from_millis(300)).await;

    // 新实例（v0.2.0）的 token 与老实例**完全独立**——claim 根本不接受
    // 自己的 token 参数，它读 ipc.token 里的前任 token 握手。
    let (newer, _) = mk_server(&dir).await;
    let new_token = [0x2A; 32];
    assert_ne!(
        new_token, old_token,
        "two instances must have independent tokens"
    );
    let claim = newer.claim_single_instance(&sock, &newer_version()).await;
    assert_eq!(claim, Claim::TookOver, "newer must take over");
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(
        old_stepped_down.load(Ordering::SeqCst),
        "older instance must have received step_down"
    );

    old_task.abort();
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn equal_or_older_claimant_stands_down() {
    let dir = std::env::temp_dir().join(format!("ppf-dae-t2-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let sock = socket_name("t2");

    // 值班实例在岗（status 报真实 CARGO_PKG_VERSION = 0.1.0）。
    let incumbent_token = [8u8; 32];
    let (incumbent, _) = mk_server(&dir).await;
    let incumbent_task = tokio::spawn({
        let i = Arc::clone(&incumbent);
        let s = sock.clone();
        async move {
            let _ = i.serve(&s, incumbent_token).await;
        }
    });
    tokio::time::sleep(Duration::from_millis(300)).await;

    let (late, _) = mk_server(&dir).await;
    // 同版本 → 后来者让位（先来者留，避免 launchd 重拉循环）。
    let claim_eq = late.claim_single_instance(&sock, &same_version()).await;
    assert_eq!(claim_eq, Claim::StandDown, "same version must stand down");
    // 低版本 → 让位。
    let claim_old = late.claim_single_instance(&sock, &older_version()).await;
    assert_eq!(claim_old, Claim::StandDown, "older must stand down");

    incumbent_task.abort();
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn dead_socket_is_cleaned_and_claimed() {
    let dir = std::env::temp_dir().join(format!("ppf-dae-t3-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let sock = socket_name("t3");

    // 无人在岗 → 直接 proceed。
    let (fresh, _) = mk_server(&dir).await;
    let claim = fresh.claim_single_instance(&sock, &same_version()).await;
    assert_eq!(claim, Claim::Proceed, "no peer → proceed");

    let _ = std::fs::remove_dir_all(&dir);
}

/// DAE-01b blocker① 反证：活 socket 用错误 token 探测（模拟旧代码用
/// 本实例随机 token 探测被拒）→ 必须 StandDown，绝不 Proceed 抢绑。
#[tokio::test]
async fn wrong_token_never_grabs_a_live_socket() {
    let dir = std::env::temp_dir().join(format!("ppf-dae-t4-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let sock = socket_name("t4");

    // 值班实例在岗，token 落文件。
    let incumbent_token = [9u8; 32];
    let (incumbent, incumbent_stepped_down) = mk_server(&dir).await;
    let incumbent_task = tokio::spawn({
        let i = Arc::clone(&incumbent);
        let s = sock.clone();
        async move {
            let _ = i.serve(&s, incumbent_token).await;
        }
    });
    tokio::time::sleep(Duration::from_millis(300)).await;

    // 模拟旧代码的随机 token：把文件里的 token 换成与值班实例无关的
    // 随机值（旧代码等效于拿本实例新随机 token 去探测）。
    let wrong_token = [0xDE; 32];
    std::fs::write(
        dir.join("ipc.token"),
        format!("{sock}\n{}\n", hex(&wrong_token)),
    )
    .unwrap();

    let (late, _) = mk_server(&dir).await;
    let claim = late.claim_single_instance(&sock, &newer_version()).await;
    assert_eq!(
        claim,
        Claim::StandDown,
        "wrong token must stand down — never Proceed and blind-grab a live socket"
    );
    assert!(
        !incumbent_stepped_down.load(Ordering::SeqCst),
        "incumbent must NOT have been asked to step down"
    );

    // 恢复前任 token 后重试 → 正常接管，证明值班实例全程存活、
    // socket 从未被 unlink 抢绑。
    std::fs::write(
        dir.join("ipc.token"),
        format!("{sock}\n{}\n", hex(&incumbent_token)),
    )
    .unwrap();
    let claim2 = late.claim_single_instance(&sock, &newer_version()).await;
    assert_eq!(
        claim2,
        Claim::TookOver,
        "with the right token, takeover works"
    );
    assert!(
        incumbent_stepped_down.load(Ordering::SeqCst),
        "incumbent stepped down on the second (authenticated) claim"
    );

    incumbent_task.abort();
    let _ = std::fs::remove_dir_all(&dir);
}
