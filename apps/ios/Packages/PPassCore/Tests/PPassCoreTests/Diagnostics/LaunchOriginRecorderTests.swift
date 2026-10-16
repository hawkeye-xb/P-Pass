import XCTest
@testable import PPassCore

final class LaunchOriginRecorderTests: XCTestCase {
    private final class Capture: CoreLogger, @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
        func log(_ message: String) { lock.lock(); _lines.append(message); lock.unlock() }
    }

    func testForegroundFirstWinsAndLaterEntriesAreIgnored() {
        let log = Capture()
        let rec = LaunchOriginRecorder()
        rec.foregroundReached(logger: log)
        rec.backgroundTaskReached(identifier: "x", logger: log)
        rec.foregroundReached(logger: log)
        XCTAssertEqual(log.lines, ["launch origin: foreground"])
    }

    func testBackgroundTaskFirstWins() {
        let log = Capture()
        let rec = LaunchOriginRecorder()
        rec.backgroundTaskReached(identifier: "com.hawkeyexb.ppass.refresh", logger: log)
        rec.foregroundReached(logger: log)
        rec.backgroundTaskReached(identifier: "com.hawkeyexb.ppass.backup", logger: log)
        XCTAssertEqual(log.lines, ["launch origin: background (com.hawkeyexb.ppass.refresh)"])
    }

    func testConcurrentEntriesRecordExactlyOnce() {
        let log = Capture()
        let rec = LaunchOriginRecorder()
        DispatchQueue.concurrentPerform(iterations: 50) { i in
            if i.isMultiple(of: 2) { rec.foregroundReached(logger: log) }
            else { rec.backgroundTaskReached(identifier: "t", logger: log) }
        }
        XCTAssertEqual(log.lines.count, 1)
    }
}
