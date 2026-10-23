//! Shared helpers for the flow-delivery integration tests.
//!
//! #1050: the blocking `flow.fetch` / `flow.cancel` RPCs are retired from the
//! daemon. The active protocol is `flow.offer` → poll `flow.status` (or wait
//! for the delivered push) and `flow.cancel_tuple`; these helpers express
//! exactly that, so the tests exercise the same path the phones use.
#![allow(dead_code)]

use std::path::Path;
use std::time::{Duration, Instant};

use daemon::flow_delivery::{DeliveryError, FlowDelivery};
use proto::{FlowCompletionReceipt, FlowFetchRequest, FlowTupleRef};
use storage::Db;
use transport::NodeId;

/// How long [`await_receipt`] waits for a terminal state before giving up.
const AWAIT_DEADLINE: Duration = Duration::from_secs(60);

/// The tuple identity (`queue_sequence` + `pairing_id` + `lease_token`)
/// of an offer — what `flow.status` / `flow.suspend` / `flow.cancel_tuple`
/// address.
pub fn tuple_of(request: &FlowFetchRequest) -> FlowTupleRef {
    FlowTupleRef {
        queue_sequence: request.queue_sequence,
        pairing_id: request.pairing_id.clone(),
        lease_token: request.lease_token.clone(),
    }
}

/// Poll `flow.status` for this offer's tuple until it is terminal, the way a
/// phone does: `completed` yields the durable receipt, `cancelled` is
/// [`DeliveryError::Cancelled`], an unknown tuple is
/// [`DeliveryError::GuardMismatch`]. `active` keeps waiting (a status poll
/// itself respawns a lost task, NET-15), up to [`AWAIT_DEADLINE`].
pub async fn await_receipt(
    delivery: &FlowDelivery,
    peer: NodeId,
    request: &FlowFetchRequest,
) -> Result<FlowCompletionReceipt, DeliveryError> {
    let tuple = tuple_of(request);
    let started = Instant::now();
    loop {
        let reply = delivery.status(peer, &tuple).await?;
        match reply.state.as_str() {
            "completed" => {
                return Ok(reply
                    .receipt
                    .expect("a completed status carries its receipt"))
            }
            "cancelled" => return Err(DeliveryError::Cancelled),
            "not_found" => return Err(DeliveryError::GrantNotFound),
            _ => {}
        }
        if started.elapsed() > AWAIT_DEADLINE {
            return Err(DeliveryError::Fetch(
                "no terminal state within the wait deadline".into(),
            ));
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// Total size of every file under `dir`.
pub fn dir_bytes(dir: &Path) -> u64 {
    fn walk(dir: &Path, total: &mut u64) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                walk(&path, total);
            } else if let Ok(meta) = entry.metadata() {
                *total += meta.len();
            }
        }
    }
    let mut total = 0u64;
    walk(dir, &mut total);
    total
}

/// Wait until `threshold` bytes sit under `store` while the offer's grant has
/// no receipt yet. `true` = caught the transfer mid-flight; `false` = it
/// completed first (the caller retries with a fresh attempt). Unlike a
/// status poll this never touches the delivery, so it cannot respawn a task
/// the test is about to suspend.
pub async fn wait_mid_flight(
    db: &Db,
    peer: NodeId,
    request: &FlowFetchRequest,
    store: &Path,
    threshold: u64,
) -> bool {
    let started = Instant::now();
    loop {
        let done = db
            .flow_receipt(
                peer.0.as_slice(),
                &request.pairing_id,
                request.queue_sequence as i64,
            )
            .await
            .unwrap()
            .is_some();
        if done {
            return false;
        }
        if dir_bytes(store) >= threshold {
            return true;
        }
        assert!(
            started.elapsed() < Duration::from_secs(60),
            "fetch moved no bytes toward the kill threshold in 60s"
        );
        tokio::time::sleep(Duration::from_millis(2)).await;
    }
}

// ── pairing ────────────────────────────────────────────────────────────

use daemon::pairing::{PairRejection, PairState, Pairing};
use proto::{
    methods, PairConfirmRequest, PairRequest, PairStatusReply, PairStatusRequest, PairSubmitted,
    Req, Resp,
};
use transport::{IrohTransport, Transport};

/// #1118: the code every test phone shows and every test owner types.
#[allow(dead_code)]
pub const TEST_CODE: &str = "246810";

/// #1118: the owner's "allow" in tests — typing [`TEST_CODE`].
#[allow(dead_code)]
pub fn allow() -> daemon::PairDecision {
    daemon::PairDecision::AcceptCode(TEST_CODE.into())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

fn token_bytes(token: &str) -> Vec<u8> {
    unhex(token.trim())
}

/// #1118: `req` with the phone's SPAKE2 message for [`TEST_CODE`] filled in, plus the phone's
/// half of the exchange (to finish once the desktop answered).
#[allow(dead_code)]
pub fn with_pake(
    req: &PairRequest,
    phone: NodeId,
    desk: NodeId,
) -> (PairRequest, pair_pake::PhoneStart) {
    let (start, msg_a) =
        pair_pake::PhoneStart::start(TEST_CODE, &token_bytes(&req.token), phone.0, desk.0).unwrap();
    let mut req = req.clone();
    req.pake_a = hex(&msg_a);
    (req, start)
}

/// #1050: the blocking `pair.request` reply is retired. This is the active
/// phone state machine over the real control channel — `pair.request`
/// (`ack_then_poll`) answers at once, then `pair.status` is polled until the
/// owner's verdict — folded back into the one `Resp` the older tests assert
/// on: `PairAccepted` on Allow, `NOT_AUTHORIZED` on any other ending, and the
/// submit's own error reply when the request is refused up front.
pub async fn pair_settled(
    phone: &IrohTransport,
    daemon: NodeId,
    token: &str,
    device_name: &str,
) -> Resp {
    let (req, start) = with_pake(
        &PairRequest {
            token: token.into(),
            device_name: device_name.into(),
            role: "member".into(),
            ack_then_poll: true,
            ..Default::default()
        },
        phone.node_id(),
        daemon,
    );
    let mut start = Some(start);
    let submit = ctrl_call(
        phone,
        daemon,
        methods::PAIR_REQUEST,
        serde_json::to_value(req).unwrap(),
    )
    .await;
    if !submit.ok {
        return submit;
    }
    let submitted: PairSubmitted = serde_json::from_value(submit.result.clone().unwrap()).unwrap();
    let started = Instant::now();
    loop {
        let reply = ctrl_call(
            phone,
            daemon,
            methods::PAIR_STATUS,
            serde_json::to_value(PairStatusRequest {
                request_id: submitted.request_id.clone(),
            })
            .unwrap(),
        )
        .await;
        assert!(reply.ok, "pair.status must answer ok: {reply:?}");
        let status: PairStatusReply = serde_json::from_value(reply.result.unwrap()).unwrap();
        // #1118: the owner typed the code — finish the exchange and confirm.
        if let (proto::PairStatusState::Pending, Some(pake_b)) = (status.state, &status.pake_b) {
            if let Some(s) = start.take() {
                let (check, confirm_a) = s.finish(&unhex(pake_b)).unwrap();
                let reply = ctrl_call(
                    phone,
                    daemon,
                    methods::PAIR_CONFIRM,
                    serde_json::to_value(PairConfirmRequest {
                        request_id: submitted.request_id.clone(),
                        confirm_a: hex(&confirm_a),
                    })
                    .unwrap(),
                )
                .await;
                if !reply.ok {
                    return Resp::err(
                        submit.id.clone(),
                        proto::RespError::new(proto::Reason::PairTokenInvalid),
                    );
                }
                let done: PairStatusReply = serde_json::from_value(reply.result.unwrap()).unwrap();
                check
                    .verify(&unhex(
                        done.confirm_b.as_deref().expect("accepted carries cB"),
                    ))
                    .expect("the desktop proves the same code");
                return Resp::ok(
                    submit.id.clone(),
                    serde_json::to_value(done.accepted.expect("accepted carries its payload"))
                        .unwrap(),
                );
            }
        }
        match status.state {
            proto::PairStatusState::Pending => {}
            proto::PairStatusState::Accepted => {
                return Resp::ok(
                    submit.id.clone(),
                    serde_json::to_value(status.accepted.expect("accepted carries its payload"))
                        .unwrap(),
                )
            }
            _ => {
                return Resp::err(
                    submit.id.clone(),
                    proto::RespError::new(proto::Reason::PairTokenInvalid),
                )
            }
        }
        assert!(
            started.elapsed() < Duration::from_secs(60),
            "pairing still pending after 60s"
        );
        // #1122：未配对对端按设备限速（每秒 5 个）；真手机每几秒轮询一次（Android 5 s）。
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

async fn ctrl_call(
    phone: &IrohTransport,
    daemon: NodeId,
    method: &str,
    params: serde_json::Value,
) -> Resp {
    let mut stream = phone.connect(daemon, transport::ALPN_CTRL).await.unwrap();
    let req = Req {
        id: format!("pair-{method}"),
        method: method.into(),
        params,
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

/// Queue-level counterpart for tests that drive [`Pairing`] directly, without
/// a phone: submit, then wait for the ledger entry to settle. `Ok(epoch)` on
/// Allow, `Err` for every other ending.
pub trait PairingExt {
    async fn submit_and_wait(
        &self,
        peer: NodeId,
        req: &PairRequest,
        now_ms: i64,
    ) -> Result<String, PairRejection>;
}

impl PairingExt for Pairing {
    async fn submit_and_wait(
        &self,
        peer: NodeId,
        req: &PairRequest,
        now_ms: i64,
    ) -> Result<String, PairRejection> {
        let (req, start) = with_pake(req, peer, self.node_id());
        let mut start = Some(start);
        let submission = self.submit_request(peer, &req, now_ms).await?;
        loop {
            let view = self.view(peer, &submission.request_id, now_ms);
            match view.as_ref().map(|v| &v.state) {
                Some(PairState::Pending) => {
                    // #1118: the owner typed the code — finish the exchange and confirm.
                    let pake_b = view.as_ref().and_then(|v| v.pake_b.clone());
                    // (Take the phone's half only once the answer is there: it must survive
                    // the polls before the owner typed the code.)
                    if let Some(pake_b) = pake_b {
                        let s = start.take().expect("the phone finishes the exchange once");
                        let (check, confirm_a) = s.finish(&pake_b).unwrap();
                        let done = self
                            .confirm_code(peer, &submission.request_id, &confirm_a, now_ms)
                            .await
                            .map_err(|_| PairRejection::OwnerDeclined)?;
                        check.verify(&done.confirm_b.unwrap()).unwrap();
                        if let PairState::Accepted { pairing_id } = done.state {
                            return Ok(pairing_id);
                        }
                        return Err(PairRejection::OwnerDeclined);
                    }
                }
                Some(PairState::Accepted { pairing_id }) => return Ok(pairing_id.clone()),
                _ => return Err(PairRejection::OwnerDeclined),
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }
}
