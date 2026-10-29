//! #1122：配对入口按需开放——入站连接的准入判据（装到 transport 的 iroh
//! after_handshake 钩子上，读任何请求之前判定）。
//!
//! - 有配对记录（授权内存副本）的设备：放行全部协议。
//! - 没有的：只在配对窗口内（二维码显示中，或它自己的配对申请尚未结束）放行
//!   控制面，且只能走配对流程那几个方法（authz）、帧上限几 KB、按设备限速
//!   （`frame_limits`）。
//! - 其余在握手完成时即被拒（关闭码 `transport::NOT_PAIRED_CLOSE_CODE`），并记一条 info 日志：
//!   对端前缀 + 原因（#1264，[`crate::pairing::WindowClosed`]）。

use std::sync::Arc;

use storage::Db;

use crate::blobs_gate::peer_prefix;
use crate::pairing::Pairing;

pub fn predicate(
    db: Db,
    pairing: Pairing,
    now: impl Fn() -> i64 + Send + Sync + 'static,
) -> transport::Admission {
    Arc::new(move |peer, alpn| {
        if db.active_pairing(&peer.0).is_some() {
            return true;
        }
        if alpn != transport::ALPN_CTRL.as_bytes() {
            tracing::info!(
                "#1264 admission: refused unpaired peer={} (not the control channel)",
                peer_prefix(peer)
            );
            return false;
        }
        match pairing.admission(peer, now()) {
            Ok(()) => true,
            Err(why) => {
                // #1264：被拒的手机只收到关闭码；为什么拒，只有这里知道——留一条可查的日志。
                // 同一台反复重拨是同一行，由日志层折叠（log_guard）。
                tracing::info!(
                    "#1264 admission: refused unpaired peer={} ({why})",
                    peer_prefix(peer)
                );
                false
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;

    #[derive(Clone, Default)]
    struct LogBuf(Arc<Mutex<Vec<u8>>>);
    impl std::io::Write for LogBuf {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(b);
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    /// #1264：握手时拒掉未配对的手机，日志里留一条：对端前缀 + 原因；放行时不记。
    /// 反证：删掉 predicate 里的 `tracing::info!`，第一条断言变红。
    #[tokio::test]
    async fn a_refused_peer_leaves_one_info_line_with_its_prefix_and_reason() {
        let buf = LogBuf::default();
        let sink = buf.clone();
        let subscriber = tracing_subscriber::fmt()
            .with_ansi(false)
            .with_max_level(tracing::Level::INFO)
            .with_writer(move || sink.clone())
            .finish();
        // Same reason as query.rs's log contract: a second dispatcher keeps callsite interest from
        // being cached as `never` by a parallel test without a subscriber.
        let _second = tracing::Dispatch::new(tracing_subscriber::registry());
        let _guard = tracing::subscriber::set_default(subscriber);

        let db = Db::open_in_memory().await.unwrap();
        let (pairing, _rx) = Pairing::new(db.clone(), transport::NodeId([0xAB; 32]), None);
        let clock = Arc::new(std::sync::atomic::AtomicI64::new(1_000));
        let now = {
            let clock = clock.clone();
            move || clock.load(std::sync::atomic::Ordering::SeqCst)
        };
        let admit = predicate(db, pairing.clone(), now);
        let ctrl = transport::ALPN_CTRL.as_bytes();
        let phone = transport::NodeId([0x5c; 32]);

        pairing.start([0x11; 12], 1_000);
        assert!(admit(phone, ctrl));
        clock.store(
            1_000 + crate::pairing::TOKEN_TTL_MS + 1,
            std::sync::atomic::Ordering::SeqCst,
        );
        assert!(!admit(phone, ctrl), "码过期后被拒");

        let log = String::from_utf8(buf.0.lock().unwrap().clone()).unwrap();
        let lines: Vec<_> = log.lines().filter(|l| l.contains("admission")).collect();
        assert_eq!(lines.len(), 1, "放行不记、拒绝记一条:\n{log}");
        assert!(lines[0].contains("INFO"), "{log}");
        assert!(lines[0].contains("peer=5c5c5c5c"), "{log}");
        assert!(lines[0].contains("QR code expired"), "{log}");
        assert!(!log.contains(&"5c".repeat(5)), "只记前 4 字节:\n{log}");
    }
}
