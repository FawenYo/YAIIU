import XCTest
@testable import YAIIU

final class BackgroundUploadPolicyTests: XCTestCase {
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
    func testIsolationGroupsPreserveAssetSiblings() {
        let jobs = [
            ("asset-a", "heic"), ("asset-b", "jpeg"),
            ("asset-a", "raw"), ("asset-c", "heic")
        ]
        let groups = BackgroundUploadPolicy.isolationGroups(
            jobs, maxGroups: 2, assetIdentifier: { $0.0 }
        )
        XCTAssertEqual(groups.map { $0.map { $0.1 } }, [["heic", "raw"], ["jpeg"]])
    }

    func testIsolationGroupsEnforceBoundAndReturnEmptyForZeroLimit() {
        let jobs = ["a", "b", "a", "c", "d"]
        let bounded = BackgroundUploadPolicy.isolationGroups(
            jobs, maxGroups: 2, assetIdentifier: { $0 }
        )
        XCTAssertEqual(bounded, [["a", "a"], ["b"]])
        let empty = BackgroundUploadPolicy.isolationGroups(
            jobs, maxGroups: 0, assetIdentifier: { $0 }
        )
        XCTAssertTrue(empty.isEmpty)
    }

}
