import XCTest
@testable import YAIIU

final class CoalescingRefreshTests: XCTestCase {
    func testBurstKeepsOneReadInFlightAndPublishesOnlyLatestSnapshot() async {
        await MainActor.run {
            var reads: [(Int) -> Void] = []
            var published: [Int] = []
            var completed = 0
            let refresh = CoalescingRefresh<Int>(load: { reads.append($0) }, publish: { published.append($0) })
            for _ in 0..<20 { refresh.refresh { _ in completed += 1 } }
            XCTAssertEqual(reads.count, 1)
            reads[0](1)
            XCTAssertEqual(reads.count, 2)
            XCTAssertTrue(published.isEmpty)
            XCTAssertEqual(completed, 0)
            reads[1](2)
            XCTAssertEqual(published, [2])
            XCTAssertEqual(completed, 20)
        }
    }

    func testRefreshDuringFollowupReadIsNotLost() async {
        await MainActor.run {
            var reads: [(Int) -> Void] = []
            var published: [Int] = []
            let refresh = CoalescingRefresh<Int>(load: { reads.append($0) }, publish: { published.append($0) })
            refresh.refresh()
            refresh.refresh()
            reads[0](1)
            refresh.refresh()
            reads[1](2)
            XCTAssertEqual(reads.count, 3)
            XCTAssertTrue(published.isEmpty)
            reads[2](3)
            XCTAssertEqual(published, [3])
        }
    }

    func testReentrantPublicationDoesNotCompleteNewRequestEarly() async {
        await MainActor.run {
            var reads: [(Int) -> Void] = []
            var completed: [String] = []
            var refresh: CoalescingRefresh<Int>!
            refresh = CoalescingRefresh<Int>(load: { reads.append($0) }, publish: { value in
                if value == 1 { refresh.refresh { _ in completed.append("new") } }
            })
            refresh.refresh { _ in completed.append("first") }
            reads[0](1)
            XCTAssertEqual(completed, ["first"])
            reads[1](2)
            XCTAssertEqual(completed, ["first", "new"])
        }
    }
}
