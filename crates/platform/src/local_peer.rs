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
    fn check_peer(&self, allowed: &[PeerRole]) -> PeerCheck;
}

impl LocalPeerSource for interprocess::local_socket::Stream {
    fn check_peer(&self, allowed: &[PeerRole]) -> PeerCheck {
        imp::check_sync(self, allowed)
    }
}

impl LocalPeerSource for interprocess::local_socket::tokio::Stream {
    fn check_peer(&self, allowed: &[PeerRole]) -> PeerCheck {
        imp::check_tokio(self, allowed)
    }
}

/// 校验本机连接的对端是 `allowed` 里的哪一个签名程序（按顺序试，第一个满足的胜出）。
pub fn verify_local_peer<S: LocalPeerSource>(stream: &S, allowed: &[PeerRole]) -> PeerCheck {
    stream.check_peer(allowed)
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
    ) -> PeerCheck {
        #[allow(unreachable_patterns)]
        match s {
            interprocess::local_socket::Stream::UdSocket(u) => {
                check_fd(u.as_fd().as_raw_fd(), allowed)
            }
            _ => PeerCheck::Rejected("不是 Unix 域套接字".into()),
        }
    }

    pub(super) fn check_tokio(
        s: &interprocess::local_socket::tokio::Stream,
        allowed: &[PeerRole],
    ) -> PeerCheck {
        #[allow(unreachable_patterns)]
        match s {
            interprocess::local_socket::tokio::Stream::UdSocket(u) => {
                check_fd(u.as_fd().as_raw_fd(), allowed)
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

    fn check_fd(fd: RawFd, allowed: &[PeerRole]) -> PeerCheck {
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
                Ok(()) => return PeerCheck::Verified(role),
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
    ) -> PeerCheck {
        PeerCheck::NotSupported(WHY)
    }

    pub(super) fn check_tokio(
        _s: &interprocess::local_socket::tokio::Stream,
        _allowed: &[PeerRole],
    ) -> PeerCheck {
        PeerCheck::NotSupported(WHY)
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
