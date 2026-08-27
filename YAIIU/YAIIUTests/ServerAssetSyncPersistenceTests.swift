import XCTest
@testable import YAIIU

final class ServerAssetSyncPersistenceTests: XCTestCase {
    func testSyncAcknowledgesOnlyAfterPersistence() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations)
        let store = StoreStub(operations: operations)
        let service = ServerAssetSyncService(apiService: api, dbManager: store)

        let result = await sync(service)

        guard case .success = result else {
            return XCTFail("Expected sync to succeed")
        }
        XCTAssertEqual(operations.values, [
            "clear-cache",
            "save-assets",
            "delete-assets",
            "update-icloud-ids",
            "clear-icloud-ids",
            "save-sync-metadata",
            "send-acks",
            "backfill-immich-ids",
        ])
        XCTAssertEqual(api.sentAcks, ["AssetMetadataV1|metadata-1", "AssetV2|asset-1"])
    }

    func testSyncDoesNotAcknowledgeWhenPersistenceFails() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations)
        let store = StoreStub(operations: operations)
        store.shouldFailAssetSave = true
        let service = ServerAssetSyncService(apiService: api, dbManager: store)

        let result = await sync(service)

        guard case .failure = result else {
            return XCTFail("Expected sync to fail")
        }
        XCTAssertFalse(operations.values.contains("send-acks"))
        XCTAssertTrue(api.sentAcks.isEmpty)
    }

    func testSyncDoesNotAcknowledgeWhenResetCacheClearFails() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations, resetAck: "SyncResetV1|reset-1")
        let store = StoreStub(operations: operations)
        store.shouldFailCacheClear = true
        let service = ServerAssetSyncService(apiService: api, dbManager: store)

        let result = await sync(service)

        guard case .failure = result else {
            return XCTFail("Expected sync to fail")
        }
        XCTAssertEqual(operations.values, ["clear-cache"])
        XCTAssertTrue(api.sentAcks.isEmpty)
    }

    func testFullSyncClearsCacheBeforeSavingSnapshot() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations)
        let store = StoreStub(operations: operations)
        let service = ServerAssetSyncService(apiService: api, dbManager: store)

        let result = await sync(service)

        guard case .success = result else {
            return XCTFail("Expected sync to succeed")
        }
        XCTAssertEqual(Array(operations.values.prefix(2)), ["clear-cache", "save-assets"])
    }

    func testFullSyncDoesNotAcknowledgeWhenCacheClearFails() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations)
        let store = StoreStub(operations: operations)
        store.shouldFailCacheClear = true
        let service = ServerAssetSyncService(apiService: api, dbManager: store)

        let result = await sync(service)

        guard case .failure = result else {
            return XCTFail("Expected sync to fail")
        }
        XCTAssertEqual(operations.values, ["clear-cache"])
        XCTAssertTrue(api.sentAcks.isEmpty)
    }

    private func sync(_ service: ServerAssetSyncService) async -> Result<SyncResult, Error> {
        await withCheckedContinuation { continuation in
            service.syncServerAssets(serverURL: "https://immich.example", apiKey: "token") {
                continuation.resume(returning: $0)
            }
        }
    }
}

private final class OperationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class APIStub: ServerAssetSyncAPI, @unchecked Sendable {
    private let operations: OperationRecorder
    private let resetAck: String?
    private(set) var sentAcks: [String] = []

    init(operations: OperationRecorder, resetAck: String? = nil) {
        self.operations = operations
        self.resetAck = resetAck
    }

    func getCurrentUser(serverURL: String, apiKey: String) async throws -> UserInfo {
        UserInfo(id: "owner-1", email: "user@example.com", name: "User")
    }

    func fetchAssetMetadataStream(serverURL: String, apiKey: String) async throws -> AssetMetadataStreamResult {
        AssetMetadataStreamResult(
            iCloudIdUpserts: resetAck == nil ? ["asset-1": "cloud-1"] : [:],
            iCloudIdDeletes: resetAck == nil ? ["asset-2"] : [],
            acksByType: resetAck == nil ? ["AssetMetadataV1": "AssetMetadataV1|metadata-1"] : [:],
            state: resetAck.map { .reset(ack: $0) } ?? .data
        )
    }

    func fetchAssetStream(serverURL: String, apiKey: String) async throws -> AssetStreamResult {
        AssetStreamResult(
            assets: [
                StreamAsset(
                    id: "asset-1",
                    checksum: Data("checksum".utf8).base64EncodedString(),
                    originalFileName: "photo.jpg",
                    fileCreatedAt: "2026-08-25T00:00:00Z",
                    type: "IMAGE",
                    ownerId: "owner-1",
                    deletedAt: nil
                ),
                .deleted(id: "asset-2"),
            ],
            acksByType: ["AssetV2": "AssetV2|asset-1"],
            state: .data
        )
    }

    func sendSyncAck(acks: [String], serverURL: String, apiKey: String) async throws {
        sentAcks = acks
        operations.append("send-acks")
    }
}

private final class StoreStub: ServerAssetSyncStore, @unchecked Sendable {
    private let operations: OperationRecorder
    var shouldFailAssetSave = false
    var shouldFailCacheClear = false

    init(operations: OperationRecorder) {
        self.operations = operations
    }

    func isAssetOnServer(checksum: String) -> Bool { false }
    func getSyncMetadata() -> SyncMetadata? { nil }
    func clearServerAssetsCache() -> Bool {
        operations.append("clear-cache")
        return !shouldFailCacheClear
    }

    func saveServerAssets(_ assets: [ServerAssetRecord], syncType: String) -> Bool {
        operations.append("save-assets")
        return !shouldFailAssetSave
    }

    func deleteServerAssets(_ immichIds: [String]) -> Bool {
        operations.append("delete-assets")
        return true
    }

    func updateICloudIds(_ iCloudIdsByImmichId: [String: String]) -> Bool {
        operations.append("update-icloud-ids")
        return true
    }

    func clearICloudIds(for immichIds: Set<String>) -> Bool {
        operations.append("clear-icloud-ids")
        return true
    }

    func saveSyncMetadata(
        lastSyncTime: Date,
        syncType: String,
        userId: String,
        totalAssets: Int,
        lastAck: String?
    ) -> Bool {
        operations.append("save-sync-metadata")
        return true
    }

    func getServerAssetsCacheCount() -> Int { 1 }

    func backfillImmichIdsFromServerCache() -> Int {
        operations.append("backfill-immich-ids")
        return 0
    }
}
