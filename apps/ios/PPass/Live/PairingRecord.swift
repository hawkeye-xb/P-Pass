import Foundation

/// 配对记录（对位 Android `Pairing`）：存在存储根目录的 `pairing.json`（断开清单里它是 clear）。
/// 配对串的解析不在 iOS 侧实现——用传输 FFI 的 `parsePairLink`（与 testclient、daemon 契约测试同一个解析器，#919）。
struct PairingRecord: Codable, Equatable {
    var daemonNodeId: String
    /// FFI `CtrlClient.call(peerToken:)` 直接吃的 PeerAddr token（配对串解析出来的那个）。
    var peerToken: String
    var storageDeviceName: String
    var pairedAt: Int64
    var pairingId: String
    /// 电脑那边已经不认这台手机（探测到 pairing lost）。
    var lost: Bool = false
}
