//! noq-udp 收包：一个比接收缓冲区大的 UDP 数据报（被截断）之后，`recv`
//! 必须及时返回，不能停在收包循环里。
//!
//! 走的是 iroh 实际用的那一层（`noq_udp::UdpSocketState::recv`）。macOS / iOS
//! 上它落到 `recv_single`，这正是 `third_party/noq-udp` 补丁改的函数；Linux /
//! Android 走 recvmmsg、Windows 走 WSARecvMsg，同样的断言在那里也必须成立。
//! 放在 platform 这个 crate：CI 的 macOS lane 只跑 `cargo test -p platform`。

use std::io::IoSliceMut;
use std::net::{Ipv4Addr, UdpSocket};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use noq_udp::{RecvMeta, UdpSocketState};

fn pair() -> (UdpSocket, UdpSocket) {
    let receiver = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    receiver.set_nonblocking(true).unwrap();
    let sender = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    (receiver, sender)
}

/// 用 8 字节缓冲区收一次；结果从工作线程送回，调用方据此判断有没有卡住。
fn recv_in_thread(receiver: UdpSocket) -> mpsc::Receiver<std::io::Result<usize>> {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let state = UdpSocketState::new((&receiver).into()).unwrap();
        let mut buf = [0u8; 8];
        let mut meta = [RecvMeta::default()];
        let r = state.recv(
            (&receiver).into(),
            &mut [IoSliceMut::new(&mut buf)],
            &mut meta,
        );
        let _ = tx.send(r);
    });
    rx
}

#[test]
fn udp_recv_returns_promptly_after_a_truncated_datagram() {
    let (receiver, sender) = pair();
    let addr = receiver.local_addr().unwrap();
    sender.send_to(&[0u8; 16], addr).unwrap();

    let rx = recv_in_thread(receiver);
    let answer = rx.recv_timeout(Duration::from_secs(2));
    if answer.is_err() {
        // 卡在循环里：补一个正常小包把它放出来，再判红。
        sender.send_to(b"ok", addr).unwrap();
        let _ = rx.recv_timeout(Duration::from_secs(2));
    }
    let result = answer.expect("recv kept looping after a truncated datagram");
    // 平台语义不同：Apple 丢弃截断包后回 WouldBlock，recvmmsg 交回截断后的
    // 包，Windows 报错。只要求返回，且不是「卡住」。
    if let Err(e) = result {
        assert_ne!(e.kind(), std::io::ErrorKind::TimedOut, "{e}");
    }
}

#[test]
fn udp_recv_delivers_the_next_datagram_after_a_truncated_one() {
    let (receiver, sender) = pair();
    let addr = receiver.local_addr().unwrap();
    sender.send_to(&[0u8; 16], addr).unwrap();
    sender.send_to(b"ok", addr).unwrap();

    // 截断包可能被跳过（Apple）、交回截断内容（recvmmsg）或报错（Windows）；
    // 不管哪种，紧跟着的正常包必须在 2 s 内完整收到。
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let state = UdpSocketState::new((&receiver).into()).unwrap();
        for _ in 0..200 {
            let mut buf = [0u8; 8];
            let mut meta = [RecvMeta::default()];
            if let Ok(1) = state.recv(
                (&receiver).into(),
                &mut [IoSliceMut::new(&mut buf)],
                &mut meta,
            ) {
                if &buf[..meta[0].len.min(8)] == b"ok" {
                    let _ = tx.send(());
                    return;
                }
            }
            thread::sleep(Duration::from_millis(5));
        }
    });
    rx.recv_timeout(Duration::from_secs(2))
        .expect("the datagram after a truncated one was never delivered");
}
