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

    private static let mixedAssetStream = """
    not-json
    {"type":"AssetV2","ack":"AssetV2|ack-1","data":{"id":"asset-1","checksum":"checksum-1","originalFileName":"photo.jpg","fileCreatedAt":"2025-01-01T00:00:00Z","type":"IMAGE","ownerId":"owner-1"}}

    {"type":"AssetV2","ack":"AssetV2|ack-2","data":{"id":"asset-3","checksum":"checksum-3","ownerId":"owner-1","deletedAt":"2025-02-01T00:00:00Z"}}\r
    {"type":"AssetDeleteV1","ack":"AssetDeleteV1|ack-1","data":{"assetId":"asset-2"}}
    {"type":"SyncAckV1","ack":"AssetV2|backfill-complete","data":{}}
    {"type":"SyncCompleteV1","ack":"completion-ack","data":{}}
    """

    private static let mixedMetadataStream = """
    {"type":"AssetMetadataV1","ack":"AssetMetadataV1|ack-1","data":{"assetId":"asset-1","key":"mobile-app","value":{"iCloudId":"cloud-1","sourceChecksum":"0123456789ABCDEF0123456789ABCDEF01234567"}}}
    {"type":"AssetMetadataDeleteV1","ack":"AssetMetadataDeleteV1|ack-1","data":{"assetId":"asset-2","key":"mobile-app"}}
    garbage
    {"type":"AssetMetadataV1","ack":"AssetMetadataV1|ack-2","data":{"assetId":"asset-3","key":"sidecar","value":{}}}
    """

    private static func asyncBytes(_ text: String) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for byte in text.utf8 {
                continuation.yield(byte)
            }
            continuation.finish()
        }
    }

    private static func assertSameAssetResult(_ lhs: AssetStreamResult, _ rhs: AssetStreamResult, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.assets.map(\.id), rhs.assets.map(\.id), file: file, line: line)
        XCTAssertEqual(lhs.assets.map(\.checksum), rhs.assets.map(\.checksum), file: file, line: line)
        XCTAssertEqual(lhs.assets.map(\.originalFileName), rhs.assets.map(\.originalFileName), file: file, line: line)
        XCTAssertEqual(lhs.assets.map(\.fileCreatedAt), rhs.assets.map(\.fileCreatedAt), file: file, line: line)
        XCTAssertEqual(lhs.assets.map(\.type), rhs.assets.map(\.type), file: file, line: line)
        XCTAssertEqual(lhs.assets.map(\.ownerId), rhs.assets.map(\.ownerId), file: file, line: line)
        XCTAssertEqual(lhs.assets.map(\.deletedAt), rhs.assets.map(\.deletedAt), file: file, line: line)
        XCTAssertEqual(lhs.assets.map(\.isDeleted), rhs.assets.map(\.isDeleted), file: file, line: line)
        XCTAssertEqual(lhs.acksByType, rhs.acksByType, file: file, line: line)
        XCTAssertEqual(lhs.resetAck, rhs.resetAck, file: file, line: line)
    }

    private static func streamAssets(
        _ text: String,
        batchSize: Int = ImmichAPIService.syncBatchSize
    ) async throws -> AssetStreamResult {
        var assets: [StreamAsset] = []
        let summary = try await ImmichAPIService.parseAssetStream(asyncBytes(text), batchSize: batchSize) {
            assets += $0
        }
        return AssetStreamResult(assets: assets, acksByType: summary.acksByType, state: summary.state)
    }

    private static func streamMetadata(_ text: String) async throws -> AssetMetadataStreamResult {
        var merged = AssetMetadataChanges()
        let summary = try await ImmichAPIService.parseAssetMetadataStream(asyncBytes(text)) { changes in
            merged.iCloudIdUpserts.merge(changes.iCloudIdUpserts) { $1 }
            merged.sourceChecksumUpserts.merge(changes.sourceChecksumUpserts) { $1 }
            merged.iCloudIdDeletes.formUnion(changes.iCloudIdDeletes)
        }
        return AssetMetadataStreamResult(
            iCloudIdUpserts: merged.iCloudIdUpserts,
            sourceChecksumUpserts: merged.sourceChecksumUpserts,
            iCloudIdDeletes: merged.iCloudIdDeletes,
            acksByType: summary.acksByType,
            state: summary.state
        )
    }

    func testStreamingAssetParserEmitsBoundedBatchesInStreamOrder() async throws {
        let text = (1...5).map {
            #"{"type":"AssetV2","ack":"AssetV2|ack-\#($0)","data":{"id":"asset-\#($0)","checksum":"c","ownerId":"owner-1"}}"#
        }.joined(separator: "\n")
        var batches: [[String]] = []

        let summary = try await ImmichAPIService.parseAssetStream(Self.asyncBytes(text), batchSize: 2) {
            batches.append($0.map(\.id))
        }

        XCTAssertEqual(batches, [["asset-1", "asset-2"], ["asset-3", "asset-4"], ["asset-5"]])
        XCTAssertEqual(summary.acksByType, ["AssetV2": "AssetV2|ack-5"])
    }

    func testStreamingMetadataParserEmitsBoundedBatches() async throws {
        let text = (1...3).map {
            #"{"type":"AssetMetadataV1","ack":"AssetMetadataV1|ack-\#($0)","data":{"assetId":"asset-\#($0)","key":"mobile-app","value":{"iCloudId":"cloud-\#($0)"}}}"#
        }.joined(separator: "\n")
        var batches: [[String: String]] = []

        let summary = try await ImmichAPIService.parseAssetMetadataStream(Self.asyncBytes(text), batchSize: 2) {
            batches.append($0.iCloudIdUpserts)
        }

        XCTAssertEqual(batches, [["asset-1": "cloud-1", "asset-2": "cloud-2"], ["asset-3": "cloud-3"]])
        XCTAssertEqual(summary.acksByType, ["AssetMetadataV1": "AssetMetadataV1|ack-3"])
    }

    func testStreamingParserStopsWhenBatchHandlerThrows() async {
        struct Stop: Error {}
        let text = (1...5).map {
            #"{"type":"AssetV2","ack":"AssetV2|ack-\#($0)","data":{"id":"asset-\#($0)","checksum":"c","ownerId":"owner-1"}}"#
        }.joined(separator: "\n")
        var calls = 0

        do {
            _ = try await ImmichAPIService.parseAssetStream(Self.asyncBytes(text), batchSize: 2) { _ in
                calls += 1
                throw Stop()
            }
            XCTFail("Expected handler error to propagate")
        } catch {
            XCTAssertTrue(error is Stop)
        }
        XCTAssertEqual(calls, 1)
    }

    func testStreamingAssetParserMatchesBufferedParser() async throws {
        let expected = ImmichAPIService.parseAssetStream(Data(Self.mixedAssetStream.utf8))
        XCTAssertEqual(expected.assets.map(\.id), ["asset-1", "asset-3", "asset-2"])

        let streamed = try await Self.streamAssets(Self.mixedAssetStream)
        Self.assertSameAssetResult(streamed, expected)
    }

    func testStreamingAssetParserReadsFinalLineWithoutTrailingNewline() async throws {
        let text = #"{"type":"AssetV2","ack":"AssetV2|ack-1","data":{"id":"asset-1","checksum":"c","ownerId":"owner-1"}}"#

        let result = try await Self.streamAssets(text)

        XCTAssertEqual(result.assets.map(\.id), ["asset-1"])
        XCTAssertEqual(result.acksByType, ["AssetV2": "AssetV2|ack-1"])
    }

    func testStreamingParsersSurfaceServerReset() async throws {
        let text = #"{"type":"SyncResetV1","ack":"SyncResetV1|reset-1","data":{}}"# + "\n"

        let assetResult = try await Self.streamAssets(text)
        let metadataResult = try await Self.streamMetadata(text)

        XCTAssertEqual(assetResult.resetAck, "SyncResetV1|reset-1")
        XCTAssertEqual(metadataResult.resetAck, "SyncResetV1|reset-1")
    }

    func testStreamingMetadataParserMatchesBufferedParser() async throws {
        let expected = ImmichAPIService.parseAssetMetadataStream(Data(Self.mixedMetadataStream.utf8))

        let streamed = try await Self.streamMetadata(Self.mixedMetadataStream)
        XCTAssertEqual(streamed.iCloudIdUpserts, expected.iCloudIdUpserts)
        XCTAssertEqual(streamed.sourceChecksumUpserts, expected.sourceChecksumUpserts)
        XCTAssertEqual(streamed.iCloudIdDeletes, expected.iCloudIdDeletes)
        XCTAssertEqual(streamed.acksByType, expected.acksByType)
        XCTAssertEqual(streamed.resetAck, expected.resetAck)
        XCTAssertEqual(expected.iCloudIdUpserts, ["asset-1": "cloud-1"])
        XCTAssertEqual(expected.iCloudIdDeletes, ["asset-2"])
    }
}
