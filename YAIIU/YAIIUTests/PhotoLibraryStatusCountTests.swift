import XCTest
@testable import YAIIU

final class PhotoLibraryStatusCountTests: XCTestCase {
    func testProvisionalStatusIsInvalidatedOnlyOnDestinationChange() {
        XCTAssertFalse(PhotoLibraryStatusCount.destinationChanged(previous: nil, current: "server|first"))
        XCTAssertFalse(PhotoLibraryStatusCount.destinationChanged(previous: "server|first", current: "server|first"))
        XCTAssertTrue(PhotoLibraryStatusCount.destinationChanged(previous: "server|first", current: "server|second"))
        XCTAssertTrue(PhotoLibraryStatusCount.destinationChanged(previous: "server|first", current: "other|first"))
    }

    func testNotUploadedFilterUsesProvisionalCacheWhileBadgeIsHidden() {
        let buildable = PhotoLibraryStatusCount.canBuildNotUploadedFilter(
            hasLoadedStatusSnapshot: true,
            hasPhotoLibraryFetch: true,
            isPhotoLibraryLoading: false
        )
        XCTAssertTrue(buildable)

        // Migration/hash verification can make the authoritative badge
        // unavailable without disabling the interactive photo filter.
        XCTAssertFalse(PhotoLibraryStatusCount.canPresentCount(
            statusCacheReady: false, inventoryUpToDate: false,
            isServerSyncing: true, isHashProcessing: true,
            isUploading: false, hasFullPhotoAccess: true,
            hasPhotoLibraryFetch: true, isPhotoLibraryLoading: false
        ))
        XCTAssertFalse(PhotoLibraryStatusCount.canBuildNotUploadedFilter(
            hasLoadedStatusSnapshot: false,
            hasPhotoLibraryFetch: true,
            isPhotoLibraryLoading: false
        ))
        XCTAssertFalse(PhotoLibraryStatusCount.canBuildNotUploadedFilter(
            hasLoadedStatusSnapshot: true,
            hasPhotoLibraryFetch: false,
            isPhotoLibraryLoading: false
        ))
        XCTAssertFalse(PhotoLibraryStatusCount.canBuildNotUploadedFilter(
            hasLoadedStatusSnapshot: true,
            hasPhotoLibraryFetch: true,
            isPhotoLibraryLoading: true
        ))
    }

    func testBadgeRequiresBothStoresAndNoActiveSyncWork() {
        func canShow(
            ready: Bool = true, inventoryReady: Bool = true,
            syncing: Bool = false, processing: Bool = false,
            uploading: Bool = false, fullAccess: Bool = true,
            hasFetch: Bool = true, loading: Bool = false
        ) -> Bool {
            PhotoLibraryStatusCount.canPresentCount(
                statusCacheReady: ready, inventoryUpToDate: inventoryReady,
                isServerSyncing: syncing,
                isHashProcessing: processing, isUploading: uploading,
                hasFullPhotoAccess: fullAccess, hasPhotoLibraryFetch: hasFetch,
                isPhotoLibraryLoading: loading
            )
        }
        XCTAssertTrue(canShow())
        XCTAssertFalse(canShow(ready: false))
        XCTAssertFalse(canShow(inventoryReady: false))
        XCTAssertFalse(canShow(syncing: true))
        XCTAssertFalse(canShow(processing: true))
        XCTAssertFalse(canShow(uploading: true))
        XCTAssertFalse(canShow(fullAccess: false))
        XCTAssertFalse(canShow(hasFetch: false))
        XCTAssertFalse(canShow(loading: true))
    }

}
