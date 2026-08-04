//! DAE-01 acceptance: single-instance discipline (newest wins).
//!
//! Two IpcServer instances share one socket name; a newer claimant takes
//! over (the older one is asked to step down), an equal/older claimant
//! stands down. step_down side effects are injected no-ops so the harness
//! survives (production exits the process, launchd relaunches).

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use daemon::{Claim, DiagAgg, IpcServer, Pairing};
use storage::Db;

fn socket_name(tag: &str) -> String {
    format!("ppf-dae-{}-{}", std::process::id(), tag)
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
    let token = [7u8; 32];
    let token_hex: String = token.iter().map(|b| format!("{b:02x}")).collect();
    let sock = socket_name("t1");

    // 老实例（v0.1.0）在岗。
    let (old, old_stepped_down) = mk_server(&dir).await;
    let old_task = tokio::spawn({
        let old = Arc::clone(&old);
        let s = sock.clone();
        async move {
            let _ = old.serve(&s, token).await;
        }
    });
    tokio::time::sleep(Duration::from_millis(300)).await;

    // 新实例（v0.2.0）claim → 接管，老实例被要求退位。
    let (newer, _) = mk_server(&dir).await;
    let claim = newer
        .claim_single_instance(&sock, &token_hex, "0.2.0")
        .await;
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
    let token = [8u8; 32];
    let token_hex: String = token.iter().map(|b| format!("{b:02x}")).collect();
    let sock = socket_name("t2");

    // 值班实例在岗（status 报真实 CARGO_PKG_VERSION = 0.1.0）。
    let (incumbent, _) = mk_server(&dir).await;
    let incumbent_task = tokio::spawn({
        let i = Arc::clone(&incumbent);
        let s = sock.clone();
        async move {
            let _ = i.serve(&s, token).await;
        }
    });
    tokio::time::sleep(Duration::from_millis(300)).await;

    let (late, _) = mk_server(&dir).await;
    // 同版本 → 后来者让位（先来者留，避免 launchd 重拉循环）。
    let claim_eq = late
        .claim_single_instance(&sock, &token_hex, "0.1.0")
        .await;
    assert_eq!(claim_eq, Claim::StandDown, "same version must stand down");
    // 低版本 → 让位。
    let claim_old = late
        .claim_single_instance(&sock, &token_hex, "0.0.9")
        .await;
    assert_eq!(claim_old, Claim::StandDown, "older must stand down");

    incumbent_task.abort();
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn dead_socket_is_cleaned_and_claimed() {
    let dir = std::env::temp_dir().join(format!("ppf-dae-t3-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let token = [9u8; 32];
    let token_hex: String = token.iter().map(|b| format!("{b:02x}")).collect();
    let sock = socket_name("t3");

    // 无人在岗 → 直接 proceed。
    let (fresh, _) = mk_server(&dir).await;
    let claim = fresh
        .claim_single_instance(&sock, &token_hex, "0.1.0")
        .await;
    assert_eq!(claim, Claim::Proceed, "no peer → proceed");

    let _ = std::fs::remove_dir_all(&dir);
}
