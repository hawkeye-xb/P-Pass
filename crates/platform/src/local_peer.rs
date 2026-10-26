//! #1115：本机 IPC 对端是谁——按对端进程的**代码签名**认人，不按「能读到某个文件」。
//!
//! macOS：连接建立时内核记下对端的 audit token（`LOCAL_PEERTOKEN`，macOS 13+ 公开支持），
//! 用 Security 框架按 token 找到对端代码（`SecCodeCopyGuestWithAttributes`）并校验
//! [`code_requirement`]。不用 PID：「先连上发请求、再 exec 成合法程序」能骗过 PID 查询
//! （讨论稿 §2.5 实测 6/6），audit token 带 pidversion，exec 之后就对不上。
//!
//! 服务端（daemon）用它认客户端；客户端（壳、daemon 的单实例交接、诊断导出）对已连上的
//! socket 调用它，拿到的是**监听方**的身份——反向校验服务端，防 socket 被抢注。
//!
//! 校验是同步 Security 调用（实测 0.2–7ms，含读盘校验静态签名），async 调用方放进
//! `spawn_blocking`。

use crate::code_signature::{DAEMON_APP_ID, DESKTOP_APP_ID};

/// 我们自己的两个签名程序。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PeerRole {
    /// 桌面主 App（窗口程序），[`DESKTOP_APP_ID`]。
    Shell,
    /// 内置 daemon（helper App），[`DAEMON_APP_ID`]。
    Daemon,
}

impl PeerRole {
    pub fn identifier(self) -> &'static str {
        match self {
            PeerRole::Shell => DESKTOP_APP_ID,
            PeerRole::Daemon => DAEMON_APP_ID,
        }
    }
}

/// 对端校验结果。不是 `Result`：「本平台不做这项校验」不能被说成通过。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PeerCheck {
    /// 对端满足 `code_requirement(role.identifier())`。
    Verified(PeerRole),
    /// 不是我们签名的程序（或拿不到对端身份）——断开，什么都不发。
    Rejected(String),
    /// 本平台没有按签名认人的实现（Windows / Linux：仍用令牌，另卡讨论）。
    NotSupported(&'static str),
}

/// 能取出对端身份的本机连接（interprocess 的同步与 tokio 两种 Stream）。
pub trait LocalPeerSource {
    #[doc(hidden)]
    fn check_peer(&self, allowed: &[PeerRole], min_version: Option<&str>) -> PeerCheck;
}

impl LocalPeerSource for interprocess::local_socket::Stream {
    fn check_peer(&self, allowed: &[PeerRole], min_version: Option<&str>) -> PeerCheck {
        imp::check_sync(self, allowed, min_version)
    }
}

impl LocalPeerSource for interprocess::local_socket::tokio::Stream {
    fn check_peer(&self, allowed: &[PeerRole], min_version: Option<&str>) -> PeerCheck {
        imp::check_tokio(self, allowed, min_version)
    }
}

/// 校验本机连接的对端是 `allowed` 里的哪一个签名程序（按顺序试，第一个满足的胜出）。
pub fn verify_local_peer<S: LocalPeerSource>(stream: &S, allowed: &[PeerRole]) -> PeerCheck {
    stream.check_peer(allowed, None)
}

/// 同 [`verify_local_peer`]，另要求对端**被签名封住的版本号不低于** `min_version`（#1150）。
///
/// 只给**服务端接入**用（daemon 认窗口程序 / 另一个 daemon）：旧的已签名版本不能一直
/// 被认作合法对端。客户端方向（壳连 daemon、新 daemon 连旧 daemon 交接）不加下限——升级窗口里
/// 新壳必须能连上旧 daemon 让它退位。版本读不出来 ⇒ 拒绝，不猜。
pub fn verify_local_peer_min_version<S: LocalPeerSource>(
    stream: &S,
    allowed: &[PeerRole],
    min_version: &str,
) -> PeerCheck {
    stream.check_peer(allowed, Some(min_version))
}

/// 版本下限判据（纯函数，各平台一致）：对端版本缺失或为空 ⇒ 拒绝；低于下限 ⇒ 拒绝；
/// 等于或更高 ⇒ 通过。比较用项目统一的 `version_cmp`（它把垃圾输入当 0，所以缺失
/// 必须在这里先显式拒绝，不能指望比较结果兜底）。
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn meets_min_version(peer: Option<&str>, min_version: &str) -> Result<(), String> {
    let Some(peer) = peer.map(str::trim).filter(|v| !v.is_empty()) else {
        return Err("对端没有可读的版本号".into());
    };
    if version_cmp::version_cmp(peer, min_version) == std::cmp::Ordering::Less {
        return Err(format!("对端版本 {peer} 低于下限 {min_version}"));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
mod imp {
    use super::{PeerCheck, PeerRole};
    use crate::code_signature::code_requirement;
    use core_foundation::base::TCFType;
    use core_foundation::data::CFData;
    use security_framework::os::macos::code_signing::{
        Flags, GuestAttributes, SecCode, SecRequirement,
    };
    use std::os::fd::{AsFd, AsRawFd, RawFd};
    use std::str::FromStr;

    /// `SOL_LOCAL`（sys/un.h）。libc crate 没有导出它。
    const SOL_LOCAL: libc::c_int = 0;

    pub(super) fn check_sync(
        s: &interprocess::local_socket::Stream,
        allowed: &[PeerRole],
        min_version: Option<&str>,
    ) -> PeerCheck {
        #[allow(unreachable_patterns)]
        match s {
            interprocess::local_socket::Stream::UdSocket(u) => {
                check_fd(u.as_fd().as_raw_fd(), allowed, min_version)
            }
            _ => PeerCheck::Rejected("不是 Unix 域套接字".into()),
        }
    }

    pub(super) fn check_tokio(
        s: &interprocess::local_socket::tokio::Stream,
        allowed: &[PeerRole],
        min_version: Option<&str>,
    ) -> PeerCheck {
        #[allow(unreachable_patterns)]
        match s {
            interprocess::local_socket::tokio::Stream::UdSocket(u) => {
                check_fd(u.as_fd().as_raw_fd(), allowed, min_version)
            }
            _ => PeerCheck::Rejected("不是 Unix 域套接字".into()),
        }
    }

    /// audit_token_t = 8 × u32（xnu bsm/audit.h）。连接建立那一刻由内核记下。
    fn peer_audit_token(fd: RawFd) -> std::io::Result<[u32; 8]> {
        let mut tok = [0u32; 8];
        let mut len = std::mem::size_of::<[u32; 8]>() as libc::socklen_t;
        // SAFETY: tok 是 32 字节的可写缓冲，len 如实给出其大小；fd 由调用方持有的连接借出。
        let r = unsafe {
            libc::getsockopt(
                fd,
                SOL_LOCAL,
                libc::LOCAL_PEERTOKEN,
                tok.as_mut_ptr().cast(),
                &mut len,
            )
        };
        if r != 0 {
            return Err(std::io::Error::last_os_error());
        }
        if len as usize != std::mem::size_of::<[u32; 8]>() {
            return Err(std::io::Error::other(format!("audit token 长度 {len}")));
        }
        Ok(tok)
    }

    fn check_fd(fd: RawFd, allowed: &[PeerRole], min_version: Option<&str>) -> PeerCheck {
        let tok = match peer_audit_token(fd) {
            Ok(t) => t,
            Err(e) => return PeerCheck::Rejected(format!("取不到对端 audit token：{e}")),
        };
        let bytes: Vec<u8> = tok.iter().flat_map(|v| v.to_ne_bytes()).collect();
        let data = CFData::from_buffer(&bytes);
        let mut attrs = GuestAttributes::new();
        attrs.set_audit_token(data.as_concrete_TypeRef());
        let code = match SecCode::copy_guest_with_attribues(None, &attrs, Flags::NONE) {
            Ok(c) => c,
            // exec 换身之后按旧 token 找不到 guest，正落在这里。
            Err(e) => return PeerCheck::Rejected(format!("按 audit token 找不到对端代码：{e}")),
        };
        let mut last = String::from("没有可接受的身份");
        for &role in allowed {
            let req = match SecRequirement::from_str(&code_requirement(role.identifier())) {
                Ok(r) => r,
                Err(e) => return PeerCheck::Rejected(format!("签名要求无效：{e}")),
            };
            match code.check_validity(Flags::NONE, &req) {
                Ok(()) => {
                    // #1150：签名通过之后再核版本下限（版本读自签名封住的 Info.plist）。
                    if let Some(floor) = min_version {
                        let peer = crate::sealed_version::of_guest(&code);
                        if let Err(why) = super::meets_min_version(peer.as_deref().ok(), floor) {
                            let seen = match &peer {
                                Ok(v) => v.clone(),
                                Err(e) => format!("读不到（{e}）"),
                            };
                            return PeerCheck::Rejected(format!(
                                "{}：{why}（对端 {seen}，下限 {floor}）",
                                role.identifier()
                            ));
                        }
                    }
                    return PeerCheck::Verified(role);
                }
                Err(e) => last = format!("不满足 {}：{e}", role.identifier()),
            }
        }
        PeerCheck::Rejected(last)
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use super::{PeerCheck, PeerRole};

    const WHY: &str = "本平台不按代码签名校验 IPC 对端（Windows / Linux 另行讨论）";

    pub(super) fn check_sync(
        _s: &interprocess::local_socket::Stream,
        _allowed: &[PeerRole],
        _min_version: Option<&str>,
    ) -> PeerCheck {
        PeerCheck::NotSupported(WHY)
    }

    pub(super) fn check_tokio(
        _s: &interprocess::local_socket::tokio::Stream,
        _allowed: &[PeerRole],
        _min_version: Option<&str>,
    ) -> PeerCheck {
        PeerCheck::NotSupported(WHY)
    }
}

#[cfg(test)]
mod floor_tests {
    use super::meets_min_version;

    /// 卡面四种情况 + 项目版本语义的两个陷阱。
    /// 反证：把比较换成字符串字典序，`2026.10.10` 那条红；把预发布当「不低于正式版」，
    /// `0.10.0-test.10 vs 0.10.0` 那条红（csreq 的 `>=` 正是这么错的）。
    #[test]
    fn floor_decisions() {
        assert!(
            meets_min_version(Some("0.10.0"), "0.10.1").is_err(),
            "低版本被拒"
        );
        assert!(
            meets_min_version(Some("0.10.1"), "0.10.1").is_ok(),
            "同版本通过"
        );
        assert!(
            meets_min_version(Some("0.10.2"), "0.10.1").is_ok(),
            "高版本通过"
        );
        assert!(meets_min_version(None, "0.10.1").is_err(), "版本缺失被拒");
        assert!(meets_min_version(Some(""), "0.10.1").is_err(), "空串被拒");
        assert!(meets_min_version(Some("  "), "0.10.1").is_err(), "空白被拒");
        assert!(
            meets_min_version(Some("garbage"), "0.10.1").is_err(),
            "垃圾被拒"
        );
        // 不是字典序：
        assert!(meets_min_version(Some("2026.10.10"), "2026.10.9").is_ok());
        assert!(meets_min_version(Some("2026.10.9"), "2026.10.10").is_err());
        assert!(meets_min_version(Some("0.10.0-test.10"), "0.10.0-test.9").is_ok());
        assert!(meets_min_version(Some("0.10.0-test.9"), "0.10.0-test.10").is_err());
        // 预发布 < 正式版（csreq 的 `>=` 判反）：
        assert!(meets_min_version(Some("0.10.0-test.10"), "0.10.0").is_err());
        assert!(meets_min_version(Some("0.10.0"), "0.10.0-test.10").is_ok());
        // 版本串两端的空白不影响：
        assert!(meets_min_version(Some(" 0.10.1 "), "0.10.1").is_ok());
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    use interprocess::local_socket::{prelude::*, GenericFilePath, ListenerOptions};

    /// 测试进程自己（cargo 产出的链接器 ad-hoc 签名）连上来：不是我们的签名程序，拒绝；
    /// 反过来客户端校验监听方（也是测试进程）同样拒绝。
    /// 反证：check_fd 退回「能取到 token 就放行」或要求串去掉 identifier / OID ⇒ 这里变 Verified，红。
    #[test]
    fn an_unsigned_peer_is_rejected_both_ways() {
        let dir = std::env::temp_dir().join(format!("ppf-peer-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.sock");
        let name = path.clone().to_fs_name::<GenericFilePath>().unwrap();
        let listener = ListenerOptions::new()
            .name(name.clone())
            .create_sync()
            .unwrap();
        let client = interprocess::local_socket::Stream::connect(name).unwrap();
        let server_side = listener.accept().unwrap();

        match verify_local_peer(&server_side, &[PeerRole::Shell, PeerRole::Daemon]) {
            PeerCheck::Rejected(why) => assert!(why.contains("不满足"), "{why}"),
            other => panic!("未签名的客户端不该通过：{other:?}"),
        }
        assert!(matches!(
            verify_local_peer(&client, &[PeerRole::Daemon]),
            PeerCheck::Rejected(_)
        ));
        drop((client, server_side, listener));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn roles_map_to_our_two_bundle_ids() {
        assert_eq!(PeerRole::Shell.identifier(), "com.hawkeyexb.ppass.desktop");
        assert_eq!(
            PeerRole::Daemon.identifier(),
            "com.hawkeyexb.ppass.desktop.daemon"
        );
    }
}
