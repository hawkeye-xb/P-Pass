import XCTest
@testable import PPassCore

final class RollingFileLogTests: XCTestCase {
    /// #1122：日志目录不进备份（只它自己，上级目录不动），读回确认，结果行说明 true。
    /// 反证：去掉 excludeFromBackup 的 setResourceValues（或不调用 excludeDirectoryFromBackup / open 里的重设），三条断言红。
    func testLogDirectoryIsExcludedFromBackupAndOnlyThatDirectory() throws {
        let dir = TempDir()
        let log = RollingFileLog(url: dir.file("Parent/Logs/ppass.log"))
        let line = log.excludeDirectoryFromBackup()
        XCTAssertTrue(line.hasSuffix("excluded from backup = true"), line)
        let logs = dir.file("Parent/Logs")
        XCTAssertEqual(try logs.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertNotEqual(try dir.file("Parent").resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testWritesTimestampedLines() {
        let dir = TempDir()
        let log = RollingFileLog(url: dir.file("Logs/ppass.log"))
        log.write("hello")
        log.write("multi\nline")
        log.flush()
        let lines = (dir.read("Logs/ppass.log") ?? "").split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" hello"))
        XCTAssertTrue(lines[0].range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}"#, options: .regularExpression) != nil, lines[0])
        XCTAssertTrue(lines[1].hasSuffix(" multi line"))
    }

    func testRollsAndKeepsOnlyTwoFilesWithinCap() {
        let dir = TempDir()
        let cap = 1_000
        let log = RollingFileLog(url: dir.file("ppass.log"), maxBytes: cap)
        for i in 0..<200 { log.write("line \(i) " + String(repeating: "x", count: 40)) }
        log.flush()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.url.path)) ?? []).sorted()
        XCTAssertEqual(names, ["ppass.log", "ppass.log.1"])
        for n in names {
            let size = (try? FileManager.default.attributesOfItem(atPath: dir.file(n).path)[.size] as? Int) ?? 0
            XCTAssertLessThanOrEqual(size ?? 0, cap, n)
        }
        // 最新一行一定在，最老的已被滚掉。
        let all = (dir.read("ppass.log.1") ?? "") + (dir.read("ppass.log") ?? "")
        XCTAssertTrue(all.contains("line 199 "))
        XCTAssertFalse(all.contains("line 0 "))
    }

    func testResumesSizeFromExistingFile() {
        let dir = TempDir()
        let url = dir.file("ppass.log")
        let a = RollingFileLog(url: url, maxBytes: 500)
        a.write(String(repeating: "a", count: 300)); a.flush()
        let b = RollingFileLog(url: url, maxBytes: 500) // 进程重启后接着写
        b.write(String(repeating: "b", count: 300)); b.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.file("ppass.log.1").path))
    }

    func testWriteFailureDoesNotThrowOrCrashAndRecovers() throws {
        let dir = TempDir()
        // 目录位置被一个普通文件占住：创建目录必失败。
        dir.write("Logs", "blocker")
        let log = RollingFileLog(url: dir.file("Logs/ppass.log"))
        log.write("lost")
        log.flush() // 没崩、没抛
        try FileManager.default.removeItem(at: dir.file("Logs"))
        log.write("after")
        log.flush()
        XCTAssertTrue((dir.read("Logs/ppass.log") ?? "").hasSuffix(" after\n"))
    }

    func testConcurrentWritersKeepWholeLines() {
        let dir = TempDir()
        let log = RollingFileLog(url: dir.file("ppass.log"))
        DispatchQueue.concurrentPerform(iterations: 200) { log.write("n=\($0)") }
        log.flush()
        let lines = (dir.read("ppass.log") ?? "").split(separator: "\n")
        XCTAssertEqual(lines.count, 200)
    }

    func testRedaction() {
        XCTAssertEqual(LogRedact.id("A1B2-C3").count, 8)
        XCTAssertEqual(LogRedact.id("A1B2-C3"), LogRedact.id("A1B2-C3"))
        XCTAssertNotEqual(LogRedact.id("A1B2-C3"), LogRedact.id("A1B2-C4"))
        let ticket = "blobaaaaaaaabcdefghijklmnopqrstuvwxyz234567abcdefghij"
        let s = LogRedact.scrub("import failed: /tmp/IMG_0042.HEIC (Foo) ticket=\(ticket)")
        XCTAssertFalse(s.contains("IMG_0042"))
        XCTAssertFalse(s.contains(ticket))
        XCTAssertTrue(s.contains("<file>"))
        XCTAssertEqual(LogRedact.scrub("cycle [launch] round 12 open"), "cycle [launch] round 12 open")
    }

    // MARK: #1152 日志脱敏补 IP 与设备名

    func testPublicIpsAreMaskedButTimestampsVersionsAndHashesSurvive() {
        let line = LogRedact.scrub("connecting remote=203.0.113.7:4433 lan=192.168.1.20:4433 v6=[2001:db8::1]:7842")
        XCTAssertEqual(line, "connecting remote=<ipv4:public>:4433 lan=192.168.1.20:4433 v6=[<ipv6:public>]:7842")
        // 不该被抹掉的：时间戳（IPv6 规则最容易误吃）、版本号、hash 前缀、NodeId 之外的普通数字。
        for keep in ["16:54:02.631 cycle done", "version 0.10.0 build 42", "hash=1a2b3c4d round 12", "T01:49:50.5Z elapsed 0.58s"] {
            XCTAssertEqual(LogRedact.scrub(keep), keep, keep)
        }
    }

    func testRegisteredDeviceNamesAreMaskedEverywhereInALine() {
        LogRedact.resetDeviceNames()
        defer { LogRedact.resetDeviceNames() }
        XCTAssertEqual(LogRedact.scrub("hello from 妈妈的 iPhone"), "hello from 妈妈的 iPhone", "没登记的不动")
        LogRedact.registerDeviceNames(["妈妈的 iPhone", "客厅的电脑", "a"])
        XCTAssertEqual(LogRedact.scrub("hello from 妈妈的 iPhone via 客厅的电脑; 客厅的电脑 again"), "hello from <device> via <device>; <device> again")
        XCTAssertEqual(LogRedact.scrub("a b c"), "a b c", "单字符名字不登记")
    }
}
