//! D6 / brief §5.6：Windows Hello 核验的**挑战状态机**（与平台无关）。
//!
//! 服务端流程（brief 原文）：
//!   1. 壳先展示要做什么（设备名、指纹前缀），用户点「批准」；
//!   2. 壳向服务要一次性挑战：随机 nonce，绑定「方法 + 参数摘要 + 过期时间」；
//!   3. 壳调 Hello 对挑战签名（系统弹窗，本人确认）；
//!   4. 壳把签名随请求发给服务；
//!   5. 服务验签，核对 nonce 未用过、未过期、方法与参数一致，才执行。
//!
//! 这里只做**状态机**：挑战的签发、一次性消费、过期、绑定校验。签名验证由调用方以闭包
//! 传入（服务用 ring 验 RSA PKCS#1 v1.5 / SHA-256，见 #1156 的实测：Hello 的
//! `RequestSignAsync` 就是这个算法）。这样纯逻辑可以单测，不把 crypto 依赖带进 platform。
//!
//! 非随机性由调用方负责：`nonce` 由服务用系统 CSPRNG 生成后传进来。这个模块不「造随机」，
//! 免得悄悄用一个不合格的源。

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::SystemTime;

/// 核验失败的原因。调用方据此记审计；**任何一种都不执行操作**。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HelloError {
    /// 没有这个 nonce（没签发过、已被消费、或已被清理）。
    Unknown,
    /// 过期（含时钟回拨：`now` 早于签发时间也算）。
    Expired,
    /// 同一个 nonce 被消费过（重放）。
    Replayed,
    /// 方法不一致（拿批准配对的挑战去解除配对）。
    MethodMismatch,
    /// 参数摘要不一致（批准的是 A 设备，签的是 B 设备）。
    ParamsMismatch,
    /// 签名验不过。
    BadSignature,
}

impl HelloError {
    /// 写审计用的一句话原因（不含 nonce 内容）。
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unknown => "unknown-nonce",
            Self::Expired => "expired",
            Self::Replayed => "replayed",
            Self::MethodMismatch => "method-mismatch",
            Self::ParamsMismatch => "params-mismatch",
            Self::BadSignature => "bad-signature",
        }
    }
}

struct Pending {
    method: String,
    params_digest: [u8; 32],
    issued_at: SystemTime,
    expires_at: SystemTime,
}

/// 一次挑战的签发与消费。进程内、`Send + Sync`，由 daemon 持有。
#[derive(Default)]
pub struct ChallengeStore {
    pending: Mutex<HashMap<[u8; 32], Pending>>,
}

impl ChallengeStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// 登记一次挑战。同一 nonce 重复登记视为调用方错误（返回 `Replayed`）。
    ///
    /// 过期时间必须晚于签发时间；否则返回 `Expired`，不登记。
    pub fn issue(
        &self,
        nonce: [u8; 32],
        method: &str,
        params_digest: [u8; 32],
        issued_at: SystemTime,
        expires_at: SystemTime,
    ) -> Result<(), HelloError> {
        if expires_at <= issued_at {
            return Err(HelloError::Expired);
        }
        let mut pending = self.pending.lock().expect("challenge lock");
        if pending.contains_key(&nonce) {
            return Err(HelloError::Replayed);
        }
        pending.insert(
            nonce,
            Pending {
                method: method.to_string(),
                params_digest,
                issued_at,
                expires_at,
            },
        );
        Ok(())
    }

    /// 验签并**消费**挑战。只有全部通过才返回 `Ok(())`。
    ///
    /// 顺序固定：不存在/过期/方法/参数 → 验签 → 消费。验签失败也会把这条挑战**删掉**
    /// （一次机会，不给暴力试签名的窗口）。
    pub fn verify_and_consume<V>(
        &self,
        nonce: [u8; 32],
        method: &str,
        params_digest: [u8; 32],
        now: SystemTime,
        verify_signature: V,
    ) -> Result<(), HelloError>
    where
        V: FnOnce(&[u8; 32]) -> bool,
    {
        let pending = {
            let mut map = self.pending.lock().expect("challenge lock");
            let Some(entry) = map.remove(&nonce) else {
                return Err(HelloError::Unknown);
            };
            entry
        };
        // 从这里开始挑战已被移出：无论成败都不能再用第二次。
        if now < pending.issued_at || now >= pending.expires_at {
            return Err(HelloError::Expired);
        }
        if pending.method != method {
            return Err(HelloError::MethodMismatch);
        }
        if pending.params_digest != params_digest {
            return Err(HelloError::ParamsMismatch);
        }
        if !verify_signature(&nonce) {
            return Err(HelloError::BadSignature);
        }
        Ok(())
    }

    /// 清掉已过期的挑战（daemon 定期调用，防止没人认领的挑战一直占内存）。
    pub fn prune(&self, now: SystemTime) -> usize {
        let mut map = self.pending.lock().expect("challenge lock");
        let before = map.len();
        map.retain(|_, p| now < p.expires_at);
        before - map.len()
    }

    /// 当前未消费的挑战数（诊断用）。
    pub fn len(&self) -> usize {
        self.pending.lock().map(|m| m.len()).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn t0() -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000)
    }
    fn n(byte: u8) -> [u8; 32] {
        [byte; 32]
    }
    fn d(byte: u8) -> [u8; 32] {
        [byte; 32]
    }

    fn store_with(nonce: [u8; 32], method: &str, params: [u8; 32]) -> ChallengeStore {
        let store = ChallengeStore::new();
        store
            .issue(nonce, method, params, t0(), t0() + Duration::from_secs(120))
            .expect("issue");
        store
    }

    #[test]
    fn happy_path_consumes_once() {
        let store = store_with(n(1), "pairing.confirm", d(7));
        assert_eq!(
            store.verify_and_consume(n(1), "pairing.confirm", d(7), t0(), |_| true),
            Ok(())
        );
        assert_eq!(
            store.verify_and_consume(n(1), "pairing.confirm", d(7), t0(), |_| true),
            Err(HelloError::Unknown),
            "第二次必须找不到（已消费）"
        );
        assert!(store.is_empty());
    }

    /// 反证：重放同一个签名不行。这里覆盖「签了名但挑战已被用掉」。
    #[test]
    fn replay_after_success_is_rejected() {
        let store = store_with(n(2), "device.revoke", d(1));
        assert!(store
            .verify_and_consume(n(2), "device.revoke", d(1), t0(), |_| true)
            .is_ok());
        assert_eq!(
            store.verify_and_consume(n(2), "device.revoke", d(1), t0(), |_| true),
            Err(HelloError::Unknown)
        );
        // 还在 pending 时重复登记同一个 nonce 是调用方错误；已消费后重新签发由调用方
        // 自己保证新鲜随机数（这里不维护「用过的 nonce」表，避免无界增长）。
        let store2 = store_with(n(9), "device.revoke", d(1));
        assert_eq!(
            store2.issue(
                n(9),
                "device.revoke",
                d(1),
                t0(),
                t0() + Duration::from_secs(10)
            ),
            Err(HelloError::Replayed)
        );
    }

    #[test]
    fn expired_challenge_is_rejected() {
        let store = store_with(n(3), "pairing.confirm", d(7));
        let late = t0() + Duration::from_secs(121);
        assert_eq!(
            store.verify_and_consume(n(3), "pairing.confirm", d(7), late, |_| true),
            Err(HelloError::Expired)
        );
    }

    #[test]
    fn clock_rollback_is_expired_not_valid() {
        let store = store_with(n(4), "pairing.confirm", d(7));
        let before_issue = t0() - Duration::from_secs(1);
        assert_eq!(
            store.verify_and_consume(n(4), "pairing.confirm", d(7), before_issue, |_| true),
            Err(HelloError::Expired)
        );
    }

    #[test]
    fn method_and_params_are_bound() {
        let store = store_with(n(5), "pairing.confirm", d(7));
        assert_eq!(
            store.verify_and_consume(n(5), "device.revoke", d(7), t0(), |_| true),
            Err(HelloError::MethodMismatch)
        );
        let store = store_with(n(6), "pairing.confirm", d(7));
        assert_eq!(
            store.verify_and_consume(n(6), "pairing.confirm", d(8), t0(), |_| true),
            Err(HelloError::ParamsMismatch)
        );
    }

    /// 反证：签名错必须拒，并且这条挑战被作废（不给暴力试签名的窗口）。
    #[test]
    fn bad_signature_is_rejected_and_burns_the_challenge() {
        let store = store_with(n(7), "pairing.confirm", d(7));
        assert_eq!(
            store.verify_and_consume(n(7), "pairing.confirm", d(7), t0(), |_| false),
            Err(HelloError::BadSignature)
        );
        assert_eq!(
            store.verify_and_consume(n(7), "pairing.confirm", d(7), t0(), |_| true),
            Err(HelloError::Unknown)
        );
    }

    #[test]
    fn prune_drops_only_expired() {
        let store = ChallengeStore::new();
        store
            .issue(
                n(10),
                "pairing.confirm",
                d(1),
                t0(),
                t0() + Duration::from_secs(10),
            )
            .unwrap();
        store
            .issue(
                n(11),
                "pairing.confirm",
                d(1),
                t0(),
                t0() + Duration::from_secs(1000),
            )
            .unwrap();
        assert_eq!(store.prune(t0() + Duration::from_secs(11)), 1);
        assert_eq!(store.len(), 1);
    }

    #[test]
    fn issue_with_non_future_expiry_is_rejected() {
        let store = ChallengeStore::new();
        assert_eq!(
            store.issue(n(12), "pairing.confirm", d(1), t0(), t0()),
            Err(HelloError::Expired)
        );
        assert!(store.is_empty());
    }
}
