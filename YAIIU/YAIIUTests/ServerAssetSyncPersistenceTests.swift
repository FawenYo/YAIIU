import XCTest
@testable import YAIIU

final class ServerAssetSyncPersistenceTests: XCTestCase {
    private var savedServerURL: String?

    override func setUp() {
        super.setUp()
        // Tests run inside the app host, whose UserDefaults on a logged-in
        // device holds the configured server; a foreign URL would flip the
        // delta-sync path to full and break cache-session assertions.
        savedServerURL = UserDefaults.standard.string(forKey: "immich_server_url")
        UserDefaults.standard.removeObject(forKey: "immich_server_url")
    }

    override func tearDown() {
        if let savedServerURL {
            UserDefaults.standard.set(savedServerURL, forKey: "immich_server_url")
        } else {
            UserDefaults.standard.removeObject(forKey: "immich_server_url")
        }
        super.tearDown()
    }


    func testMetadataOnlyDeltaDoesNotInvalidateChecksums() async {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations, metadataOnly: true)
        let store = StoreStub(operations: operations)
        store.syncMetadata = SyncMetadata(
            lastSyncTime: Date(), lastSyncType: "delta", userId: "owner-1",
            serverURL: "https://immich.example", totalAssets: 1,
            lastAck: "AssetV2|previous"
        )
        store.existingAsset = ServerAssetRecord(
            immichId: "asset-1", checksum: "stable-checksum",
            sourceChecksum: "original-checksum", iCloudId: "old-cloud",
            ownerId: "owner-1"
        )
        let result = await sync(ServerAssetSyncService(apiService: api, dbManager: store))
        guard case .success = result else { return XCTFail("Expected successful delta") }
        XCTAssertFalse(store.invalidatedFullReset ?? true)
        XCTAssertTrue(store.invalidatedChecksums.isEmpty)
        XCTAssertTrue(operations.values.contains("update-icloud-ids"))
    }

    func testChangedSourceChecksumInvalidatesOldAndNewValues() async {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations, sourceChecksum: "new-source", metadataOnly: true)
        let store = StoreStub(operations: operations)
        store.syncMetadata = SyncMetadata(
            lastSyncTime: Date(), lastSyncType: "delta", userId: "owner-1",
            serverURL: "https://immich.example", totalAssets: 1,
            lastAck: "AssetV2|previous"
        )
        store.existingAsset = ServerAssetRecord(
            immichId: "asset-1", checksum: "server-checksum",
            sourceChecksum: "old-source", ownerId: "owner-1"
        )
        let result = await sync(ServerAssetSyncService(apiService: api, dbManager: store))
        guard case .success = result else { return XCTFail("Expected successful delta") }
        XCTAssertEqual(store.invalidatedChecksums, [
            "old-source", "new-source", "server-checksum"
        ])
    }

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
            "invalidate-hash-checks",
            "clear-cache",
            "save-assets",
            "delete-assets",
            "update-icloud-ids",
            "clear-icloud-ids",
            "update-source-checksums",
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
        store.syncMetadata = Self.deltaMetadata
        store.shouldFailCacheClear = true
        let service = ServerAssetSyncService(apiService: api, dbManager: store)

        let result = await sync(service)

        guard case .failure = result else {
            return XCTFail("Expected sync to fail")
        }
        XCTAssertEqual(operations.values, [
            "invalidate-hash-checks",
            "save-assets",
            "delete-assets",
            "invalidate-hash-checks",
            "clear-cache",
        ])
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
        XCTAssertEqual(Array(operations.values.prefix(3)), ["invalidate-hash-checks", "clear-cache", "save-assets"])
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
        XCTAssertEqual(operations.values, ["invalidate-hash-checks", "clear-cache"])
        XCTAssertTrue(api.sentAcks.isEmpty)
    }

    func testSyncPrefersSourceChecksumForRewrittenUploads() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations, sourceChecksum: "original-checksum")
        let store = StoreStub(operations: operations)
        let service = ServerAssetSyncService(apiService: api, dbManager: store)

        let result = await sync(service)

        guard case .success = result else {
            return XCTFail("Expected sync to succeed")
        }
        XCTAssertNil(store.savedAssets.first?.sourceChecksum)
        XCTAssertEqual(store.updatedSourceChecksums, ["asset-1": "original-checksum"])
        XCTAssertLessThan(
            try XCTUnwrap(operations.values.firstIndex(of: "save-assets")),
            try XCTUnwrap(operations.values.firstIndex(of: "update-source-checksums"))
        )
    }
    func testDeltaSyncPreservesExistingSourceChecksumWithoutMetadataEvent() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations)
        let store = StoreStub(operations: operations)
        store.syncMetadata = SyncMetadata(
            lastSyncTime: Date(),
            lastSyncType: "delta",
            userId: "owner-1",
            serverURL: "https://immich.example",
            totalAssets: 1,
            lastAck: "AssetV2|previous"
        )
        store.existingAsset = ServerAssetRecord(
            immichId: "asset-1",
            checksum: "server-checksum",
            sourceChecksum: "original-checksum"
        )
        let service = ServerAssetSyncService(apiService: api, dbManager: store)

        let result = await sync(service)

        guard case .success = result else {
            return XCTFail("Expected sync to succeed")
        }
        XCTAssertEqual(store.savedAssets.first?.sourceChecksum, "original-checksum")
        XCTAssertEqual(store.invalidatedFullReset, false)
        XCTAssertTrue(store.invalidatedChecksums.contains("original-checksum"))
        XCTAssertTrue(store.invalidatedChecksums.contains("server-checksum"))
    }

    func testFailedInvalidationPreventsAck() async {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations)
        let store = StoreStub(operations: operations)
        store.shouldFailInvalidation = true
        let service = ServerAssetSyncService(apiService: api, dbManager: store)

        guard case .failure = await sync(service) else {
            return XCTFail("Expected invalidation failure")
        }
        XCTAssertFalse(operations.values.contains("send-acks"))
    }

    private static let deltaMetadata = SyncMetadata(
        lastSyncTime: Date(), lastSyncType: "delta", userId: "owner-1",
        serverURL: "https://immich.example", totalAssets: 1,
        lastAck: "AssetV2|previous"
    )

    private static func streamAsset(_ id: String) -> StreamAsset {
        StreamAsset(
            id: id,
            checksum: Data(id.utf8).base64EncodedString(),
            originalFileName: "\(id).jpg",
            fileCreatedAt: nil,
            type: "IMAGE",
            ownerId: "owner-1",
            deletedAt: nil
        )
    }

    func testAssetBatchesPersistWhileStreaming() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations)
        api.assetBatches = [[Self.streamAsset("a")], [Self.streamAsset("b")], [Self.streamAsset("c")]]
        let store = StoreStub(operations: operations)

        let result = await sync(ServerAssetSyncService(apiService: api, dbManager: store))

        guard case .success(let summary) = result else { return XCTFail("Expected sync to succeed") }
        XCTAssertEqual(api.operationsAtAssetStreamEnd.filter { $0 == "save-assets" }.count, 3)
        XCTAssertFalse(api.operationsAtAssetStreamEnd.contains("send-acks"))
        XCTAssertEqual(store.savedAssetBatches.map { $0.map(\.immichId) }, [["a"], ["b"], ["c"]])
        XCTAssertEqual(summary.upsertedCount, 3)
    }

    func testDeltaInvalidatesEachBatchBeforeSavingIt() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations, metadataResets: 0)
        api.assetBatches = [[Self.streamAsset("a")], [Self.streamAsset("b")]]
        let store = StoreStub(operations: operations)
        store.syncMetadata = Self.deltaMetadata

        let result = await sync(ServerAssetSyncService(apiService: api, dbManager: store))

        guard case .success = result else { return XCTFail("Expected sync to succeed") }
        XCTAssertEqual(Array(operations.values.prefix(4)), [
            "invalidate-hash-checks", "save-assets",
            "invalidate-hash-checks", "save-assets",
        ])
    }

    func testFailureInLaterBatchDoesNotAdvanceCheckpoint() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations)
        api.assetBatches = [[Self.streamAsset("a")], [Self.streamAsset("b")], [Self.streamAsset("c")]]
        let store = StoreStub(operations: operations)
        store.syncMetadata = Self.deltaMetadata
        store.failAssetSaveOnCall = 2

        let result = await sync(ServerAssetSyncService(apiService: api, dbManager: store))

        guard case .failure = result else { return XCTFail("Expected sync to fail") }
        XCTAssertEqual(store.savedAssetBatches.count, 2)
        XCTAssertFalse(operations.values.contains("save-sync-metadata"))
        XCTAssertTrue(api.ackHistory.isEmpty)
    }

    func testServerResetAfterAssetBatchesClearsCacheAndRetriesFullSync() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations, resetAck: "SyncResetV1|reset-1", metadataResets: 1)
        let store = StoreStub(operations: operations)
        store.syncMetadata = Self.deltaMetadata

        let result = await sync(ServerAssetSyncService(apiService: api, dbManager: store))

        guard case .success(let summary) = result else { return XCTFail("Expected sync to succeed") }
        XCTAssertEqual(summary.syncType, "full")
        XCTAssertEqual(api.ackHistory, [
            ["SyncResetV1|reset-1"],
            ["AssetMetadataV1|metadata-1", "AssetV2|asset-1"],
        ])
        let resetClear = try XCTUnwrap(operations.values.firstIndex(of: "clear-cache"))
        XCTAssertLessThan(try XCTUnwrap(operations.values.firstIndex(of: "save-assets")), resetClear)
        XCTAssertEqual(store.savedLastAck, "AssetV2|asset-1")
    }

    func testRepeatedServerResetFails() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations, resetAck: "SyncResetV1|reset-1")
        let store = StoreStub(operations: operations)

        let result = await sync(ServerAssetSyncService(apiService: api, dbManager: store))

        guard case .failure(let error) = result,
              case SyncError.repeatedServerReset = error
        else { return XCTFail("Expected repeated reset failure") }
        XCTAssertEqual(api.ackHistory, [["SyncResetV1|reset-1"]])
        XCTAssertFalse(operations.values.contains("save-sync-metadata"))
    }

    func testBatchedFullSyncWritesExpectedRowsToDatabase() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaiiu-sync-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
            }
        }
        let connection = SQLiteConnection.testing(databasePath: databaseURL.path)
        connection.ensureInitialized()
        let store = RepositoryStore(connection: connection)
        XCTAssertTrue(store.saveServerAssets([ServerAssetRecord(immichId: "stale", checksum: "stale")], syncType: "full"))

        let operations = OperationRecorder()
        let api = APIStub(operations: operations, sourceChecksum: "0123456789abcdef0123456789abcdef01234567")
        api.assetBatches = [
            [Self.streamAsset("asset-1"), Self.streamAsset("asset-2")],
            [Self.streamAsset("asset-3"), .deleted(id: "asset-3")],
        ]

        let result = await sync(ServerAssetSyncService(apiService: api, dbManager: store))

        guard case .success(let summary) = result else { return XCTFail("Expected sync to succeed") }
        XCTAssertEqual(summary.totalAssets, 2)
        XCTAssertNil(store.getServerAssetByImmichId("stale"))
        XCTAssertNil(store.getServerAssetByImmichId("asset-3"))
        let first = try XCTUnwrap(store.getServerAssetByImmichId("asset-1"))
        XCTAssertEqual(first.checksum, ServerAssetSyncService.convertBase64ToHex(Data("asset-1".utf8).base64EncodedString()))
        XCTAssertEqual(first.iCloudId, "cloud-1")
        XCTAssertEqual(first.sourceChecksum, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(first.originalFilename, "asset-1.jpg")
        XCTAssertEqual(first.ownerId, "owner-1")
        XCTAssertNil(try XCTUnwrap(store.getServerAssetByImmichId("asset-2")).iCloudId)
        XCTAssertEqual(store.getSyncMetadata()?.lastAck, "AssetV2|asset-1")
    }

    func testServerResetFromAssetStreamInvalidatesClearsAndRetries() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations, metadataResets: 0)
        api.assetResetAck = "SyncResetV1|reset-assets"
        let store = StoreStub(operations: operations)
        store.syncMetadata = Self.deltaMetadata

        let result = await sync(ServerAssetSyncService(apiService: api, dbManager: store))

        guard case .success(let summary) = result else { return XCTFail("Expected sync to succeed") }
        XCTAssertEqual(summary.syncType, "full")
        XCTAssertEqual(Array(operations.values.prefix(3)), ["invalidate-hash-checks", "clear-cache", "send-acks"])
        XCTAssertEqual(api.ackHistory.first, ["SyncResetV1|reset-assets"])
    }

    func testDeltaInvalidatesStagedSourceChecksumBeforeMergingIt() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations, metadataResets: 0)
        let store = StoreStub(operations: operations)
        store.syncMetadata = Self.deltaMetadata
        store.pendingSources = ["staged-source"]

        let result = await sync(ServerAssetSyncService(apiService: api, dbManager: store))

        guard case .success = result else { return XCTFail("Expected sync to succeed") }
        XCTAssertTrue(store.invalidatedChecksums.contains("staged-source"))
        XCTAssertEqual(Array(operations.values.prefix(2)), ["invalidate-hash-checks", "save-assets"])
    }

    func testMetadataForAssetMissedByAssetStreamIsAppliedOnLaterSync() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaiiu-sync-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
            }
        }
        let connection = SQLiteConnection.testing(databasePath: databaseURL.path)
        connection.ensureInitialized()
        let store = RepositoryStore(connection: connection)
        let source = "0123456789abcdef0123456789abcdef01234567"

        // The asset is uploaded after the asset stream was read but before the
        // metadata stream: its metadata arrives first and finds no row.
        let operations = OperationRecorder()
        let api = APIStub(operations: operations, metadataResets: 0)
        api.assetBatches = [[Self.streamAsset("asset-1")]]
        var raced = AssetMetadataChanges()
        raced.iCloudIdUpserts = ["asset-late": "cloud-late"]
        raced.sourceChecksumUpserts = ["asset-late": source]
        api.metadataResponses = [raced, AssetMetadataChanges()]
        guard case .success = await sync(ServerAssetSyncService(apiService: api, dbManager: store)) else {
            return XCTFail("Expected first sync to succeed")
        }
        XCTAssertNil(store.getServerAssetByImmichId("asset-late"))
        XCTAssertEqual(store.pendingSourceChecksums(for: ["asset-late"]), [source])

        api.assetBatches = [[Self.streamAsset("asset-late")]]
        guard case .success(let summary) = await sync(ServerAssetSyncService(apiService: api, dbManager: store)) else {
            return XCTFail("Expected delta sync to succeed")
        }

        XCTAssertEqual(summary.syncType, "delta")
        let late = try XCTUnwrap(store.getServerAssetByImmichId("asset-late"))
        XCTAssertEqual(late.iCloudId, "cloud-late")
        XCTAssertEqual(late.sourceChecksum, source)
        XCTAssertTrue(store.pendingSourceChecksums(for: ["asset-late"]).isEmpty)
    }

    func testTrashedThenRestoredAssetKeepsMetadataAcrossDeltas() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaiiu-sync-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
            }
        }
        let connection = SQLiteConnection.testing(databasePath: databaseURL.path)
        connection.ensureInitialized()
        let store = RepositoryStore(connection: connection)
        let source = "0123456789abcdef0123456789abcdef01234567"
        let operations = OperationRecorder()
        let api = APIStub(operations: operations, metadataResets: 0)
        api.assetBatches = [[Self.streamAsset("asset-1")]]
        var metadata = AssetMetadataChanges()
        metadata.iCloudIdUpserts = ["asset-1": "cloud-1"]
        metadata.sourceChecksumUpserts = ["asset-1": source]
        api.metadataResponses = [metadata, AssetMetadataChanges(), AssetMetadataChanges()]
        let service = ServerAssetSyncService(apiService: api, dbManager: store)
        guard case .success = await sync(service) else { return XCTFail("Expected full sync to succeed") }

        let trashed = StreamAsset(
            id: "asset-1",
            checksum: Data("asset-1".utf8).base64EncodedString(),
            originalFileName: "asset-1.jpg",
            fileCreatedAt: nil,
            type: "IMAGE",
            ownerId: "owner-1",
            deletedAt: "2026-11-01T00:00:00Z"
        )
        api.assetBatches = [[trashed]]
        guard case .success = await sync(service) else { return XCTFail("Expected trash delta to succeed") }
        XCTAssertNil(store.getServerAssetByImmichId("asset-1"))

        api.assetBatches = [[Self.streamAsset("asset-1")]]
        guard case .success = await sync(service) else { return XCTFail("Expected restore delta to succeed") }

        let restored = try XCTUnwrap(store.getServerAssetByImmichId("asset-1"))
        XCTAssertEqual(restored.iCloudId, "cloud-1")
        XCTAssertEqual(restored.sourceChecksum, source)
    }

    func testTrashEventRetainsMetadataAndPermanentDeleteDoesNot() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations, metadataResets: 0)
        let trashed = StreamAsset(
            id: "asset-3", checksum: "", originalFileName: nil, fileCreatedAt: nil,
            type: nil, ownerId: "owner-1", deletedAt: "2026-11-01T00:00:00Z"
        )
        api.assetBatches = [[trashed, .deleted(id: "asset-2")]]
        let store = StoreStub(operations: operations)
        store.syncMetadata = Self.deltaMetadata

        let result = await sync(ServerAssetSyncService(apiService: api, dbManager: store))

        guard case .success(let summary) = result else { return XCTFail("Expected sync to succeed") }
        XCTAssertTrue(operations.values.contains("trash-assets"))
        XCTAssertTrue(operations.values.contains("delete-assets"))
        XCTAssertEqual(summary.deletedCount, 2)
    }

    private func sync(_ service: ServerAssetSyncService) async -> Result<SyncResult, Error> {
        await withCheckedContinuation { continuation in
            service.syncServerAssets(serverURL: "https://immich.example", apiKey: "token") {
                continuation.resume(returning: $0)
            }
        }
    }

    func testBase64ChecksumConvertsToLowercaseHex() {
        let bytes: [UInt8] = [0x00, 0x01, 0x0f, 0x10, 0x7f, 0x80, 0xab, 0xcd, 0xef, 0xff]
            + (0..<10).map { UInt8($0 * 25) }
        let expected = bytes.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(
            ServerAssetSyncService.convertBase64ToHex(Data(bytes).base64EncodedString()),
            expected
        )
        XCTAssertEqual(ServerAssetSyncService.convertBase64ToHex(""), "")
        XCTAssertNil(ServerAssetSyncService.convertBase64ToHex("not base64!"))
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
    private var metadataResetsRemaining: Int
    private let sourceChecksum: String?
    private let metadataOnly: Bool
    var assetBatches: [[StreamAsset]] = [[
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
    ]]
    var assetResetAck: String?
    var metadataResponses: [AssetMetadataChanges] = []
    private(set) var sentAcks: [String] = []
    private(set) var ackHistory: [[String]] = []
    private(set) var operationsAtAssetStreamEnd: [String] = []

    init(
        operations: OperationRecorder,
        resetAck: String? = nil,
        metadataResets: Int = .max,
        sourceChecksum: String? = nil,
        metadataOnly: Bool = false
    ) {
        self.operations = operations
        self.resetAck = resetAck
        self.metadataResetsRemaining = metadataResets
        self.sourceChecksum = sourceChecksum
        self.metadataOnly = metadataOnly
    }

    func getCurrentUser(serverURL: String, apiKey: String) async throws -> UserInfo {
        UserInfo(id: "owner-1", email: "user@example.com", name: "User")
    }

    func streamAssets(
        serverURL: String,
        apiKey: String,
        onBatch: ([StreamAsset]) throws -> Void
    ) async throws -> SyncStreamSummary {
        if let ack = assetResetAck {
            assetResetAck = nil
            return SyncStreamSummary(acksByType: [:], state: .reset(ack: ack))
        }
        if !metadataOnly {
            for batch in assetBatches {
                try onBatch(batch)
            }
        }
        operationsAtAssetStreamEnd = operations.values
        return SyncStreamSummary(
            acksByType: metadataOnly ? [:] : ["AssetV2": "AssetV2|asset-1"],
            state: .data
        )
    }

    func streamAssetMetadata(
        serverURL: String,
        apiKey: String,
        onBatch: (AssetMetadataChanges) throws -> Void
    ) async throws -> SyncStreamSummary {
        if let resetAck, metadataResetsRemaining > 0 {
            metadataResetsRemaining -= 1
            return SyncStreamSummary(acksByType: [:], state: .reset(ack: resetAck))
        }
        if !metadataResponses.isEmpty {
            try onBatch(metadataResponses.removeFirst())
            return SyncStreamSummary(acksByType: ["AssetMetadataV1": "AssetMetadataV1|metadata-2"], state: .data)
        }
        var changes = AssetMetadataChanges()
        changes.iCloudIdUpserts = ["asset-1": "cloud-1"]
        changes.iCloudIdDeletes = ["asset-2"]
        if let sourceChecksum {
            changes.sourceChecksumUpserts = ["asset-1": sourceChecksum]
        }
        try onBatch(changes)
        return SyncStreamSummary(
            acksByType: ["AssetMetadataV1": "AssetMetadataV1|metadata-1"],
            state: .data
        )
    }

    func sendSyncAck(acks: [String], serverURL: String, apiKey: String) async throws {
        sentAcks = acks
        ackHistory.append(acks)
        operations.append("send-acks")
    }
}

private final class StoreStub: ServerAssetSyncStore, @unchecked Sendable {
    private let operations: OperationRecorder
    var shouldFailAssetSave = false
    private(set) var savedAssets: [ServerAssetRecord] = []
    var shouldFailCacheClear = false
    var shouldFailInvalidation = false
    var invalidatedFullReset: Bool?
    var invalidatedChecksums: Set<String> = []
    var syncMetadata: SyncMetadata?
    var existingAsset: ServerAssetRecord?
    private(set) var savedLastAck: String?

    init(operations: OperationRecorder) {
        self.operations = operations
    }

    func invalidateHashChecksForServerChanges(checksums: [String], fullReset: Bool) -> Bool {
        invalidatedFullReset = fullReset
        invalidatedChecksums.formUnion(checksums)
        operations.append("invalidate-hash-checks")
        return !shouldFailInvalidation
    }

    func isAssetOnServer(checksum: String) -> Bool { false }
    func getServerAssetByImmichId(_ immichId: String) -> ServerAssetRecord? {
        existingAsset?.immichId == immichId ? existingAsset : nil
    }
    func getSyncMetadata() -> SyncMetadata? { syncMetadata }
    func clearServerAssetsCache() -> Bool {
        operations.append("clear-cache")
        guard !shouldFailCacheClear else { return false }
        syncMetadata = nil
        return true
    }

    var failAssetSaveOnCall: Int?
    private(set) var savedAssetBatches: [[ServerAssetRecord]] = []
    func saveServerAssets(_ assets: [ServerAssetRecord], syncType: String) -> Bool {
        savedAssets = assets
        savedAssetBatches.append(assets)
        operations.append("save-assets")
        return !shouldFailAssetSave && failAssetSaveOnCall != savedAssetBatches.count
    }

    var pendingSources: [String] = []
    func pendingSourceChecksums(for immichIds: [String]) -> [String] { pendingSources }

    func deleteServerAssets(_ immichIds: [String], retainingMetadata: Bool) -> Bool {
        operations.append(retainingMetadata ? "trash-assets" : "delete-assets")
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

    private(set) var updatedSourceChecksums: [String: String] = [:]
    func updateSourceChecksums(_ sourceChecksumsByImmichId: [String: String]) -> Bool {
        updatedSourceChecksums = sourceChecksumsByImmichId
        operations.append("update-source-checksums")
        return true
    }

    func saveSyncMetadata(
        lastSyncTime: Date,
        syncType: String,
        userId: String,
        serverURL: String,
        totalAssets: Int,
        lastAck: String?
    ) -> Bool {
        operations.append("save-sync-metadata")
        savedLastAck = lastAck
        return true
    }

    func getServerAssetsCacheCount() -> Int { 1 }

    func backfillImmichIdsFromServerCache() -> Int {
        operations.append("backfill-immich-ids")
        return 0
    }
}

private final class RepositoryStore: ServerAssetSyncStore, @unchecked Sendable {
    private let assets: ServerAssetRepository
    private let hashes: HashCacheRepository

    init(connection: SQLiteConnection) {
        assets = ServerAssetRepository(connection: connection)
        hashes = HashCacheRepository(connection: connection)
    }

    func invalidateHashChecksForServerChanges(checksums: [String], fullReset: Bool) -> Bool {
        hashes.invalidateHashChecksForServerChanges(checksums: checksums, fullReset: fullReset)
    }
    func isAssetOnServer(checksum: String) -> Bool { assets.isAssetOnServer(checksum: checksum) }
    func getServerAssetByImmichId(_ immichId: String) -> ServerAssetRecord? { assets.getServerAssetByImmichId(immichId) }
    func getSyncMetadata() -> SyncMetadata? { assets.getSyncMetadata() }
    func clearServerAssetsCache() -> Bool { assets.clearServerAssetsCache() }
    func saveServerAssets(_ records: [ServerAssetRecord], syncType: String) -> Bool {
        assets.saveServerAssets(records, syncType: syncType)
    }
    func deleteServerAssets(_ immichIds: [String], retainingMetadata: Bool) -> Bool {
        assets.deleteServerAssets(immichIds, retainingMetadata: retainingMetadata)
    }
    func pendingSourceChecksums(for immichIds: [String]) -> [String] { assets.pendingSourceChecksums(for: immichIds) }
    func updateICloudIds(_ iCloudIdsByImmichId: [String: String]) -> Bool { assets.updateICloudIds(iCloudIdsByImmichId) }
    func clearICloudIds(for immichIds: Set<String>) -> Bool { assets.clearICloudIds(for: immichIds) }
    func updateSourceChecksums(_ sourceChecksumsByImmichId: [String: String]) -> Bool {
        assets.updateSourceChecksums(sourceChecksumsByImmichId)
    }
    func saveSyncMetadata(lastSyncTime: Date, syncType: String, userId: String, serverURL: String, totalAssets: Int, lastAck: String?) -> Bool {
        assets.saveSyncMetadata(
            lastSyncTime: lastSyncTime, syncType: syncType, userId: userId,
            serverURL: serverURL, totalAssets: totalAssets, lastAck: lastAck
        )
    }
    func getServerAssetsCacheCount() -> Int { assets.getServerAssetsCacheCount() }
    func backfillImmichIdsFromServerCache() -> Int { 0 }
}
