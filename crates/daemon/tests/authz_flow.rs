//! T-030 acceptance: the authz checkpoint over a real (loopback) iroh
//! connection — unpaired NodeId gets `NOT_AUTHORIZED`, paired devices get
//! exactly their role's methods, revocation slams the door, and every
//! denial leaves a diag event.

use daemon::Router;
use proto::{codes, Req, Resp};
use storage::{Db, Device, Role};
use transport::{IrohTransport, Transport, TransportConfig};

async fn start_daemon(db: Db) -> (IrohTransport, transport::PeerAddr) {
    let tp = IrohTransport::bind(TransportConfig::loopback(vec![transport::ALPN_CTRL.into()]))
        .await
        .unwrap();
    let addr = tp.local_addr();
    let router = Router::new(db, "test-daemon");
    let tp2 = tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });
    (tp, addr)
}

async fn client() -> IrohTransport {
    IrohTransport::bind(TransportConfig::loopback(vec![transport::ALPN_CTRL.into()]))
        .await
        .unwrap()
}

/// One request over a fresh stream; returns the response.
async fn call(tp: &IrohTransport, daemon: transport::NodeId, method: &str) -> Resp {
    let mut stream = tp.connect(daemon, transport::ALPN_CTRL).await.unwrap();
    let req = Req {
        id: format!("req-{method}"),
        method: method.into(),
        params: serde_json::Value::Null,
        ..Default::default()
    };
    stream
        .send_frame(&proto::codec::encode(&req).unwrap())
        .await
        .unwrap();
    stream.finish().unwrap();
    let frame = stream.recv_frame().await.unwrap().expect("a response");
    proto::codec::decode::<Resp>(&frame).unwrap()
}

fn paired(node_id: &[u8; 32], role: Role) -> Device {
    Device {
        node_id: node_id.to_vec(),
        name: "test-device".into(),
        role,
        paired_at: 1,
        last_seen: None,
        revoked: false,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn unpaired_node_gets_not_authorized() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr) = start_daemon(db.clone()).await;
    let ctp = client().await;
    ctp.add_peer(daddr);

    let resp = call(&ctp, dtp.node_id(), "timeline.page").await;
    assert!(!resp.ok);
    let err = resp.error.expect("error payload");
    assert_eq!(err.code, codes::NOT_AUTHORIZED);
    assert_eq!(err.msg_key, "err.not_paired");

    // The denial is on the diagnostic record (§2.3: 记诊断事件).
    let events = db.list_diag(10).await.unwrap();
    assert!(
        events.iter().any(|e| e.kind == "authz.denied"
            && e.detail.as_deref().unwrap_or("").contains("timeline.page")),
        "denial must be recorded: {events:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn unpaired_node_may_still_say_hello() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr) = start_daemon(db).await;
    let ctp = client().await;
    ctp.add_peer(daddr);

    let resp = call(&ctp, dtp.node_id(), "hello").await;
    assert!(resp.ok, "hello is the capability handshake: {resp:?}");
    let hello: proto::Hello = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert_eq!(hello.proto_ver, proto::PROTO_VER);
    assert!(hello.capabilities.contains(&"thumbnail.v1".to_string()));
}

#[tokio::test(flavor = "multi_thread")]
async fn viewer_browses_but_backup_is_denied() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr) = start_daemon(db.clone()).await;
    let ctp = client().await;
    ctp.add_peer(daddr);
    db.upsert_device(&paired(&ctp.node_id().0, Role::Viewer))
        .await
        .unwrap();

    // Browsing methods reach dispatch (not implemented yet → err.unsupported,
    // but crucially NOT not_authorized).
    let resp = call(&ctp, dtp.node_id(), "timeline.page").await;
    let err = resp.error.expect("unimplemented for now");
    assert_eq!(err.code, codes::INVALID_REQUEST);
    assert_eq!(err.msg_key, "err.unsupported");

    // backup.* is cut off at the checkpoint.
    let resp = call(&ctp, dtp.node_id(), "backup.begin").await;
    let err = resp.error.expect("denied");
    assert_eq!(err.code, codes::NOT_AUTHORIZED);
    assert_eq!(err.msg_key, "err.not_authorized");
}

#[tokio::test(flavor = "multi_thread")]
async fn revoked_device_is_shut_out_at_once() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr) = start_daemon(db.clone()).await;
    let ctp = client().await;
    ctp.add_peer(daddr);
    db.upsert_device(&paired(&ctp.node_id().0, Role::Member))
        .await
        .unwrap();

    // While paired: allowed through the checkpoint.
    let resp = call(&ctp, dtp.node_id(), "hello").await;
    assert!(resp.ok);

    // Revoke → 吊销即拒连, even for hello.
    assert!(db.revoke(&ctp.node_id().0).await.unwrap());
    let resp = call(&ctp, dtp.node_id(), "hello").await;
    let err = resp.error.expect("denied after revocation");
    assert_eq!(err.code, codes::NOT_AUTHORIZED);
    assert_eq!(err.msg_key, "err.not_authorized");
}
