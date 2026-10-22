import XCTest
@testable import YAIIU

final class PhotoLibraryStatusCountTests: XCTestCase {
    func testBadgeRequiresBothStoresAndNoActiveSyncWork() {
        func canShow(
            ready: Bool = true, syncing: Bool = false, processing: Bool = false,
            uploading: Bool = false, fullAccess: Bool = true,
            hasFetch: Bool = true, loading: Bool = false
        ) -> Bool {
            PhotoLibraryStatusCount.canPresentCount(
                statusCacheReady: ready, isServerSyncing: syncing,
                isHashProcessing: processing, isUploading: uploading,
                hasFullPhotoAccess: fullAccess, hasPhotoLibraryFetch: hasFetch,
                isPhotoLibraryLoading: loading
            )
        }
        XCTAssertTrue(canShow())
        XCTAssertFalse(canShow(ready: false))
        XCTAssertFalse(canShow(syncing: true))
        XCTAssertFalse(canShow(processing: true))
        XCTAssertFalse(canShow(uploading: true))
        XCTAssertFalse(canShow(fullAccess: false))
        XCTAssertFalse(canShow(hasFetch: false))
        XCTAssertFalse(canShow(loading: true))
    }

}
