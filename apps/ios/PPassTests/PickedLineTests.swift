import PPassCore
import XCTest
@testable import PPass

/// #1272：「挑几张传」行的进度 / 结果句与被杀后的提示（数字按实际）。文案在 Localizable / IOS.strings。
final class PickedLineTests: XCTestCase {
    private func batch(total: Int, delivered: Int = 0, existing: Int = 0, failed: Int = 0, interrupted: Bool = false) -> PickedBatchSummary {
        PickedBatchSummary(total: total, delivered: delivered, alreadyThere: existing, failed: failed, interrupted: interrupted)
    }

    func test_none_means_no_line() {
        XCTAssertNil(HomeProjection.pickedLine(nil))
        XCTAssertNil(HomeProjection.pickedInterruptedLine(nil))
    }

    func test_progress_counts_the_one_in_flight() {
        XCTAssertEqual(HomeProjection.pickedLine(batch(total: 5, delivered: 2)), L.f("picked_progress", 3, 5))
    }

    func test_result_sentences_match_android() {
        XCTAssertEqual(HomeProjection.pickedLine(batch(total: 3, delivered: 3)), L.f("picked_result_delivered", 3))
        XCTAssertEqual(HomeProjection.pickedLine(batch(total: 3, delivered: 1, existing: 2)), L.f("picked_result_with_existing", 3, 2))
        XCTAssertEqual(HomeProjection.pickedLine(batch(total: 3, delivered: 2, failed: 1)),
                       L.f("picked_result_delivered", 2) + " · " + L.f("picked_result_failed", 1))
        XCTAssertEqual(HomeProjection.pickedLine(batch(total: 2, failed: 2)), L.f("picked_result_failed", 2))
    }

    func test_interrupted_batch_is_not_a_row_value_but_a_hero_line_with_real_numbers() {
        let b = batch(total: 12, delivered: 9, interrupted: true)
        XCTAssertNil(HomeProjection.pickedLine(b))
        XCTAssertEqual(HomeProjection.pickedInterruptedLine(b), L.f("picked_interrupted", 12, 3))
        XCTAssertNil(HomeProjection.pickedInterruptedLine(batch(total: 12, delivered: 12, interrupted: true)), "全送达就没有要提示的")
    }
}
