import Foundation
import XCTest
@testable import YAIIU

final class PhotoLibraryEnumerationTests: XCTestCase {
    private final class LifetimeCounter {
        var live = 0
        var peak = 0
    }

    private final class Temporary: NSObject {
        let counter: LifetimeCounter

        init(counter: LifetimeCounter) {
            self.counter = counter
            counter.live += 1
            counter.peak = max(counter.peak, counter.live)
        }

        deinit { counter.live -= 1 }
    }

    func testDrainsFetchAndCallbackTemporariesBeforeNextAsset() {
        let counter = LifetimeCounter()
        var visited = 0
        autoreleasepool {
            let completed = PhotoLibraryEnumeration.forEach(
                count: 1_000,
                objectAt: { index in
                    // PhotoKit creates autoreleased buffers before invoking its callback.
                    _ = Unmanaged.passRetained(Temporary(counter: counter)).autorelease()
                    return index
                }
            ) { _, _ in
                _ = Unmanaged.passRetained(Temporary(counter: counter)).autorelease()
                visited += 1
            }
            XCTAssertTrue(completed)
            XCTAssertEqual(visited, 1_000)
            XCTAssertEqual(counter.live, 0)
            XCTAssertLessThanOrEqual(counter.peak, 2)
        }
    }

    func testPreservesFetchOrderAndIndices() {
        let identifiers = ["newest", "middle", "oldest"]
        var visited: [String] = []
        var indices: [Int] = []
        let completed = PhotoLibraryEnumeration.forEach(
            count: identifiers.count, objectAt: { identifiers[$0] }
        ) { identifier, index in
            visited.append(identifier)
            indices.append(index)
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(visited, ["newest", "middle", "oldest"])
        XCTAssertEqual(indices, [0, 1, 2])
    }

    func testSparseChangesOnlyReadSelectedAfterChangeIndices() {
        // Insertion and removal shift indices; changedIndexes uses the after state.
        let after = ["inserted", "unchanged", "edited", "moved", "also-edited"]
        var fetched: [Int] = []
        var identifiers: Set<String> = []
        let completed = PhotoLibraryEnumeration.forEach(
            indices: IndexSet([2, 4]),
            objectAt: { index in
                fetched.append(index)
                return after[index]
            }
        ) { identifier, _ in
            identifiers.insert(identifier)
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(fetched, [2, 4])
        XCTAssertEqual(identifiers, ["edited", "also-edited"])
    }

    func testSparseChangesDoNotMaterializeTheWholeChangedObjectArray() {
        let counter = LifetimeCounter()
        autoreleasepool {
            let completed = PhotoLibraryEnumeration.forEach(
                indices: IndexSet(stride(from: 0, to: 2_000, by: 2)),
                objectAt: { _ in
                    _ = Unmanaged.passRetained(Temporary(counter: counter)).autorelease()
                    return Temporary(counter: counter)
                }
            ) { _, _ in }
            XCTAssertTrue(completed)
            XCTAssertEqual(counter.live, 0)
            XCTAssertLessThanOrEqual(counter.peak, 2)
        }
    }

    func testEmptyChangesDoNotFetchObjects() {
        let completed = PhotoLibraryEnumeration.forEach(
            indices: IndexSet(),
            objectAt: { index in
                XCTFail("Empty change set fetched an asset")
                return index
            }
        ) { _, _ in XCTFail("Empty change set consumed an asset") }
        XCTAssertTrue(completed)
    }

    func testCancellationStopsBeforeFetchingNextAsset() {
        var fetched: [Int] = []
        var visited: [Int] = []
        let completed = PhotoLibraryEnumeration.forEach(
            count: 10,
            objectAt: { index in
                fetched.append(index)
                return index
            },
            shouldStop: { visited.count == 2 }
        ) { value, _ in
            visited.append(value)
        }
        XCTAssertFalse(completed)
        XCTAssertEqual(fetched, [0, 1])
        XCTAssertEqual(visited, [0, 1])
    }

    func testAlreadyCancelledScanDoesNotFetchAnyAsset() {
        let completed = PhotoLibraryEnumeration.forEach(
            count: 10,
            objectAt: { index in
                XCTFail("Cancelled scan fetched an asset")
                return index
            },
            shouldStop: { true }
        ) { _, _ in XCTFail("Cancelled scan consumed an asset") }
        XCTAssertFalse(completed)
    }

    func testEmptyLibraryCompletesWithoutFetching() {
        let completed = PhotoLibraryEnumeration.forEach(
            count: 0,
            objectAt: { index in
                XCTFail("Empty scan fetched an asset")
                return index
            }
        ) { _, _ in XCTFail("Empty scan consumed an asset") }
        XCTAssertTrue(completed)
    }
}
