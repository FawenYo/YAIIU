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

    func testVisibleDetailCanOpenWhileContentRefreshRebuildsFilters() {
        let storage = PhotoGridFetchStorage<Fetch>()
        var generation = PhotoLibraryIndexGeneration()
        generation.recordReload()
        storage.filtered = Fetch()
        storage.filteredIndexGeneration = generation.value

        // The full fetch generation and filter-loading state may change while
        // iCloud thumbnails finish. Neither changes these visible positions.
        for _ in 0..<3 {
            generation.recordChange(
                isIncremental: true, insertedCount: 0, removedCount: 0, hasMoves: false
            )
            XCTAssertTrue(storage.canOpenFilteredDetail(
                at: 2, displayCount: 4, indexGeneration: generation.value
            ))
        }
    }

    func testVisibleDetailRejectsOldPositionsAfterInsertionAndContentRefresh() {
        let storage = PhotoGridFetchStorage<Fetch>()
        var generation = PhotoLibraryIndexGeneration()
        storage.filtered = Fetch()
        storage.filteredIndexGeneration = generation.value
        generation.recordChange(
            isIncremental: true, insertedCount: 1, removedCount: 0, hasMoves: false
        )
        generation.recordChange(
            isIncremental: true, insertedCount: 0, removedCount: 0, hasMoves: false
        )

        XCTAssertFalse(storage.canOpenFilteredDetail(
            at: 2, displayCount: 4, indexGeneration: generation.value
        ))
    }

    func testDetailRejectsMissingSnapshotOrUnknownPositionGeneration() {
        let storage = PhotoGridFetchStorage<Fetch>()
        XCTAssertFalse(storage.canOpenFilteredDetail(at: 0, displayCount: 1, indexGeneration: 0))
        storage.filtered = Fetch()
        XCTAssertFalse(storage.canOpenFilteredDetail(at: 0, displayCount: 1, indexGeneration: 0))
        storage.filteredIndexGeneration = 0
        storage.filtered = nil
        XCTAssertFalse(storage.canOpenFilteredDetail(at: 0, displayCount: 1, indexGeneration: 0))
    }

    func testDetailRejectsPositionsOutsideVisibleSnapshot() {
        let storage = PhotoGridFetchStorage<Fetch>()
        storage.filtered = Fetch()
        storage.filteredIndexGeneration = 0

        for (index, count) in [(-1, 4), (4, 4), (0, 0)] {
            XCTAssertFalse(storage.canOpenFilteredDetail(
                at: index, displayCount: count, indexGeneration: 0
            ))
        }
    }

    func testNotUploadedFilterReusesPositionsAcrossContentUpdates() {
        let storage = PhotoGridFetchStorage<Fetch>()
        storage.cachedNotUploaded = Fetch()
        storage.cachedNotUploadedIndexGeneration = 2
        storage.cachedNotUploadedStatusGeneration = 4
        XCTAssertTrue(storage.canReuseNotUploadedIndices(indexGeneration: 2, statusGeneration: 4))
    }

    func testNotUploadedFilterRebuildsWhenStatusOrPositionsChange() {
        let storage = PhotoGridFetchStorage<Fetch>()
        storage.cachedNotUploaded = Fetch()
        storage.cachedNotUploadedIndexGeneration = 2
        storage.cachedNotUploadedStatusGeneration = 4
        XCTAssertFalse(storage.canReuseNotUploadedIndices(indexGeneration: 2, statusGeneration: 5))
        XCTAssertFalse(storage.canReuseNotUploadedIndices(indexGeneration: 3, statusGeneration: 4))
    }

    func testNotUploadedFilterRequiresCompletedCachedSnapshot() {
        let storage = PhotoGridFetchStorage<Fetch>()
        storage.cachedNotUploaded = Fetch()
        XCTAssertFalse(storage.canReuseNotUploadedIndices(indexGeneration: 2, statusGeneration: 4))
        storage.cachedNotUploadedIndexGeneration = 2
        storage.cachedNotUploadedStatusGeneration = 4
        storage.cachedNotUploaded = nil
        XCTAssertFalse(storage.canReuseNotUploadedIndices(indexGeneration: 2, statusGeneration: 4))
    }
}
