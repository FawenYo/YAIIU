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
}
