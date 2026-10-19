import XCTest
@testable import YAIIU

final class PhotoLibraryIndexGenerationTests: XCTestCase {
    func testCloudDownloadUpdatesPreserveOpenDetailPositions() {
        var generation = PhotoLibraryIndexGeneration()
        generation.recordReload()
        let openedDetailGeneration = generation.value

        // Image download and metadata completion can each publish an update.
        for _ in 0..<2 {
            generation.recordChange(
                isIncremental: true, insertedCount: 0, removedCount: 0, hasMoves: false
            )
        }

        XCTAssertEqual(generation.value, openedDetailGeneration)
    }

    func testInsertionInvalidatesDetailEvenAfterAnotherContentUpdate() {
        var generation = PhotoLibraryIndexGeneration()
        let openedDetailGeneration = generation.value
        generation.recordChange(
            isIncremental: true, insertedCount: 1, removedCount: 0, hasMoves: false
        )
        generation.recordChange(
            isIncremental: true, insertedCount: 0, removedCount: 0, hasMoves: false
        )

        XCTAssertNotEqual(generation.value, openedDetailGeneration)
        XCTAssertEqual(generation.value, 1)
    }

    func testRemovalInvalidatesPositions() {
        var generation = PhotoLibraryIndexGeneration()
        generation.recordChange(
            isIncremental: true, insertedCount: 0, removedCount: 1, hasMoves: false
        )
        XCTAssertEqual(generation.value, 1)
    }

    func testReplacementInvalidatesPositionsEvenWhenCountIsUnchanged() {
        var generation = PhotoLibraryIndexGeneration()
        generation.recordChange(
            isIncremental: true, insertedCount: 1, removedCount: 1, hasMoves: false
        )
        XCTAssertEqual(generation.value, 1)
    }

    func testMoveInvalidatesPositionsWithoutInsertionsOrRemovals() {
        var generation = PhotoLibraryIndexGeneration()
        generation.recordChange(
            isIncremental: true, insertedCount: 0, removedCount: 0, hasMoves: true
        )
        XCTAssertEqual(generation.value, 1)
    }

    func testNonincrementalChangesInvalidateUnknownPositions() {
        var generation = PhotoLibraryIndexGeneration()
        generation.recordChange(
            isIncremental: false, insertedCount: 0, removedCount: 0, hasMoves: false
        )
        XCTAssertEqual(generation.value, 1)
    }

    func testExplicitReloadInvalidatesPreviousDetailGeneration() {
        var generation = PhotoLibraryIndexGeneration()
        generation.recordReload()
        let openedDetailGeneration = generation.value
        generation.recordReload()
        XCTAssertNotEqual(generation.value, openedDetailGeneration)
    }
}
