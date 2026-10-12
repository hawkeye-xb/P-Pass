import Foundation
import Photos

/// 相册授权的档位（IOS-10）。对位 Android `MediaAccess`（FULL / PARTIAL / NONE），iOS 多两档：
/// 还没问过（`notDetermined`，可以直接弹系统授权框），以及受设备管理限制（`restricted`，用户自己在设置里也改不了）。
public enum PhotoAccessLevel: String, Equatable, Sendable, CaseIterable {
    case notDetermined
    case full
    case limited
    case denied
    case restricted

    /// **只认 `authorizationStatus(for: .readWrite)` 的结果。** 旧 API `authorizationStatus()`（不带 level）在部分授权下返回
    /// `.authorized`（模拟器实测：limited 档 readWrite=4、旧 API=3），用它会把部分授权当成完整授权，重演 MOB-94 的「假 0/0 + 都存好了」。
    public init(readWriteStatus status: PHAuthorizationStatus) {
        switch status {
        case .authorized: self = .full
        case .limited: self = .limited
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .denied // 未知档位按「拿不到」处理：宁可让用户去设置看一眼，也不显示假数字
        }
    }
}

/// 读授权状态 / 请求授权。生产实现是 ``PhotoKitAuthorization``。
public protocol PhotoAuthorizationProviding: Sendable {
    func currentLevel() -> PhotoAccessLevel
    /// 弹系统授权框（只有 `notDetermined` 时系统才会弹；其他档位直接返回当前档位）。
    func requestFullAccess() async -> PhotoAccessLevel
}

public struct PhotoKitAuthorization: PhotoAuthorizationProviding {
    public init() {}

    public func currentLevel() -> PhotoAccessLevel {
        PhotoAccessLevel(readWriteStatus: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestFullAccess() async -> PhotoAccessLevel {
        PhotoAccessLevel(readWriteStatus: await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }
}

/// 首页告示卡上那个按钮做什么。打开设置的 URL 由 App 线用 `UIApplication.openSettingsURLString` 打开（本包不依赖 UIKit）。
public enum PhotoAccessAction: String, Equatable, Sendable {
    /// 弹系统授权框（只在 notDetermined 时有效）。
    case requestAccess
    /// 跳到系统设置里本 App 的页面（相册权限在里面）。
    case openAppSettings
}

/// 首页告示的文案 key 与动作。文案本身由 i18n 线落进 assets/i18n（本包不写文案，README 里列了建议文案，改前给用户确认）。
public struct PhotoAccessNotice: Equatable, Sendable {
    public let titleKey: String
    public let bodyKey: String
    /// nil = 没有可做的动作（受限：用户自己改不了）。
    public let action: PhotoAccessAction?
    public let actionKey: String?
}

/// 授权档位 → 首页该怎么表达（IOS-10，沿用 MOB-02 / MOB-94 的结论，不重新讨论）。
///
/// 定调（2026-09-21）：部分授权**不是要支持的形态**，UI 只负责把用户引导到完整授权，不为它设计降级功能。
/// 拿不到完整权限时，首页**不显示**备份进度数字（不出假 0/0），**不盖**「都存好了」的章。
public struct PhotoAccessPresentation: Equatable, Sendable {
    public let level: PhotoAccessLevel
    /// 首页能不能显示「M / N 张已回家 · 待备份 K」这类数字。只有完整授权时为真。
    public let showsBackupCounts: Bool
    /// 能不能盖「都存好了」的章。只有完整授权时才**可能**为真（其他闸门由首页自己再判）。
    public let allowsAllBackedUpStamp: Bool
    /// 能不能把系统后台上传通道（`PHAssetResourceUploadJob`）当作可用。`PHPhotoLibrary.h` 写明要有完整相册权限。
    /// 后台上传本轮不做（IOS-15 挂起），这里只把「部分授权下它整个不可用」这件事表达出来。
    public let backgroundUploadPossible: Bool
    /// 首页告示；完整授权时为 nil。
    public let notice: PhotoAccessNotice?

    public static func of(_ level: PhotoAccessLevel) -> PhotoAccessPresentation {
        switch level {
        case .full:
            return PhotoAccessPresentation(level: level, showsBackupCounts: true, allowsAllBackedUpStamp: true, backgroundUploadPossible: true, notice: nil)
        case .limited:
            // 不能只说「范围变小」：要把「现在只能前台备份」说出来（部分授权下后台通道整个不可用）。
            return PhotoAccessPresentation(level: level, showsBackupCounts: false, allowsAllBackedUpStamp: false, backgroundUploadPossible: false,
                                           notice: PhotoAccessNotice(titleKey: Keys.limitedTitle, bodyKey: Keys.limitedBody, action: .openAppSettings, actionKey: Keys.openSettings))
        case .denied:
            return PhotoAccessPresentation(level: level, showsBackupCounts: false, allowsAllBackedUpStamp: false, backgroundUploadPossible: false,
                                           notice: PhotoAccessNotice(titleKey: Keys.deniedTitle, bodyKey: Keys.deniedBody, action: .openAppSettings, actionKey: Keys.openSettings))
        case .restricted:
            // 家长控制 / 设备管理限制：去设置也改不了，不给一个点了没用的按钮。
            return PhotoAccessPresentation(level: level, showsBackupCounts: false, allowsAllBackedUpStamp: false, backgroundUploadPossible: false,
                                           notice: PhotoAccessNotice(titleKey: Keys.restrictedTitle, bodyKey: Keys.restrictedBody, action: nil, actionKey: nil))
        case .notDetermined:
            return PhotoAccessPresentation(level: level, showsBackupCounts: false, allowsAllBackedUpStamp: false, backgroundUploadPossible: false,
                                           notice: PhotoAccessNotice(titleKey: Keys.requestTitle, bodyKey: Keys.requestBody, action: .requestAccess, actionKey: Keys.requestAction))
        }
    }

    /// 文案 key。命名沿 assets/i18n 的点分风格；落文案前与 i18n 线核对，不在本包里写死文字。
    public enum Keys {
        public static let limitedTitle = "photo_access.limited.title"
        public static let limitedBody = "photo_access.limited.body"
        public static let deniedTitle = "photo_access.denied.title"
        public static let deniedBody = "photo_access.denied.body"
        public static let restrictedTitle = "photo_access.restricted.title"
        public static let restrictedBody = "photo_access.restricted.body"
        public static let requestTitle = "photo_access.request.title"
        public static let requestBody = "photo_access.request.body"
        public static let requestAction = "photo_access.request.action"
        public static let openSettings = "photo_access.open_settings"

        public static let all: [String] = [limitedTitle, limitedBody, deniedTitle, deniedBody, restrictedTitle, restrictedBody,
                                           requestTitle, requestBody, requestAction, openSettings]
    }
}

/// 后台上传任务（`PHAssetResourceUploadJob`，iOS 26.1+）的闸门（验收 4）。
///
/// 三个条件全满足才允许建 job：系统版本 ≥ 26.1、完整相册授权、`PHPhotoLibrary.uploadJobExtensionEnabled` 为真。
/// 任一不满足返回 false，调用方**不得**尝试建 job（不是建了再看报错）。后台上传本轮挂起（IOS-15），闸门先立住，接上时直接用。
public enum BackgroundUploadGate {
    /// 纯判定，便于测试。`extensionEnabled` 为 nil 表示系统版本低于 26.1、读不到这个开关。
    public static func mayCreateUploadJobs(level: PhotoAccessLevel, extensionEnabled: Bool?) -> Bool {
        guard level == .full, let extensionEnabled else { return false }
        return extensionEnabled
    }

    /// 读真实环境。
    public static func mayCreateUploadJobs(level: PhotoAccessLevel, library: PHPhotoLibrary = .shared()) -> Bool {
        mayCreateUploadJobs(level: level, extensionEnabled: uploadJobExtensionEnabled(library))
    }

    /// iOS 26.1 以下返回 nil。
    public static func uploadJobExtensionEnabled(_ library: PHPhotoLibrary = .shared()) -> Bool? {
        if #available(iOS 26.1, *) {
            return library.uploadJobExtensionEnabled
        }
        return nil
    }
}
