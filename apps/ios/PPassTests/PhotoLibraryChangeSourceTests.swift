import Foundation
import Photos
import PPassCore
import PPassMedia
import XCTest
@testable import PPass

/// #978：PhotoKit 变更监听的适配层。注册表换成假的（真 PHPhotoLibrary 需要授权，测试进程拿不到）。
final class PhotoLibraryChangeSourceTests: XCTestCase {
    private final class FakeRegistry: PhotoLibraryRegistering, @unchecked Sendable {
        var registered: [ObjectIdentifier] = []
        func register(_ observer: PHPhotoLibraryChangeObserver) { registered.append(ObjectIdentifier(observer)) }
        func unregister(_ observer: PHPhotoLibraryChangeObserver) { registered.removeAll { $0 == ObjectIdentifier(observer) } }
    }

    private final class Counter: @unchecked Sendable { var n = 0 }

    func testStartRegistersTheObserverAndStopRemovesIt() {
        let registry = FakeRegistry()
        let source = PhotoLibraryChangeSource(library: registry)
        let counter = Counter()
        source.start { counter.n += 1 }
        XCTAssertEqual(registry.registered, [ObjectIdentifier(source)])
        source.notify()
        XCTAssertEqual(counter.n, 1)
        source.stop()
        XCTAssertTrue(registry.registered.isEmpty)
        source.notify()
        XCTAssertEqual(counter.n, 1, "注销之后到达的通知不再往外送")
    }

    /// 授权档位 → 能不能监听：完整、部分授权都要监听；其余不监听（原因进日志，由 MediaChangeWatcher 记）。
    func testOnlyFullAndLimitedAccessCanObserve() {
        XCTAssertNil(PhotoLibraryChangeSource.unavailableReason(level: .full))
        XCTAssertNil(PhotoLibraryChangeSource.unavailableReason(level: .limited), "部分授权下也要工作")
        for level in [PhotoAccessLevel.notDetermined, .denied, .restricted] {
            XCTAssertNotNil(PhotoLibraryChangeSource.unavailableReason(level: level), "\(level) 不注册")
        }
    }
}
