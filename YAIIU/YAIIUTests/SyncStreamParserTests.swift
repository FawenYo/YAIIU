import XCTest
@testable import YAIIU

final class SyncStreamParserTests: XCTestCase {
    func testMetadataParserReturnsMobileAppICloudId() throws {
        let data = Data(#"{"type":"AssetMetadataV1","ack":"AssetMetadataV1|ack-1","data":{"assetId":"asset-1","key":"mobile-app","value":{"iCloudId":"cloud-1"}}}"#.utf8)

        let result = ImmichAPIService.parseAssetMetadataStream(data)

        XCTAssertEqual(result.iCloudIdUpserts, ["asset-1": "cloud-1"])
    }

    func testMetadataParserReturnsMobileAppDeletion() throws {
        let data = Data(#"{"type":"AssetMetadataDeleteV1","ack":"AssetMetadataDeleteV1|ack-1","data":{"assetId":"asset-1","key":"mobile-app"}}"#.utf8)

        let result = ImmichAPIService.parseAssetMetadataStream(data)

        XCTAssertEqual(result.iCloudIdDeletes, ["asset-1"])
    }

    func testMetadataParserIgnoresUnrelatedAndEmptyMetadata() throws {
        let data = Data("""
        {"type":"AssetMetadataV1","ack":"AssetMetadataV1|ack-1","data":{"assetId":"asset-1","key":"sidecar","value":{"iCloudId":"cloud-1"}}}
        {"type":"AssetMetadataV1","ack":"AssetMetadataV1|ack-2","data":{"assetId":"asset-2","key":"mobile-app","value":{"iCloudId":""}}}
        {"type":"AssetMetadataDeleteV1","ack":"AssetMetadataDeleteV1|ack-1","data":{"assetId":"asset-3","key":"sidecar"}}
        """.utf8)

        let result = ImmichAPIService.parseAssetMetadataStream(data)

        XCTAssertTrue(result.iCloudIdUpserts.isEmpty)
        XCTAssertTrue(result.iCloudIdDeletes.isEmpty)
    }

    func testMetadataParserRetainsLatestAckForEveryEntityType() throws {
        let data = Data("""
        {"type":"AssetMetadataV1","ack":"AssetMetadataV1|ack-1","data":{"assetId":"asset-1","key":"mobile-app","value":{"iCloudId":"cloud-1"}}}
        {"type":"AssetMetadataDeleteV1","ack":"AssetMetadataDeleteV1|ack-1","data":{"assetId":"asset-2","key":"mobile-app"}}
        {"type":"AssetMetadataV1","ack":"AssetMetadataV1|ack-2","data":{"assetId":"asset-3","key":"mobile-app","value":{"iCloudId":"cloud-3"}}}
        {"type":"SyncAckV1","ackType":"AssetMetadataDeleteV1","ack":"AssetMetadataDeleteV1|ack-2","data":{}}
        {"type":"SyncCompleteV1","ack":"completion-ack","data":{}}
        """.utf8)

        let result = ImmichAPIService.parseAssetMetadataStream(data)

        XCTAssertEqual(result.acksByType, [
            "AssetMetadataV1": "AssetMetadataV1|ack-2",
            "AssetMetadataDeleteV1": "AssetMetadataDeleteV1|ack-2",
        ])
        XCTAssertEqual(Set(result.acks), Set(result.acksByType.values))
    }

    func testAssetParserReturnsUpsertDeleteAndTypedAcks() throws {
        let data = Data("""
        {"type":"AssetV2","ack":"AssetV2|ack-1","data":{"id":"asset-1","checksum":"checksum-1","originalFileName":"photo.jpg","fileCreatedAt":"2025-01-01T00:00:00Z","type":"IMAGE","ownerId":"owner-1"}}
        {"type":"AssetDeleteV1","ack":"AssetDeleteV1|ack-1","data":{"assetId":"asset-2"}}
        {"type":"SyncAckV1","ackType":"AssetV2","ack":"AssetV2|ack-2","data":{}}
        {"type":"SyncCompleteV1","ack":"completion-ack","data":{}}
        """.utf8)

        let result = ImmichAPIService.parseAssetStream(data)

        XCTAssertEqual(result.assets.count, 2)
        XCTAssertEqual(result.assets[0].id, "asset-1")
        XCTAssertFalse(result.assets[0].isDeleted)
        XCTAssertEqual(result.assets[1].id, "asset-2")
        XCTAssertTrue(result.assets[1].isDeleted)
        XCTAssertEqual(result.acksByType, [
            "AssetV2": "AssetV2|ack-2",
            "AssetDeleteV1": "AssetDeleteV1|ack-1",
        ])
        XCTAssertEqual(Set(result.acks), Set(result.acksByType.values))
    }

    func testParsersSkipMalformedLines() throws {
        let data = Data("""
        not-json
        {"type":"AssetV2","ack":"AssetV2|ack-1","data":{"id":"asset-1","checksum":"checksum-1"}}
        """.utf8)

        let result = ImmichAPIService.parseAssetStream(data)

        XCTAssertEqual(result.assets.map(\.id), ["asset-1"])
        XCTAssertEqual(result.acksByType, ["AssetV2": "AssetV2|ack-1"])
    }
}
