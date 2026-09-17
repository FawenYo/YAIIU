import XCTest
@testable import YAIIU

final class SyncStreamParserTests: XCTestCase {
    func testMetadataParserReturnsMobileAppICloudId() throws {
        let data = Data(#"{"type":"AssetMetadataV1","ack":"AssetMetadataV1|ack-1","data":{"assetId":"asset-1","key":"mobile-app","value":{"iCloudId":"cloud-1"}}}"#.utf8)

        let result = ImmichAPIService.parseAssetMetadataStream(data)

        XCTAssertEqual(result.iCloudIdUpserts, ["asset-1": "cloud-1"])
    }

    func testMetadataParserReturnsSourceChecksum() {
        let checksum = "0123456789abcdef0123456789abcdef01234567"
        let data = Data(#"{"type":"AssetMetadataV1","ack":"AssetMetadataV1|ack-1","data":{"assetId":"asset-1","key":"mobile-app","value":{"sourceChecksum":"0123456789ABCDEF0123456789ABCDEF01234567"}}}"#.utf8)

        let result = ImmichAPIService.parseAssetMetadataStream(data)

        XCTAssertEqual(result.sourceChecksumUpserts, ["asset-1": checksum])
        XCTAssertEqual(result.acksByType, ["AssetMetadataV1": "AssetMetadataV1|ack-1"])
    }

    func testMetadataUpdateItemEncodesSourceChecksum() throws {
        // The server replaces the whole mobile-app value on PUT; an update that
        // omits sourceChecksum silently deletes it, so it must be serialized.
        let item = MetadataUpdateItem(
            assetId: "asset-1",
            key: RemoteAssetMetadataItem.mobileAppKey,
            value: MobileAppMetadata(iCloudId: "cloud-1", createdAt: nil, sourceChecksum: "0123456789abcdef0123456789abcdef01234567")
        )

        let data = try JSONEncoder().encode(["items": [item]])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        let value = try XCTUnwrap(items.first?["value"] as? [String: Any])

        XCTAssertEqual(value["sourceChecksum"] as? String, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(value["iCloudId"] as? String, "cloud-1")
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

    func testMetadataParserAcknowledgesWellFormedUnrelatedMetadata() {
        let data = Data("""
        {"type":"AssetMetadataV1","ack":"AssetMetadataV1|ack-1","data":{"assetId":"asset-1","key":"sidecar","value":{}}}
        {"type":"AssetMetadataDeleteV1","ack":"AssetMetadataDeleteV1|ack-1","data":{"assetId":"asset-2","key":"third-party"}}
        """.utf8)

        let result = ImmichAPIService.parseAssetMetadataStream(data)

        XCTAssertTrue(result.iCloudIdUpserts.isEmpty)
        XCTAssertTrue(result.iCloudIdDeletes.isEmpty)
        XCTAssertEqual(result.acksByType, [
            "AssetMetadataV1": "AssetMetadataV1|ack-1",
            "AssetMetadataDeleteV1": "AssetMetadataDeleteV1|ack-1",
        ])
    }

    func testMetadataParserDoesNotAckMalformedUnrelatedUpsert() {
        let data = Data(#"{"type":"AssetMetadataV1","ack":"AssetMetadataV1|ack-1","data":{"assetId":"asset-1","key":"sidecar"}}"#.utf8)

        let result = ImmichAPIService.parseAssetMetadataStream(data)

        XCTAssertTrue(result.acks.isEmpty)
    }

    func testMetadataParserRetainsLatestAckForEveryEntityType() throws {
        let data = Data("""
        {"type":"AssetMetadataV1","ack":"AssetMetadataV1|ack-1","data":{"assetId":"asset-1","key":"mobile-app","value":{"iCloudId":"cloud-1"}}}
        {"type":"AssetMetadataDeleteV1","ack":"AssetMetadataDeleteV1|ack-1","data":{"assetId":"asset-2","key":"mobile-app"}}
        {"type":"AssetMetadataV1","ack":"AssetMetadataV1|ack-2","data":{"assetId":"asset-3","key":"mobile-app","value":{"iCloudId":"cloud-3"}}}
        {"type":"SyncAckV1","ack":"AssetMetadataDeleteV1|backfill-complete","data":{}}
        {"type":"SyncCompleteV1","ack":"completion-ack","data":{}}
        """.utf8)

        let result = ImmichAPIService.parseAssetMetadataStream(data)

        XCTAssertEqual(result.acksByType, [
            "AssetMetadataV1": "AssetMetadataV1|ack-2",
            "AssetMetadataDeleteV1": "AssetMetadataDeleteV1|backfill-complete",
        ])
        XCTAssertEqual(Set(result.acks), Set(result.acksByType.values))
    }

    func testAssetParserReturnsUpsertDeleteAndTypedAcks() throws {
        let data = Data("""
        {"type":"AssetV2","ack":"AssetV2|ack-1","data":{"id":"asset-1","checksum":"checksum-1","originalFileName":"photo.jpg","fileCreatedAt":"2025-01-01T00:00:00Z","type":"IMAGE","ownerId":"owner-1"}}
        {"type":"AssetDeleteV1","ack":"AssetDeleteV1|ack-1","data":{"assetId":"asset-2"}}
        {"type":"SyncAckV1","ack":"AssetV2|backfill-complete","data":{}}
        {"type":"SyncCompleteV1","ack":"completion-ack","data":{}}
        """.utf8)

        let result = ImmichAPIService.parseAssetStream(data)

        XCTAssertEqual(result.assets.count, 2)
        XCTAssertEqual(result.assets[0].id, "asset-1")
        XCTAssertFalse(result.assets[0].isDeleted)
        XCTAssertEqual(result.assets[1].id, "asset-2")
        XCTAssertTrue(result.assets[1].isDeleted)
        XCTAssertEqual(result.acksByType, [
            "AssetV2": "AssetV2|backfill-complete",
            "AssetDeleteV1": "AssetDeleteV1|ack-1",
        ])
        XCTAssertEqual(Set(result.acks), Set(result.acksByType.values))
    }

    func testParsersSkipMalformedLines() throws {
        let data = Data("""
        not-json
        {"type":"AssetV2","ack":"AssetV2|ack-1","data":{"id":"asset-1","checksum":"checksum-1","ownerId":"owner-1"}}
        """.utf8)

        let result = ImmichAPIService.parseAssetStream(data)

        XCTAssertEqual(result.assets.map(\.id), ["asset-1"])
        XCTAssertEqual(result.acksByType, ["AssetV2": "AssetV2|ack-1"])
    }

    func testAssetParserDoesNotAckRejectedEvent() {
        let data = Data(#"{"type":"AssetV2","ack":"AssetV2|ack-1","data":{"id":"asset-1"}}"#.utf8)

        let result = ImmichAPIService.parseAssetStream(data)

        XCTAssertTrue(result.assets.isEmpty)
        XCTAssertTrue(result.acks.isEmpty)
    }

    func testMetadataParserDoesNotAckRejectedEvent() {
        let data = Data(#"{"type":"AssetMetadataV1","ack":"AssetMetadataV1|ack-1","data":{"assetId":"asset-1","key":"mobile-app","value":{}}}"#.utf8)

        let result = ImmichAPIService.parseAssetMetadataStream(data)

        XCTAssertTrue(result.iCloudIdUpserts.isEmpty)
        XCTAssertTrue(result.acks.isEmpty)
    }

    func testParsersSurfaceServerReset() {
        let data = Data(#"{"type":"SyncResetV1","ack":"SyncResetV1|reset-1","data":{}}"#.utf8)

        let metadataResult = ImmichAPIService.parseAssetMetadataStream(data)
        let assetResult = ImmichAPIService.parseAssetStream(data)

        XCTAssertEqual(metadataResult.resetAck, "SyncResetV1|reset-1")
        XCTAssertEqual(assetResult.resetAck, "SyncResetV1|reset-1")
        XCTAssertTrue(metadataResult.acks.isEmpty)
        XCTAssertTrue(assetResult.acks.isEmpty)
    }
}
