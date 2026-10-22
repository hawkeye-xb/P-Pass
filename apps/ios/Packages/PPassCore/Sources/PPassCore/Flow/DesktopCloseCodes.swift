// #1122 / #1119：桌面在连接层发出的 QUIC 应用关闭码（跨端注册表，Rust 唯一定义在 `crates/proto/src/close_codes.rs`）。
//
// 关闭帧在 TLS 握手之后发出，经桌面身份认证，与 `not_paired` 应答同样可信。手机只在「关闭方就是配对记录里的那台电脑」
// 且关闭码是下面两个之一时，把这次失败归为明确的「未配对」，汇入与 `not_paired` 应答同一条「被拒即清理」路径；
// 其它一律按「连不上」（超时、网络断、本地关闭、未知关闭码如 blobs 的 403、关闭方不是记录的那台电脑）。
// 取值不在别处重复：契约测试读 `snapshots__close_codes_registry` 快照核对这里（`DesktopCloseCodesContractTests`）。
import Foundation

public enum DesktopCloseCodes {
    /// 接受连接时因为「没有配对记录、也不在配对窗口内」被拒。
    public static let notPaired: UInt64 = 401
    /// 已有连接因为这台设备的配对记录被删除而被关。
    public static let unpaired: UInt64 = 410

    /// 注册表：(关闭码, 线上原因串)，顺序与快照一致。
    public static let registry: [(code: UInt64, reason: String)] = [(notPaired, "not_paired"), (unpaired, "unpaired")]

    /// 这个关闭码是不是「未配对」。
    public static func meansNotPaired(_ code: UInt64) -> Bool { code == notPaired || code == unpaired }
}

/// 控制面调用因为连接被对端用应用关闭码关掉而失败（FFI `FfiError.PeerClosed` 的核心层镜像）。
public struct PeerClosedConnection: Error, Equatable, Sendable {
    /// 关闭帧的来源（64 位 hex，FFI 取自连接的认证对端）。
    public let nodeId: String
    public let code: UInt64

    public init(nodeId: String, code: UInt64) {
        self.nodeId = nodeId
        self.code = code
    }
}

/// 关闭帧 → 「未配对」。只有关闭方 == 本地配对记录里的 daemonNodeId、且关闭码属于「未配对」才返回
/// [DesktopRejected]（`not_paired`，走与应答同一条被拒路径）；否则 nil（调用方保持原错误，按「连不上」处理）。
public func desktopRejection(forClose closed: PeerClosedConnection, recordedDaemonNodeId: String?, method: String) -> DesktopRejected? {
    guard DesktopCloseCodes.meansNotPaired(closed.code) else { return nil }
    guard let recorded = recordedDaemonNodeId, !recorded.isBlank,
          closed.nodeId.lowercased() == recorded.lowercased() else { return nil }
    return DesktopRejected(reason: .registered(.notPaired), method: method)
}
