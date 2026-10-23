//! #1122：配对入口按需开放——入站连接的准入判据（装到 transport 的 iroh
//! after_handshake 钩子上，读任何请求之前判定）。
//!
//! - 有配对记录（授权内存副本）的设备：放行全部协议。
//! - 没有的：只在配对窗口内（二维码显示中，或它自己的配对申请尚未结束）放行
//!   控制面，且只能走配对流程那几个方法（authz）、帧上限几 KB、按设备限速
//!   （`frame_limits`）。
//! - 其余在握手完成时即被拒（关闭码 `transport::NOT_PAIRED_CLOSE_CODE`）。

use std::sync::Arc;

use storage::Db;

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
        alpn == transport::ALPN_CTRL.as_bytes() && pairing.admits(peer, now())
    })
}
