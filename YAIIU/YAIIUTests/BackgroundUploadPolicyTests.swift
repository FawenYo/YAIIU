import XCTest
import Photos
@testable import YAIIU

final class BackgroundUploadPolicyTests: XCTestCase {
    func testLivePhotoVideoSelectionPrefersEditedVersionOnce() {
        XCTAssertEqual(
            BackgroundUploadPolicy.preferredLivePhotoVideoIndex(types: [
                .photo, .pairedVideo, .fullSizePairedVideo
            ]), 2
        )
        XCTAssertEqual(
            BackgroundUploadPolicy.preferredLivePhotoVideoIndex(types: [
                .fullSizePairedVideo, .pairedVideo, .photo
            ]), 0
        )
        XCTAssertEqual(
            BackgroundUploadPolicy.preferredLivePhotoVideoIndex(types: [
                .photo, .pairedVideo
            ]), 1
        )
        XCTAssertNil(BackgroundUploadPolicy.preferredLivePhotoVideoIndex(types: [
            .photo, .alternatePhoto
        ]))
    }

    func testForegroundPriorityAlwaysPrefersFullSizePairedVideo() {
        // PhotoKit may enumerate generic full-size video either before or
        // after the actual Live Photo paired companion.
        XCTAssertGreaterThan(
            BackgroundUploadPolicy.livePhotoVideoPriority(.fullSizePairedVideo),
            BackgroundUploadPolicy.livePhotoVideoPriority(.fullSizeVideo)
        )
        XCTAssertGreaterThan(
            BackgroundUploadPolicy.livePhotoVideoPriority(.pairedVideo),
            BackgroundUploadPolicy.livePhotoVideoPriority(.fullSizeVideo)
        )
        XCTAssertEqual(
            BackgroundUploadPolicy.preferredLivePhotoVideoIndex(types: [
                .fullSizePairedVideo, .fullSizeVideo
            ]), 0
        )
        XCTAssertEqual(
            BackgroundUploadPolicy.preferredLivePhotoVideoIndex(types: [
                .fullSizeVideo, .fullSizePairedVideo
            ]), 1
        )
    }

    func testLivePhotoPairedVideoResourcesAreUploadable() {
        XCTAssertTrue(BackgroundUploadPolicy.isUploadableResourceType(.pairedVideo))
        XCTAssertTrue(BackgroundUploadPolicy.isUploadableResourceType(.fullSizePairedVideo))
        XCTAssertTrue(BackgroundUploadPolicy.isUploadableResourceType(.photo))
        XCTAssertTrue(BackgroundUploadPolicy.isUploadableResourceType(.fullSizePhoto))
        XCTAssertTrue(BackgroundUploadPolicy.isUploadableResourceType(.alternatePhoto))
    }


    func testDisallowingCellularOnlyAllowsWiFi() {
        XCTAssertTrue(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: false, interface: .wifi))
        XCTAssertFalse(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: false, interface: .cellular))
        XCTAssertFalse(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: false, interface: .other))
        XCTAssertFalse(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: false, interface: .unavailable))
    }

    func testAllowingCellularAllowsWiFiAndCellularOnly() {
        XCTAssertTrue(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: true, interface: .wifi))
        XCTAssertTrue(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: true, interface: .cellular))
        XCTAssertFalse(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: true, interface: .other))
        XCTAssertFalse(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: true, interface: .unavailable))
    }
    func testNewJobRequestDisallowsCellularWhenPreferenceIsOff() {
        XCTAssertFalse(BackgroundUploadPolicy.allowsCellularAccess(for: .newJob, allowCellular: false))
        XCTAssertTrue(BackgroundUploadPolicy.allowsCellularAccess(for: .newJob, allowCellular: true))
    }
    func testRetryRequestRemainsAllowedOnCellular() {
        XCTAssertTrue(BackgroundUploadPolicy.allowsCellularAccess(for: .retry, allowCellular: false))
    }

    func testUnknownNetworkDoesNotCreateJobs() {
        XCTAssertFalse(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: false, interface: .unknown))
        XCTAssertFalse(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: true, interface: .unknown))
    }

    func testUnavailableNetworkDoesNotCreateJobs() {
        XCTAssertFalse(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: true, interface: .unavailable))
    }
}
