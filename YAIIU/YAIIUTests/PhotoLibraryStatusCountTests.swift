import XCTest
@testable import YAIIU

final class PhotoLibraryStatusCountTests: XCTestCase {
    func testBadgeRequiresBothStoresAndNoActiveSyncWork() {
        func canShow(
            ready: Bool = true, syncing: Bool = false, processing: Bool = false,
            uploading: Bool = false, hasFetch: Bool = true, loading: Bool = false
        ) -> Bool {
            PhotoLibraryStatusCount.canPresentCount(
                statusCacheReady: ready, isServerSyncing: syncing,
                isHashProcessing: processing, isUploading: uploading,
                hasPhotoLibraryFetch: hasFetch,
                isPhotoLibraryLoading: loading
            )
        }
        XCTAssertTrue(canShow())
        XCTAssertFalse(canShow(ready: false))
        XCTAssertFalse(canShow(syncing: true))
        XCTAssertFalse(canShow(processing: true))
        XCTAssertFalse(canShow(uploading: true))
        XCTAssertFalse(canShow(hasFetch: false))
        XCTAssertFalse(canShow(loading: true))
    }

    func testCountUsesOnlyVisibleUploadedAssetsAndIncludesUnknownPhotos() {
        let statuses: [String: PhotoSyncStatus] = [
            "visible": .uploaded, "hidden": .uploaded, "deleted": .uploaded,
            "pending": .pending, "error": .error, "missingUpload": .notUploaded
        ]
        var queried = Set<String>()
        let count = PhotoLibraryStatusCount.notUploadedCount(totalCount: 5, statuses: statuses) { identifiers in
            queried.formUnion(identifiers)
            return identifiers.contains("visible") ? 1 : 0
        }
        XCTAssertEqual(count, 4)
        XCTAssertEqual(queried, ["visible", "hidden", "deleted"])
    }

    func testLargeStatusMapUsesBoundedPhotoKitQueries() {
        let statuses = Dictionary(uniqueKeysWithValues: (0..<601).map { ("asset-\($0)", PhotoSyncStatus.uploaded) })
        var sizes: [Int] = []
        let count = PhotoLibraryStatusCount.notUploadedCount(totalCount: 603, statuses: statuses) { identifiers in
            sizes.append(identifiers.count)
            return identifiers.count
        }
        XCTAssertEqual(sizes, [300, 300, 1])
        XCTAssertEqual(count, 2)
    }

    func testCancellationDoesNotPublishPartialCount() {
        let statuses = ["a": PhotoSyncStatus.uploaded, "b": .uploaded]
        var stopped = false
        let count = PhotoLibraryStatusCount.notUploadedCount(
            totalCount: 3, statuses: statuses, batchSize: 1,
            shouldStop: { stopped }
        ) { _ in
            stopped = true
            return 1
        }
        XCTAssertNil(count)
    }

    func testNoUploadedStatusesDoesNotFetchPhotoKit() {
        let count = PhotoLibraryStatusCount.notUploadedCount(totalCount: 3, statuses: ["a": .pending]) { _ in
            XCTFail("No uploaded IDs require no PhotoKit query")
            return 0
        }
        XCTAssertEqual(count, 3)
    }
}
