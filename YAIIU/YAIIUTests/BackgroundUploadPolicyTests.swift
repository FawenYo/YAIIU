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

final class BackgroundUploadCreationRecoveryTests: XCTestCase {
    private var suites = [String]()

    override func tearDown() {
        for suite in suites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        super.tearDown()
    }

    private func makePreferences() -> UserDefaults {
        let suite = "BackgroundUploadCreationRecoveryTests.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    func testInternalCreationFailureGetsOnlyOneRecoveryAcrossExtensionInstances() {
        let preferences = makePreferences()
        let error = NSError(domain: "PHPhotosErrorDomain", code: -1)
        let first = BackgroundUploadCreationRecovery(preferences: preferences)
        XCTAssertTrue(first.requestRetry(after: error))
        XCTAssertFalse(first.requestRetry(after: error))
        let relaunched = BackgroundUploadCreationRecovery(preferences: preferences)
        XCTAssertFalse(relaunched.requestRetry(after: error))
    }

    func testSuccessfulCreationAllowsRecoveryOfALaterFailure() {
        let recovery = BackgroundUploadCreationRecovery(preferences: makePreferences())
        let error = NSError(domain: "PHPhotosErrorDomain", code: -1)
        XCTAssertTrue(recovery.requestRetry(after: error))
        recovery.recordSuccessfulCreation()
        XCTAssertTrue(recovery.requestRetry(after: error))
        XCTAssertFalse(recovery.requestRetry(after: error))
    }

    func testOtherErrorsDoNotConsumeOrReceiveStateRecovery() {
        let recovery = BackgroundUploadCreationRecovery(preferences: makePreferences())
        XCTAssertFalse(recovery.requestRetry(after: NSError(domain: NSURLErrorDomain, code: -1)))
        XCTAssertFalse(recovery.requestRetry(after: NSError(domain: "PHPhotosErrorDomain", code: 3201)))
        XCTAssertTrue(recovery.requestRetry(after: NSError(domain: "PHPhotosErrorDomain", code: -1)))
    }

    func testMissingPersistentStorageDoesNotAllowUnboundedRecoveryOnRelaunch() {
        let recovery = BackgroundUploadCreationRecovery(preferences: nil)
        XCTAssertFalse(recovery.requestRetry(after: NSError(domain: "PHPhotosErrorDomain", code: -1)))
    }
}
