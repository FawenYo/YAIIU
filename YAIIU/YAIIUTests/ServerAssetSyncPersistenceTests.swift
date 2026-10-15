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
            "begin-rebuild",
            "clear-cache",
            "save-assets",
            "delete-assets",
            "update-icloud-ids",
            "clear-icloud-ids",
            "update-source-checksums",
            "backfill-immich-ids",
            "finalize-full-snapshot",
            "save-sync-metadata",
            "send-acks",
            "end-rebuild",
        ])
        XCTAssertEqual(api.sentAcks, ["AssetMetadataV1|metadata-1", "AssetV2|asset-1"])
    }

    func testOldSyncCannotPersistAfterDestinationInvalidation() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations)
        let store = StoreStub(operations: operations)
        let gate = SyncTestGate()
        let reachedMetadata = expectation(description: "Old sync reached metadata fetch")
        api.beforeMetadataFetch = {
            reachedMetadata.fulfill()
            await gate.wait()
        }
        let service = ServerAssetSyncService(apiService: api, dbManager: store)
        let ongoing = Task { await sync(service) }
        await fulfillment(of: [reachedMetadata], timeout: 5)

        // Matches SettingsManager.login/updateServerURL/logout: invalidate
        // before the new destination resets SQLite.
        ServerAssetSyncService.invalidateInFlightSync()
        await gate.release()
        let result = await ongoing.value
        guard case .failure = result else {
            return XCTFail("Old sync must fail after destination change")
        }
        XCTAssertFalse(operations.values.contains("clear-cache"))
        XCTAssertFalse(operations.values.contains("save-assets"))
        XCTAssertFalse(operations.values.contains("save-sync-metadata"))
        XCTAssertFalse(operations.values.contains("send-acks"))
        XCTAssertTrue(api.sentAcks.isEmpty)
    }

    func testMetadataBackfillDestinationScopeRejectsStaleAccountOrRevision() {
        let oldRevision = ServerAssetSyncService.capturedDestinationRevision()
        let scope = MetadataBackfillDestinationScope(
            revision: oldRevision, identity: "immich-account-A"
        )
        XCTAssertTrue(scope.isCurrent(currentIdentity: "immich-account-A"))
        XCTAssertFalse(scope.isCurrent(currentIdentity: "immich-account-B"))
        XCTAssertFalse(scope.isCurrent(currentIdentity: nil))

        // Changing the actual configured server/credential invalidates
        // previously captured candidate lookup and metadata upload batches.
        ServerAssetSyncService.invalidateInFlightSync()
        XCTAssertFalse(scope.isCurrent(currentIdentity: "immich-account-A"))

        let next = MetadataBackfillDestinationScope(
            revision: ServerAssetSyncService.capturedDestinationRevision(),
            identity: "immich-account-B"
        )
        XCTAssertTrue(next.isCurrent(currentIdentity: "immich-account-B"))
        XCTAssertFalse(next.isCurrent(currentIdentity: "immich-account-A"))
    }

    func testNewDestinationSyncCanSupersedeOldBlockedNetworkSync() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations)
        let store = StoreStub(operations: operations)
        let gate = SyncTestGate()
        let oldFetchStarted = expectation(description: "Old destination is waiting for network")
        api.beforeMetadataFetch = {
            if await gate.claimFirst() {
                oldFetchStarted.fulfill()
                await gate.wait()
            }
        }
        let service = ServerAssetSyncService(apiService: api, dbManager: store)
        let old = Task { await sync(service) }
        await fulfillment(of: [oldFetchStarted], timeout: 5)

        // Destination switch invalidates the old task while its network
        // continuation remains suspended. A new sync must NOT return
        // syncInProgress, and the old task must NOT write after it resumes.
        ServerAssetSyncService.invalidateInFlightSync()
        let fresh = await sync(service)
        guard case .success = fresh else {
            await gate.release()
            _ = await old.value
            return XCTFail("New destination must supersede an old in-flight sync")
        }
        XCTAssertEqual(operations.values.filter { $0 == "save-assets" }.count, 1)

        await gate.release()
        let oldResult = await old.value
        guard case .failure = oldResult else {
            return XCTFail("Invalidated old sync unexpectedly succeeded")
        }
        XCTAssertEqual(operations.values.filter { $0 == "save-assets" }.count, 1)
        XCTAssertEqual(operations.values.filter { $0 == "send-acks" }.count, 1)

        // An old generation's defer cannot clear the current sync slot.
        let subsequent = await sync(service)
        guard case .success = subsequent else {
            return XCTFail("New destination became stuck after old sync completed")
        }
    }

    func testDuplicateSyncForSameDestinationStillReturnsInProgress() async throws {
        let api = APIStub(operations: OperationRecorder())
        let gate = SyncTestGate()
        let firstFetchStarted = expectation(description: "First sync is in progress")
        api.beforeMetadataFetch = {
            if await gate.claimFirst() {
                firstFetchStarted.fulfill()
                await gate.wait()
            }
        }
        let store = StoreStub(operations: OperationRecorder())
        let service = ServerAssetSyncService(apiService: api, dbManager: store)
        let first = Task { await sync(service) }
        await fulfillment(of: [firstFetchStarted], timeout: 5)
        let duplicate = await sync(service)
        guard case .failure(let error) = duplicate,
              let syncError = error as? SyncError,
              case .syncInProgress = syncError else {
            await gate.release()
            _ = await first.value
            return XCTFail("Duplicate current-destination sync must be rejected")
        }
        await gate.release()
        _ = await first.value
    }

    func testInitialFullSyncGuardsServerCatalogDuringNetworkFetch() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations)
        let store = StoreStub(operations: operations)
        let gate = SyncTestGate()
        let fetching = expectation(description: "Metadata fetch has started")
        api.beforeMetadataFetch = {
            fetching.fulfill()
            await gate.wait()
        }
        let service = ServerAssetSyncService(apiService: api, dbManager: store)
        let task = Task { await sync(service) }
        await fulfillment(of: [fetching], timeout: 5)

        // While no server list has arrived, the extension-facing gate must
        // already be active. No SQLite catalog mutations or ACKs can happen
        // before remote data is available.
        XCTAssertTrue(store.rebuildBarrierActive)
        XCTAssertEqual(operations.values, ["begin-rebuild"])

        await gate.release()
        let result = await task.value
        guard case .success = result else {
            return XCTFail("Full sync should succeed once metadata fetch resumes")
        }
        XCTAssertFalse(store.rebuildBarrierActive)
        XCTAssertEqual(operations.values.filter { $0 == "begin-rebuild" }.count, 1)
        XCTAssertTrue(operations.values.contains("finalize-full-snapshot"))
        XCTAssertTrue(operations.values.contains("end-rebuild"))
    }

    func testRebuildBarrierReleasedAfterFailedFullSnapshot() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations)
        let store = StoreStub(operations: operations)
        store.shouldFailFullSnapshotFinalization = true
        let service = ServerAssetSyncService(apiService: api, dbManager: store)
        let result = await sync(service)
        guard case .failure = result else { return XCTFail("Expected sync failure") }
        XCTAssertFalse(store.rebuildBarrierActive)
        XCTAssertTrue(operations.values.contains("begin-rebuild"))
        XCTAssertTrue(operations.values.contains("end-rebuild"))
        XCTAssertFalse(operations.values.contains("send-acks"))
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
        XCTAssertEqual(operations.values, ["begin-rebuild", "clear-cache", "end-rebuild"])
        XCTAssertTrue(api.sentAcks.isEmpty)
    }

    func testFailedSnapshotReconciliationDoesNotAdvanceCheckpointOrAck() async throws {
        let operations = OperationRecorder()
        let api = APIStub(operations: operations)
        let store = StoreStub(operations: operations)
        store.shouldFailFullSnapshotFinalization = true
        let service = ServerAssetSyncService(apiService: api, dbManager: store)

        let result = await sync(service)
        guard case .failure = result else {
            return XCTFail("Expected full-sync finalization to fail")
        }
        XCTAssertTrue(operations.values.contains("finalize-full-snapshot"))
        XCTAssertFalse(operations.values.contains("save-sync-metadata"))
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
        XCTAssertEqual(Array(operations.values.prefix(3)), ["begin-rebuild", "clear-cache", "save-assets"])
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
        XCTAssertEqual(operations.values, ["begin-rebuild", "clear-cache", "end-rebuild"])
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
        XCTAssertEqual(store.savedAssets.first?.sourceChecksum, "original-checksum")
        XCTAssertEqual(store.updatedSourceChecksums, ["asset-1": "original-checksum"])
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
    }

    private func sync(_ service: ServerAssetSyncService) async -> Result<SyncResult, Error> {
        await withCheckedContinuation { continuation in
            service.syncServerAssets(serverURL: "https://immich.example", apiKey: "token") {
                continuation.resume(returning: $0)
            }
        }
    }
}

private actor SyncTestGate {
    private var firstClaimed = false
    private var released = false

    func claimFirst() -> Bool {
        guard !firstClaimed else { return false }
        firstClaimed = true
        return true
    }
    private var waiting: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiting = continuation
        }
    }

    func release() {
        released = true
        waiting?.resume()
        waiting = nil
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
    private let sourceChecksum: String?
    private(set) var sentAcks: [String] = []
    var beforeMetadataFetch: (() async -> Void)?

    init(operations: OperationRecorder, resetAck: String? = nil, sourceChecksum: String? = nil) {
        self.operations = operations
        self.resetAck = resetAck
        self.sourceChecksum = sourceChecksum
    }

    func getCurrentUser(serverURL: String, apiKey: String) async throws -> UserInfo {
        UserInfo(id: "owner-1", email: "user@example.com", name: "User")
    }

    func fetchAssetMetadataStream(serverURL: String, apiKey: String) async throws -> AssetMetadataStreamResult {
        if let beforeMetadataFetch { await beforeMetadataFetch() }
        return AssetMetadataStreamResult(
            iCloudIdUpserts: resetAck == nil ? ["asset-1": "cloud-1"] : [:],
            sourceChecksumUpserts: sourceChecksum.map { ["asset-1": $0] } ?? [:],
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
    private(set) var savedAssets: [ServerAssetRecord] = []
    var shouldFailCacheClear = false
    var shouldFailFullSnapshotFinalization = false
    var syncMetadata: SyncMetadata?
    var existingAsset: ServerAssetRecord?

    init(operations: OperationRecorder) {
        self.operations = operations
    }

    func isAssetOnServer(checksum: String) -> Bool { false }
    func getServerAssetByImmichId(_ immichId: String) -> ServerAssetRecord? {
        existingAsset?.immichId == immichId ? existingAsset : nil
    }
    func getSyncMetadata() -> SyncMetadata? { syncMetadata }
    func clearServerAssetsCache() -> Bool {
        operations.append("clear-cache")
        return !shouldFailCacheClear
    }
    private(set) var rebuildBarrierActive = false
    func setServerSnapshotRebuilding(_ rebuilding: Bool) -> Bool {
        rebuildBarrierActive = rebuilding
        operations.append(rebuilding ? "begin-rebuild" : "end-rebuild")
        return true
    }
    func refreshServerSnapshotRebuildLease() -> Bool {
        operations.append("refresh-rebuild")
        return true
    }

    func finalizeFullServerSnapshot(snapshotStartedAt: Date, destinationIdentity: String?) -> Bool {
        operations.append("finalize-full-snapshot")
        return !shouldFailFullSnapshotFinalization
    }

    func saveServerAssets(_ assets: [ServerAssetRecord], syncType: String) -> Bool {
        savedAssets = assets
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
        return true
    }

    func getServerAssetsCacheCount() -> Int { 1 }

    func backfillImmichIdsFromServerCache() -> Int {
        operations.append("backfill-immich-ids")
        return 0
    }
}
