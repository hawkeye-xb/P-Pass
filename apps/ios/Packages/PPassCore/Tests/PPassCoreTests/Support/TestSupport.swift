import Foundation
import XCTest
@testable import PPassCore

/// 每个测试一个真实的临时目录（真跑文件 IO，不 mock 文件系统）。
final class TempDir {
    let url: URL

    init(_ name: String = #function) {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ppasscore-tests", isDirectory: true)
            .appendingPathComponent("\(name.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    func write(_ name: String, _ text: String) {
        try! Data(text.utf8).write(to: file(name))
    }

    func read(_ name: String) -> String? {
        (try? Data(contentsOf: file(name))).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// 截获每一行日志，断言「降级 / 损坏时说了实话」。
final class RecordingLogger: CoreLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return _lines
    }

    func log(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        _lines.append(message)
    }

    func contains(_ fragment: String) -> Bool { lines.contains { $0.contains(fragment) } }
}

/// 可拨动的时钟。
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Int64

    init(_ start: Int64 = 1_000) { _now = start }

    var now: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return _now }
        set { lock.lock(); _now = newValue; lock.unlock() }
    }

    var function: @Sendable () -> Int64 { { [self] in self.now } }
}
