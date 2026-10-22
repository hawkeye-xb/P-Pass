// 这台手机的 iroh 身份私钥（32 字节）放哪、什么时候算「新设备」（对位 Android 身份私钥 Keystore 加固）。
//
// - 私钥只在钥匙串里（App 侧 `KeychainIdentityStore`：首次解锁后可读、仅本设备、不同步），不落存储根，
//   所以不进 iCloud / Finder 备份、不随换机迁移。iroh 建连要私钥原文，只能「静态加密存储 + 运行时载入内存」。
// - 存储根里的 [DeviceIdentity.markerFileName] 是「本次安装」的标记：钥匙串卸载后还在，存储根（App Group 容器）不在；
//   有私钥没标记 = 卸载重装留下的旧私钥。
// - 新设备（重装 / 备份恢复 / 钥匙串被清 / 测试机上的旧明文 `identity.key`）一律：生成新私钥 → 写入钥匙串并读回
//   → 按断开清单清掉配对 → 删旧明文 → 写标记。顺序就是安全性：前两步失败什么都没删；中途被杀，下次启动重走同一条路。
// - 读不到 ≠ 没有：首次解锁前钥匙串返回 [IdentityStoreError.locked]，标记 / 配对文件读失败都原样抛出，绝不当成新设备。
import Foundation

/// 私钥的存取（App 侧是钥匙串；测试注入失败）。
public protocol IdentitySecretStore: Sendable {
    /// nil = 没有这一项。
    func read() throws -> Data?
    /// 新增一项（调用方先 [delete]）。
    func write(_ key: Data) throws
    /// 删除；本来就没有不算错。
    func delete() throws
}

public enum IdentityStoreError: Error, Equatable, CustomStringConvertible {
    /// 开机后还没解锁过（errSecInteractionNotAllowed）：暂时读不到，不是故障。
    case locked
    /// 钥匙串操作失败（[op] 是 read / write / delete，[status] 是 OSStatus）。
    case failed(op: String, status: Int32)
    /// 写进去再读回来不一致（或读回为空）。
    case readBackMismatch

    public var description: String {
        switch self {
        case .locked: return "keychain locked until first unlock"
        case let .failed(op, status): return "keychain \(op) failed (OSStatus \(status))"
        case .readBackMismatch: return "keychain read-back mismatch"
        }
    }
}

public enum DeviceIdentity {
    /// 本次安装的标记（相对存储根）。断开清单登记为 keep。
    public static let markerFileName = "identity-installed"
    /// 旧版本的明文私钥（相对存储根）。见到就按新设备处理并删掉。
    public static let legacyPlaintextFileName = "identity.key"
    static let keyLength = 32

    /// 为什么这次生成了新私钥（日志 / 测试用）。
    public enum NewDeviceReason: String, Equatable, Sendable {
        /// 钥匙串里没有（全新安装、备份恢复、钥匙串被清）。
        case missing
        /// 有私钥但没有本次安装的标记（卸载重装）。
        case reinstall
        /// 存储根里有旧版本的明文私钥。
        case legacyPlaintext
        /// 钥匙串里的不是 32 字节。
        case malformed
        /// 用户在拒绝启动页点了「重置并重新配对」。
        case userReset
    }

    public enum Outcome: Equatable, Sendable {
        case existing
        case newDevice(NewDeviceReason)
    }

    public struct Loaded: Equatable, Sendable {
        public let key: Data
        public let outcome: Outcome
    }

    /// 启动时取私钥：照常就返回钥匙串里的；判定为新设备就换一把新的（见文件头的顺序）。
    /// - Parameter clearPairing: 按断开清单清本地配对（只在存储根里有配对记录时调用）。
    public static func load(root: URL, store: IdentitySecretStore, clearPairing: () throws -> Void,
                            random: () throws -> Data = randomKey, logger: CoreLogger) throws -> Loaded {
        let stored = try store.read()
        let reason: NewDeviceReason
        if try exists(root.appendingPathComponent(legacyPlaintextFileName)) {
            reason = .legacyPlaintext
        } else if let stored {
            if stored.count != keyLength {
                reason = .malformed
            } else if try !exists(root.appendingPathComponent(markerFileName)) {
                reason = .reinstall
            } else {
                logger.log("identity: using the key in the keychain")
                return Loaded(key: stored, outcome: .existing)
            }
        } else {
            reason = .missing
        }
        return try becomeNewDevice(root: root, store: store, reason: reason, clearPairing: clearPairing, random: random, logger: logger)
    }

    /// 换一把新私钥，这台手机从此是一台新设备（「重置并重新配对」也走这里）。
    public static func becomeNewDevice(root: URL, store: IdentitySecretStore, reason: NewDeviceReason, clearPairing: () throws -> Void,
                                       random: () throws -> Data = randomKey, logger: CoreLogger) throws -> Loaded {
        logger.log("identity: new device (\(reason.rawValue)), generating a new key")
        let key = try random()
        precondition(key.count == keyLength, "identity key must be \(keyLength) bytes")
        try store.delete()
        try store.write(key)
        guard try store.read() == key else { throw IdentityStoreError.readBackMismatch }
        // 私钥已经落进钥匙串，下面才动存储根：旧配对属于旧身份，电脑不认新私钥。
        if try exists(root.appendingPathComponent(DisconnectState.pairing.path!)) {
            logger.log("identity: clearing the pairing that belonged to the previous key")
            try clearPairing()
        }
        try removeIfPresent(root.appendingPathComponent(legacyPlaintextFileName))
        try Data().write(to: root.appendingPathComponent(markerFileName), options: .atomic)
        return Loaded(key: key, outcome: .newDevice(reason))
    }

    public static func randomKey() throws -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<keyLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// 存在 / 不存在 / 读失败三分：只有「确实不存在」返回 false，其余错误原样抛出。
    static func exists(_ url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return false
        }
    }

    private static func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) } catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }
}
