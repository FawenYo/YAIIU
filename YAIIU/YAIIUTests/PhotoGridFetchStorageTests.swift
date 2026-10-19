import Foundation
import XCTest
@testable import YAIIU

final class PhotoGridFetchStorageTests: XCTestCase {
    private final class Fetch: NSObject {}

    func testCapturedViewStorageDoesNotKeepReplacedFetchAlive() {
        let storage = PhotoGridFetchStorage<Fetch>()
        storage.filtered = Fetch()
        weak var previous = storage.filtered
        let capturedStorage = storage

        storage.filtered = Fetch()

        XCTAssertNil(previous)
        XCTAssertTrue(capturedStorage.filtered === storage.filtered)
    }

    func testCachedFilterKeepsFetchUntilBothOwnersReplaceIt() {
        let storage = PhotoGridFetchStorage<Fetch>()
        storage.filtered = Fetch()
        storage.cachedNotUploaded = storage.filtered
        weak var previous = storage.filtered
        let capturedStorage = storage

        storage.filtered = Fetch()
        XCTAssertNotNil(previous, "The cached indices still need their original fetch.")
        storage.cachedNotUploaded = storage.filtered

        XCTAssertNil(previous)
        XCTAssertTrue(capturedStorage.cachedNotUploaded === storage.filtered)
    }

    func testCapturedCellSnapshotExpiresWithoutRebindingToNewFetch() {
        let storage = PhotoGridFetchStorage<Fetch>()
        storage.filtered = Fetch()
        let cellSnapshot = storage.filteredSnapshot
        XCTAssertTrue(cellSnapshot.value === storage.filtered)

        storage.filtered = Fetch()

        XCTAssertNil(cellSnapshot.value, "An old cell must not retain or read a different indexed fetch.")
        XCTAssertNotNil(storage.filteredSnapshot.value)
    }

    func testEmptyFilteredSnapshotStaysEmptyAfterReplacement() {
        let storage = PhotoGridFetchStorage<Fetch>()
        let cellSnapshot = storage.filteredSnapshot
        storage.filtered = Fetch()

        XCTAssertNil(cellSnapshot.value)
    }
}
