import Foundation
import Photos

/// 取原图失败的分类，按 #311 D4 的处置方式分（ARCH-01 的词：等待中(原因) / 源已删 / 失败计次）。
///
/// 对接 PPassCore `ImportResult`（#903）的方式：
/// - ``sourceMissing`` 对应 `.sourceMissing`。
/// - ``network`` 对应 `.originalUnavailable(reason:)`，不计失败预算，等网络。
/// - ``localStorageFull`` 是手机自己空间不足，写不下临时文件。它不是网络问题，也不是这张照片的问题，换一张照样写不下，
///   所以**不该**计入单张失败，而是整体等待。PPassCore 的 `WaitReason` 里目前没有这一项，对接时需要补上（PR 里已登记）。
/// - ``unavailable`` 表示资源确实拿不到：抛错，由引擎按单张失败计次。
/// 取消不在这里：直接抛 `CancellationError`。
public enum OriginalFetchFailure: Error, Equatable {
    /// 照片库里已经没有这一项。
    case sourceMissing
    /// 因网络拉不下来（iCloud 优化存储下原图不在本机）。暂时性的，不计失败预算。
    case network(reason: String)
    /// 手机本地空间不足，临时文件写不下。
    case localStorageFull(reason: String)
    /// 资源确实不可得（没有原图资源、资源校验失败、系统不支持等）。计入失败。
    case unavailable(reason: String)

    /// 这次失败要不要扣这张照片的失败预算。
    public var countsAgainstFailureBudget: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

enum OriginalFetchErrorClassifier {
    /// 把 PhotoKit / 系统返回的错误归类。顺着 `NSUnderlyingErrorKey` 链往下找：iCloud 下载失败时，
    /// 外层常常是 PhotoKit 或 CloudPhotoLibrary 的错误，真正的原因（断网、超时）在里层。
    /// **只有能认定是网络原因时才归为 ``OriginalFetchFailure/network``**：归错了会让这张照片一直卡在队头，
    /// 它既不计次，也不推进 G。认不出来的一律归为 ``OriginalFetchFailure/unavailable``。
    static func classify(_ error: Error) -> OriginalFetchFailure {
        let chain = errorChain(error as NSError)
        let summary = chain.map { e in "\(e.domain)#\(e.code)" }.joined(separator: " <- ")
        if chain.contains(where: isNetwork) { return .network(reason: summary) }
        if chain.contains(where: isOutOfSpace) { return .localStorageFull(reason: summary) }
        return .unavailable(reason: summary)
    }

    static func isUserCancelled(_ error: Error) -> Bool {
        errorChain(error as NSError).contains { e in e.domain == PHPhotosErrorDomain && e.code == PHPhotosError.userCancelled.rawValue }
    }

    private static func errorChain(_ error: NSError) -> [NSError] {
        var out: [NSError] = []
        var current: NSError? = error
        while let e = current, out.count < 8 {
            out.append(e)
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return out
    }

    /// 断网、超时、连接被重置这一类 POSIX 错误。
    private static let networkPOSIX: Set<Int32> = [ENETDOWN, ENETUNREACH, ENETRESET, ECONNABORTED, ECONNRESET, ETIMEDOUT, ECONNREFUSED, EHOSTDOWN, EHOSTUNREACH, ENOTCONN]

    private static func isNetwork(_ e: NSError) -> Bool {
        switch e.domain {
        case NSURLErrorDomain:
            // 取消不是网络问题；其余 NSURLError 都是传输层的问题。
            return e.code != NSURLErrorCancelled
        case PHPhotosErrorDomain:
            return e.code == PHPhotosError.networkError.rawValue // 3169
        case NSPOSIXErrorDomain:
            return networkPOSIX.contains(Int32(e.code))
        default:
            return false
        }
    }

    private static func isOutOfSpace(_ e: NSError) -> Bool {
        switch e.domain {
        case PHPhotosErrorDomain: return e.code == PHPhotosError.notEnoughSpace.rawValue // 3305
        case NSCocoaErrorDomain: return e.code == NSFileWriteOutOfSpaceError
        case NSPOSIXErrorDomain: return Int32(e.code) == ENOSPC || Int32(e.code) == EDQUOT
        default: return false
        }
    }
}
