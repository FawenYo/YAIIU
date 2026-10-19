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

    func testContentUpdatesReuseCompletedIdentifierSnapshot() {
        var generation = PhotoLibraryIndexGeneration()
        generation.recordReload()
        let snapshotGeneration = generation.value
        generation.recordChange(
            isIncremental: true, insertedCount: 0, removedCount: 0, hasMoves: false
        )
        XCTAssertTrue(generation.canReuseIdentifiers(
            from: snapshotGeneration, snapshotIsReady: true, snapshotCount: 100, assetCount: 100
        ))
    }

    func testPendingOrIncompleteIdentifierSnapshotRequiresScan() {
        let generation = PhotoLibraryIndexGeneration()
        XCTAssertFalse(generation.canReuseIdentifiers(
            from: generation.value, snapshotIsReady: false, snapshotCount: 100, assetCount: 100
        ))
        XCTAssertFalse(generation.canReuseIdentifiers(
            from: generation.value, snapshotIsReady: true, snapshotCount: 99, assetCount: 100
        ))
    }

    func testStructuralChangeCannotReuseSnapshotEvenWithEqualCounts() {
        var generation = PhotoLibraryIndexGeneration()
        let snapshotGeneration = generation.value
        generation.recordChange(
            isIncremental: true, insertedCount: 1, removedCount: 1, hasMoves: false
        )
        XCTAssertFalse(generation.canReuseIdentifiers(
            from: snapshotGeneration, snapshotIsReady: true, snapshotCount: 100, assetCount: 100
        ))
    }
    func testBackToBackEditsPreserveBothAssetsUntilRendering() {
        // The UI can receive only the latest fetch after edits to A and B.
        let original = PhotoAssetContentRevision(library: 0, asset: 0)
        let changed = PhotoAssetContentRevision(library: 0, asset: 1)
        for id in ["A", "B"] {
            XCTAssertTrue(PhotoAssetContentRevision.needsReload(
                previousIdentifier: id, previousRevision: original,
                currentIdentifier: id, currentRevision: changed
            ))
        }
    }

    func testUnrelatedUpdateDoesNotReloadAlreadyRefreshedAsset() {
        let observed = PhotoAssetContentRevision(library: 0, asset: 1)
        XCTAssertFalse(PhotoAssetContentRevision.needsReload(
            previousIdentifier: "A", previousRevision: observed,
            currentIdentifier: "A", currentRevision: observed
        ))
    }

    func testMultipleEditsBeforeRenderStillTriggerOneRefresh() {
        XCTAssertTrue(PhotoAssetContentRevision.needsReload(
            previousIdentifier: "A",
            previousRevision: PhotoAssetContentRevision(library: 2, asset: 1),
            currentIdentifier: "A",
            currentRevision: PhotoAssetContentRevision(library: 2, asset: 3)
        ))
    }

    func testFullLibraryResetTriggersRefresh() {
        XCTAssertTrue(PhotoAssetContentRevision.needsReload(
            previousIdentifier: "A",
            previousRevision: PhotoAssetContentRevision(library: 2, asset: 5),
            currentIdentifier: "A",
            currentRevision: PhotoAssetContentRevision(library: 3, asset: 0)
        ))
    }

    func testNewAssetUsesInitialLoadInsteadOfReload() {
        let rev = PhotoAssetContentRevision(library: 0, asset: 0)
        XCTAssertFalse(PhotoAssetContentRevision.needsReload(
            previousIdentifier: nil, previousRevision: nil,
            currentIdentifier: "A", currentRevision: rev
        ))
        XCTAssertFalse(PhotoAssetContentRevision.needsReload(
            previousIdentifier: "A", previousRevision: rev,
            currentIdentifier: "B", currentRevision: rev
        ))
    }
}
