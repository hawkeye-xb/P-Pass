import Foundation
import Photos
import PPassCore
import PPassMedia

/// 照片库的注册入口。生产是 `PHPhotoLibrary.shared()`，测试里换成假的（真库需要授权，测试进程拿不到）。
protocol PhotoLibraryRegistering: AnyObject {
    func register(_ observer: PHPhotoLibraryChangeObserver)
    func unregister(_ observer: PHPhotoLibraryChangeObserver)
}

final class SystemPhotoLibrary: PhotoLibraryRegistering {
    func register(_ observer: PHPhotoLibraryChangeObserver) { PHPhotoLibrary.shared().register(observer) }
    func unregister(_ observer: PHPhotoLibraryChangeObserver) { PHPhotoLibrary.shared().unregisterChangeObserver(observer) }
}

/// #978：`PHPhotoLibraryChangeObserver` 适配成 PPassCore 的 `MediaChangeSource`（对位 Android MediaStore ContentObserver）。
/// 系统在任意线程回调；只当「有变化」的信号用，不读 `PHChange` 的内容——新照片靠引擎自己的收件箱 / 对账发现。
/// 部分授权（limited）下系统只通知可见范围内的变化，监听照常工作。
final class PhotoLibraryChangeSource: NSObject, MediaChangeSource, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let library: PhotoLibraryRegistering
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    init(library: PhotoLibraryRegistering = SystemPhotoLibrary()) { self.library = library }

    func start(_ onChange: @escaping @Sendable () -> Void) {
        lock.lock(); handler = onChange; lock.unlock()
        library.register(self)
    }

    func stop() {
        library.unregister(self)
        lock.lock(); handler = nil; lock.unlock()
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) { notify() }

    func notify() {
        lock.lock(); let h = handler; lock.unlock()
        h?()
    }

    /// 现在能不能监听：完整与部分授权都可以；没问过 / 拒绝 / 受限时不注册（`PHPhotoLibrary` 不会给未授权的 App 发通知，
    /// 注册只会白占一个观察者）。原因由 `MediaChangeWatcher` 写进日志。
    static func unavailableReason(level: PhotoAccessLevel) -> String? {
        switch level {
        case .full, .limited: return nil
        case .notDetermined, .denied, .restricted: return "photo access \(level.rawValue)"
        }
    }
}
