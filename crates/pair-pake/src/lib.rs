//! #1118：配对验证码——SPAKE2（RustCrypto `spake2` 0.4，Ed25519 群）加 RFC 9382 式密钥确认。
//!
//! 角色：手机 = A（生成并显示 6 位码），电脑 = B（用户在电脑上输入这个码）。
//!
//! - 口令 `w = 码(ASCII) ‖ 0x00 ‖ 二维码令牌(原始字节)`：验证码绑定在这一次配对会话上（同 Magic
//!   Wormhole 把 nameplate 一起绑进口令），别的二维码的会话不能复用这个码。
//! - 身份：A = 手机 NodeId、B = 电脑 NodeId（各 32 字节）。两端只取经 QUIC/TLS 认证出来的对端
//!   NodeId，不信消息里自报的值；身份进 SPAKE2 的 transcript（RFC 9382 §3.3 的要求）。
//! - 密钥确认（RFC 9382 §3.3 / §4 的结构）：`KcA ‖ KcB = HKDF-SHA256(K, info)`，
//!   `cA = HMAC(KcA, TT)`、`cB = HMAC(KcB, TT)`；`TT` 是带 8 字节小端长度前缀的字段串
//!   （协议标签、令牌、两个 NodeId、两条 SPAKE2 消息），没有拼接歧义。
//! - 顺序（由类型保证，不靠调用方自觉）：手机先发 `cA`；电脑**验过 `cA` 才产出 `cB`**；手机验
//!   `cB` 才算完成。电脑在验证 `cA` 之前不发出任何由 K 派生的东西。
//! - 一次猜测：主动攻击者每次会话只能试一个码（SPAKE2 的性质）；电脑验 `cA` 失败即作废这次申请
//!   与令牌（由调用方执行，见 daemon `pairing.rs`）。
//! - 低阶点（含单位元）在交给 spake2 之前就拒绝——spake2 0.4 只做点解压，不做子群检查。
//!
//! 没有经过独立审计的 Rust PAKE 实现可用（接受理由见 #1118）：版本钉死、对抗测试兜底。

use hmac::{Hmac, Mac};
use sha2::Sha256;
use spake2::{Ed25519Group, Identity, Password, Spake2};

/// 验证码位数。
pub const CODE_DIGITS: usize = 6;
/// SPAKE2 消息长度：1 字节角色 + 32 字节压缩点。
pub const MSG_LEN: usize = 33;
/// 确认消息长度（HMAC-SHA256）。
pub const CONFIRM_LEN: usize = 32;

const PROTOCOL: &[u8] = b"ppass/pair/v1";
const CONFIRM_INFO: &[u8] = b"ppass/pair/v1 key confirmation";

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum PakeError {
    /// 验证码不是 6 位数字。
    #[error("pairing code must be {CODE_DIGITS} digits")]
    BadCode,
    /// 对端的 SPAKE2 消息长度、角色或点不合法（含低阶点）。
    #[error("malformed pairing message")]
    BadMessage,
    /// 确认消息对不上：码不对，或任一方的身份 / 令牌 / 消息不一致。
    #[error("pairing confirmation does not match")]
    ConfirmMismatch,
    /// 系统随机数不可用。
    #[error("system randomness unavailable")]
    Random,
}

/// 均匀随机的 6 位验证码（拒绝采样，没有取模偏置）。
pub fn generate_code() -> Result<String, PakeError> {
    const LIMIT: u32 = u32::MAX - (u32::MAX % 1_000_000);
    loop {
        let mut b = [0u8; 4];
        getrandom::getrandom(&mut b).map_err(|_| PakeError::Random)?;
        let v = u32::from_le_bytes(b);
        if v < LIMIT {
            return Ok(format!("{:06}", v % 1_000_000));
        }
    }
}

fn password(code: &str, token: &[u8]) -> Result<Password, PakeError> {
    if code.len() != CODE_DIGITS || !code.bytes().all(|b| b.is_ascii_digit()) {
        return Err(PakeError::BadCode);
    }
    let mut w = Vec::with_capacity(CODE_DIGITS + 1 + token.len());
    w.extend_from_slice(code.as_bytes());
    w.push(0);
    w.extend_from_slice(token);
    Ok(Password::new(w))
}

/// 对端消息：长度、角色字节、点可解压、不是低阶点、且在素数阶子群里（RFC 9382 §7；#1149）。
fn check_peer_msg(msg: &[u8], side: u8) -> Result<(), PakeError> {
    if msg.len() != MSG_LEN || msg[0] != side {
        return Err(PakeError::BadMessage);
    }
    let mut bytes = [0u8; 32];
    bytes.copy_from_slice(&msg[1..]);
    let point = curve25519_dalek::edwards::CompressedEdwardsY(bytes)
        .decompress()
        .ok_or(PakeError::BadMessage)?;
    // 低阶点（含单位元）与「素数阶点 + 低阶分量」的混合点都不是合法的 SPAKE2 消息。
    // `is_torsion_free` 是 dalek 现成的素数阶子群判定（点乘 ℓ 得单位元），低阶点
    // 单独列出只为保留原来的明确语义。
    if point.is_small_order() || !point.is_torsion_free() {
        return Err(PakeError::BadMessage);
    }
    Ok(())
}

const SIDE_A: u8 = 0x41;
const SIDE_B: u8 = 0x42;

/// 一次配对会话的公开上下文：令牌与双方身份。
#[derive(Clone)]
struct Context {
    token: Vec<u8>,
    phone: [u8; 32],
    desk: [u8; 32],
}

impl Context {
    /// RFC 9382 式 TT：每个字段前缀 8 字节小端长度。
    fn transcript(&self, msg_a: &[u8], msg_b: &[u8]) -> Vec<u8> {
        let mut tt = Vec::new();
        for field in [
            PROTOCOL,
            &self.token[..],
            &self.phone[..],
            &self.desk[..],
            msg_a,
            msg_b,
        ] {
            tt.extend_from_slice(&(field.len() as u64).to_le_bytes());
            tt.extend_from_slice(field);
        }
        tt
    }
}

struct Confirmations {
    /// 手机的确认 cA。
    a: [u8; CONFIRM_LEN],
    /// 电脑的确认 cB。
    b: [u8; CONFIRM_LEN],
}

fn confirmations(key: &[u8], tt: &[u8]) -> Confirmations {
    let hk = hkdf::Hkdf::<Sha256>::new(None, key);
    let mut okm = [0u8; 2 * CONFIRM_LEN];
    hk.expand(CONFIRM_INFO, &mut okm)
        .expect("64 bytes is a valid HKDF-SHA256 output length");
    let mac = |k: &[u8]| -> [u8; CONFIRM_LEN] {
        let mut m = <Hmac<Sha256> as Mac>::new_from_slice(k).expect("HMAC takes any key length");
        m.update(tt);
        m.finalize().into_bytes().into()
    };
    Confirmations {
        a: mac(&okm[..CONFIRM_LEN]),
        b: mac(&okm[CONFIRM_LEN..]),
    }
}

/// 常量时间比较（hmac 的 verify 走 subtle）。
fn equal_ct(expected: &[u8; CONFIRM_LEN], got: &[u8]) -> bool {
    if got.len() != CONFIRM_LEN {
        return false;
    }
    let mut a = <Hmac<Sha256> as Mac>::new_from_slice(b"ppass/pair/v1 compare")
        .expect("HMAC takes any key length");
    a.update(expected);
    let tag = a.finalize().into_bytes();
    let mut b = <Hmac<Sha256> as Mac>::new_from_slice(b"ppass/pair/v1 compare")
        .expect("HMAC takes any key length");
    b.update(got);
    b.verify(&tag).is_ok()
}

/// 手机一侧，第一步：生成 X。
pub struct PhoneStart {
    spake: Spake2<Ed25519Group>,
    ctx: Context,
    msg_a: Vec<u8>,
}

impl PhoneStart {
    /// `code` 是手机生成的 6 位码，`token` 是二维码里的一次性令牌（原始字节），`phone` / `desk`
    /// 是双方 NodeId。返回这一步和要发给电脑的消息 `pake_a`。
    pub fn start(
        code: &str,
        token: &[u8],
        phone: [u8; 32],
        desk: [u8; 32],
    ) -> Result<(Self, Vec<u8>), PakeError> {
        let pw = password(code, token)?;
        let (spake, msg_a) =
            Spake2::<Ed25519Group>::start_a(&pw, &Identity::new(&phone), &Identity::new(&desk));
        let ctx = Context {
            token: token.to_vec(),
            phone,
            desk,
        };
        Ok((
            Self {
                spake,
                ctx,
                msg_a: msg_a.clone(),
            },
            msg_a,
        ))
    }

    /// 收到电脑的 `pake_b`：派生密钥，交出 `cA`（发给电脑）和等着验 `cB` 的下一步。
    pub fn finish(self, msg_b: &[u8]) -> Result<(PhoneConfirm, [u8; CONFIRM_LEN]), PakeError> {
        check_peer_msg(msg_b, SIDE_B)?;
        let key = self
            .spake
            .finish(msg_b)
            .map_err(|_| PakeError::BadMessage)?;
        let c = confirmations(&key, &self.ctx.transcript(&self.msg_a, msg_b));
        Ok((PhoneConfirm { expect_b: c.b }, c.a))
    }
}

/// 手机一侧，最后一步：验电脑的 `cB`。
pub struct PhoneConfirm {
    expect_b: [u8; CONFIRM_LEN],
}

impl PhoneConfirm {
    /// 对上才算配对完成；对不上说明电脑并不知道这个码（或会话被篡改）。
    pub fn verify(&self, confirm_b: &[u8]) -> Result<(), PakeError> {
        if equal_ct(&self.expect_b, confirm_b) {
            Ok(())
        } else {
            Err(PakeError::ConfirmMismatch)
        }
    }
}

/// 电脑一侧：用户输入码之后，对手机的 `pake_a` 作答。
pub struct Desktop {
    expect_a: [u8; CONFIRM_LEN],
    confirm_b: [u8; CONFIRM_LEN],
}

impl Desktop {
    /// `code` 是用户在电脑上输入的码；`phone` 取自这次申请的认证连接对端，`desk` 是本机 NodeId。
    /// 返回会话和要交给手机的 `pake_b`。码不对在这一步发现不了——要等 [`Self::verify`]。
    pub fn respond(
        code: &str,
        token: &[u8],
        phone: [u8; 32],
        desk: [u8; 32],
        msg_a: &[u8],
    ) -> Result<(Self, Vec<u8>), PakeError> {
        let pw = password(code, token)?;
        check_peer_msg(msg_a, SIDE_A)?;
        let (spake, msg_b) =
            Spake2::<Ed25519Group>::start_b(&pw, &Identity::new(&phone), &Identity::new(&desk));
        let key = spake.finish(msg_a).map_err(|_| PakeError::BadMessage)?;
        let ctx = Context {
            token: token.to_vec(),
            phone,
            desk,
        };
        let c = confirmations(&key, &ctx.transcript(msg_a, &msg_b));
        Ok((
            Self {
                expect_a: c.a,
                confirm_b: c.b,
            },
            msg_b,
        ))
    }

    /// 验手机的 `cA`；**只有对上了**才交出 `cB`。消耗会话：一次申请只验一次（输错即作废）。
    pub fn verify(self, confirm_a: &[u8]) -> Result<[u8; CONFIRM_LEN], PakeError> {
        if equal_ct(&self.expect_a, confirm_a) {
            Ok(self.confirm_b)
        } else {
            Err(PakeError::ConfirmMismatch)
        }
    }
}

/// #1118：NodeId 的人眼可读指纹——两端显示「这台电脑 / 这台手机」的身份标识用，只在这里定义一次。
/// 取 NodeId（64 位 hex）前 8 位，大写，四位一组：`AB12 CD34`。不是 64 位 hex 就原样大写返回前 8 位。
pub fn node_fingerprint(node_hex: &str) -> String {
    let head: String = node_hex
        .trim()
        .chars()
        .filter(|c| c.is_ascii_hexdigit())
        .take(8)
        .collect::<String>()
        .to_ascii_uppercase();
    if head.len() <= 4 {
        return head;
    }
    format!("{} {}", &head[..4], &head[4..])
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOKEN: [u8; 12] = [7; 12];
    const PHONE: [u8; 32] = [0xA1; 32];
    const DESK: [u8; 32] = [0xB2; 32];

    /// 跑一遍：手机用 `phone_code`、电脑用 `desk_code`，可分别指定两侧看到的身份与令牌。
    #[allow(clippy::type_complexity)]
    fn run(
        phone_code: &str,
        desk_code: &str,
        desk_sees_phone: [u8; 32],
        desk_token: &[u8],
    ) -> Result<(), PakeError> {
        let (p, msg_a) = PhoneStart::start(phone_code, &TOKEN, PHONE, DESK)?;
        let (d, msg_b) = Desktop::respond(desk_code, desk_token, desk_sees_phone, DESK, &msg_a)?;
        let (pc, ca) = p.finish(&msg_b)?;
        let cb = d.verify(&ca)?;
        pc.verify(&cb)
    }

    #[test]
    fn same_code_same_session_completes() {
        assert_eq!(run("123456", "123456", PHONE, &TOKEN), Ok(()));
    }

    /// 错码必败：电脑验 cA 时失败，不交出 cB。
    #[test]
    fn a_wrong_code_fails_at_the_desktop() {
        assert_eq!(
            run("123456", "123457", PHONE, &TOKEN),
            Err(PakeError::ConfirmMismatch)
        );
    }

    /// 错 NodeId 必败：电脑认出的对端不是手机自以为的那台（中间人换了身份）。
    #[test]
    fn a_wrong_node_id_fails() {
        let mut other = PHONE;
        other[0] ^= 1;
        assert_eq!(
            run("123456", "123456", other, &TOKEN),
            Err(PakeError::ConfirmMismatch)
        );
    }

    /// 电脑一侧的 NodeId 错同样必败：手机以为自己在跟二维码那台电脑说话，实际对端换了身份。
    #[test]
    fn a_wrong_desktop_node_id_fails() {
        let mut other = DESK;
        other[31] ^= 1;
        let (p, msg_a) = PhoneStart::start("123456", &TOKEN, PHONE, DESK).unwrap();
        let (d, msg_b) = Desktop::respond("123456", &TOKEN, PHONE, other, &msg_a).unwrap();
        let (_pc, ca) = p.finish(&msg_b).unwrap();
        assert_eq!(d.verify(&ca), Err(PakeError::ConfirmMismatch));
    }

    /// 两条确认消息不能互换（反射）：手机自己的 cA 当 cB 递回来不被接受，电脑的 cB 当 cA 也不行。
    #[test]
    fn confirmations_cannot_be_reflected() {
        let (p, msg_a) = PhoneStart::start("123456", &TOKEN, PHONE, DESK).unwrap();
        let (d, msg_b) = Desktop::respond("123456", &TOKEN, PHONE, DESK, &msg_a).unwrap();
        let (pc, ca) = p.finish(&msg_b).unwrap();
        assert_eq!(pc.verify(&ca), Err(PakeError::ConfirmMismatch));
        let cb = d.verify(&ca).unwrap();
        let (p2, msg_a2) = PhoneStart::start("123456", &TOKEN, PHONE, DESK).unwrap();
        let (d2, _msg_b2) = Desktop::respond("123456", &TOKEN, PHONE, DESK, &msg_a2).unwrap();
        drop(p2);
        assert_eq!(d2.verify(&cb), Err(PakeError::ConfirmMismatch));
        assert_ne!(ca, cb);
    }

    /// 令牌绑定：同一个码，拿到别的二维码令牌的会话里也对不上。令牌同时在口令和确认消息的 transcript
    /// 里，任一处都足以让它对不上。反证（已实测）：两处都去掉才变红，只去掉一处仍然对不上。
    #[test]
    fn the_code_is_bound_to_this_qr_token() {
        assert_eq!(
            run("123456", "123456", PHONE, &[8; 12]),
            Err(PakeError::ConfirmMismatch)
        );
    }

    /// 重放必败：上一轮的 cA 拿到新一轮（同码同令牌、新随机数）里不被接受；旧 pake_a 重放给新会话，
    /// 攻击者也算不出能让新会话接受的 cA（他没有手机的随机数）。
    #[test]
    fn a_replayed_confirmation_fails() {
        let (p1, msg_a1) = PhoneStart::start("123456", &TOKEN, PHONE, DESK).unwrap();
        let (_d1, msg_b1) = Desktop::respond("123456", &TOKEN, PHONE, DESK, &msg_a1).unwrap();
        let (_pc1, ca1) = p1.finish(&msg_b1).unwrap();
        // 新会话：电脑对重放的 msg_a1 作答（新随机数），攻击者重放旧 cA。
        let (d2, _msg_b2) = Desktop::respond("123456", &TOKEN, PHONE, DESK, &msg_a1).unwrap();
        assert_eq!(d2.verify(&ca1), Err(PakeError::ConfirmMismatch));
        // 电脑侧的 cB 也不能被重放给新一轮的手机。
        let (p3, msg_a3) = PhoneStart::start("123456", &TOKEN, PHONE, DESK).unwrap();
        let (d3, msg_b3) = Desktop::respond("123456", &TOKEN, PHONE, DESK, &msg_a3).unwrap();
        let (pc3, ca3) = p3.finish(&msg_b3).unwrap();
        let cb3 = d3.verify(&ca3).unwrap();
        let (p4, msg_a4) = PhoneStart::start("123456", &TOKEN, PHONE, DESK).unwrap();
        let (_d4, msg_b4) = Desktop::respond("123456", &TOKEN, PHONE, DESK, &msg_a4).unwrap();
        let (pc4, _ca4) = p4.finish(&msg_b4).unwrap();
        assert_eq!(pc4.verify(&cb3), Err(PakeError::ConfirmMismatch));
        assert_eq!(pc3.verify(&cb3), Ok(()));
    }

    /// 低阶点（含单位元）必败：在交给 spake2 之前就拒绝，两侧都是。
    #[test]
    fn small_order_points_are_rejected() {
        use curve25519_dalek::constants::EIGHT_TORSION;
        for t in EIGHT_TORSION.iter() {
            let compressed = t.compress().to_bytes();
            let mut as_a = vec![SIDE_A];
            as_a.extend_from_slice(&compressed);
            assert!(
                matches!(
                    Desktop::respond("123456", &TOKEN, PHONE, DESK, &as_a),
                    Err(PakeError::BadMessage)
                ),
                "desktop must reject small-order X"
            );
            let (p, _) = PhoneStart::start("123456", &TOKEN, PHONE, DESK).unwrap();
            let mut as_b = vec![SIDE_B];
            as_b.extend_from_slice(&compressed);
            assert!(
                matches!(p.finish(&as_b), Err(PakeError::BadMessage)),
                "phone must reject small-order Y"
            );
        }
    }

    /// #1149：混合阶点（素数阶点 + 低阶分量：不是低阶点，但不在素数阶子群里）两侧都拒绝；
    /// 同一个素数阶点本身仍然正常通过（防止把校验写成恒拒绝）。
    /// 反证：把 `!point.is_torsion_free()` 去掉 ⇒ 混合点被放行 ⇒ 变红。
    #[test]
    fn points_outside_the_prime_order_subgroup_are_rejected() {
        use curve25519_dalek::constants::{ED25519_BASEPOINT_POINT, EIGHT_TORSION};
        use curve25519_dalek::scalar::Scalar;
        let prime_order = ED25519_BASEPOINT_POINT * Scalar::from(0x1234_5678u64);
        assert!(prime_order.is_torsion_free());
        // EIGHT_TORSION[0] 是单位元，[1..] 是非平凡低阶点。
        for t in &EIGHT_TORSION[1..] {
            let mixed = prime_order + t;
            assert!(!mixed.is_small_order() && !mixed.is_torsion_free());
            let compressed = mixed.compress().to_bytes();
            let mut as_a = vec![SIDE_A];
            as_a.extend_from_slice(&compressed);
            assert!(matches!(
                Desktop::respond("123456", &TOKEN, PHONE, DESK, &as_a),
                Err(PakeError::BadMessage)
            ));
            let (p, _) = PhoneStart::start("123456", &TOKEN, PHONE, DESK).unwrap();
            let mut as_b = vec![SIDE_B];
            as_b.extend_from_slice(&compressed);
            assert!(matches!(p.finish(&as_b), Err(PakeError::BadMessage)));
        }
        // 对照：素数阶点本身通过校验。
        let mut ok = vec![SIDE_A];
        ok.extend_from_slice(&prime_order.compress().to_bytes());
        assert_eq!(check_peer_msg(&ok, SIDE_A), Ok(()));
    }

    /// 消息格式：长度不对、角色字节不对、不是合法点，都拒绝。
    #[test]
    fn malformed_messages_are_rejected() {
        let (_p, msg_a) = PhoneStart::start("123456", &TOKEN, PHONE, DESK).unwrap();
        assert!(Desktop::respond("123456", &TOKEN, PHONE, DESK, &msg_a[..32]).is_err());
        let mut wrong_side = msg_a.clone();
        wrong_side[0] = SIDE_B;
        assert!(Desktop::respond("123456", &TOKEN, PHONE, DESK, &wrong_side).is_err());
        // 找一个解压不出点的 32 字节编码（约一半的 y 不在曲线上）。
        let bad = (2u8..=255)
            .map(|y| {
                let mut b = [0u8; 32];
                b[0] = y;
                b
            })
            .find(|b| {
                curve25519_dalek::edwards::CompressedEdwardsY(*b)
                    .decompress()
                    .is_none()
            })
            .expect("some y is not on the curve");
        let mut not_a_point = vec![SIDE_A];
        not_a_point.extend_from_slice(&bad);
        assert!(Desktop::respond("123456", &TOKEN, PHONE, DESK, &not_a_point).is_err());
    }

    /// 确认消息的先后：电脑在验过 cA 之前没有任何办法拿到 cB（`verify` 是唯一出口，验错就消耗掉
    /// 会话），乱填的 cA 换不来 cB；手机不能在拿到 pake_b 之前产出 cA（`finish` 才给）。
    #[test]
    fn the_desktop_releases_cb_only_after_a_valid_ca() {
        let (_p, msg_a) = PhoneStart::start("123456", &TOKEN, PHONE, DESK).unwrap();
        let (d, _msg_b) = Desktop::respond("123456", &TOKEN, PHONE, DESK, &msg_a).unwrap();
        assert_eq!(
            d.verify(&[0u8; CONFIRM_LEN]),
            Err(PakeError::ConfirmMismatch)
        );
        let (_p, msg_a) = PhoneStart::start("123456", &TOKEN, PHONE, DESK).unwrap();
        let (d, _msg_b) = Desktop::respond("123456", &TOKEN, PHONE, DESK, &msg_a).unwrap();
        assert_eq!(d.verify(&[0u8; 5]), Err(PakeError::ConfirmMismatch));
    }

    #[test]
    fn codes_are_six_digits_and_validated() {
        for _ in 0..200 {
            let c = generate_code().unwrap();
            assert_eq!(c.len(), 6);
            assert!(c.bytes().all(|b| b.is_ascii_digit()));
        }
        for bad in ["12345", "1234567", "12345a", " 23456", ""] {
            assert!(matches!(
                PhoneStart::start(bad, &TOKEN, PHONE, DESK),
                Err(PakeError::BadCode)
            ));
        }
    }

    #[test]
    fn fingerprint_is_the_first_eight_hex_grouped() {
        assert_eq!(node_fingerprint(&"ab12cd34".repeat(8)), "AB12 CD34");
        assert_eq!(node_fingerprint("  ab12cd34ef"), "AB12 CD34");
        assert_eq!(node_fingerprint("ab1"), "AB1");
    }
}
