import XCTest
@testable import YAIIU

final class SyncStreamParserTests: XCTestCase {
    func testMetadataParserReturnsMobileAppICloudId() throws {
        let data = Data(#"{"type":"AssetMetadataV1","ack":"AssetMetadataV1|ack-1","data":{"assetId":"asset-1","key":"mobile-app","value":{"iCloudId":"cloud-1"}}}"#.utf8)
        let result = ImmichAPIService.parseAssetMetadataStream(data)
        XCTAssertEqual(result.iCloudIdUpserts, ["asset-1": "cloud-1"])
    }
}
