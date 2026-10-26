// #1119：未配对时不再向系统挂后台任务；断开 / 被拒即清理时取消全部（长任务 + 短任务）。
import Foundation
import XCTest
@testable import PPassCore

final class UnpairedSchedulingTests: XCTestCase {
    private func scheduler(_ dir: TempDir, _ submitter: RecordingSubmitter, paired: Locked<Bool>) -> PlannedWakeScheduler {
        PlannedWakeScheduler(directory: dir.url, submitter: submitter, logger: NoopLogger(), isPaired: { paired.get() })
    }

    /// 未配对：启动 / 回前台的重排、引擎登记的唤醒、短任务续挂，一概不提交。配对后恢复提交。
    /// 反证：去掉 `resubmit` / `ensureShortScheduled` 里的 isPaired 判断，未配对段的断言红。
    func testNothingIsSubmittedWhileUnpaired() {
        let dir = TempDir()
        let submitter = RecordingSubmitter()
        let paired = Locked(false)
        let s = scheduler(dir, submitter, paired: paired)
        s.ensureScheduled()
        s.ensureShortScheduled()
        s.scheduleUnreachableProbes()
        s.scheduleWhenConditionsMet(.wifi)
        s.didRun(.periodic)
        XCTAssertEqual(submitter.submitted.get().count, 0, "未配对不挂长任务")
        XCTAssertEqual(submitter.shorts.get().count, 0, "未配对不挂短任务")

        paired.set(true)
        s.ensureScheduled()
        s.ensureShortScheduled()
        XCTAssertEqual(submitter.submitted.get().count, 1)
        XCTAssertEqual(submitter.shorts.get().count, 1)
    }

    /// 断开：计划文件删掉、系统请求全部取消（提交器的 cancelAll 同时撤长任务与短任务）；之后（已无配对）重排也不再提交。
    /// 反证：`stop()` 不调 cancelAll，cancels 为 0，红。
    func testStopCancelsEverythingAndNothingComesBackAfterwards() {
        let dir = TempDir()
        let submitter = RecordingSubmitter()
        let paired = Locked(true)
        let s = scheduler(dir, submitter, paired: paired)
        s.scheduleUnreachableProbes()
        s.ensureShortScheduled()
        XCTAssertEqual(submitter.submitted.get().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.file(PlannedWakeScheduler.fileName).path))

        s.stop()
        paired.set(false) // 清理删了配对记录
        XCTAssertEqual(submitter.cancels.get(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.file(PlannedWakeScheduler.fileName).path))
        s.ensureScheduled()
        s.ensureShortScheduled()
        s.cancelUnreachableProbes()
        XCTAssertEqual(submitter.submitted.get().count, 1, "取消之后不再有新的提交")
        XCTAssertEqual(submitter.shorts.get().count, 1)
    }
}
