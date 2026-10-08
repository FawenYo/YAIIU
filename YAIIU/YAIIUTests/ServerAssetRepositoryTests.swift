import SQLite3
import XCTest
@testable import YAIIU

final class ServerAssetRepositoryTests: XCTestCase {
    private var databaseURL: URL!
    private var connection: SQLiteConnection!
    private var repository: ServerAssetRepository!
    private var uploadRepository: UploadRecordRepository!
    override func setUp() {
        super.setUp()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaiiu-tests-\(UUID().uuidString).sqlite")
        connection = SQLiteConnection.testing(databasePath: databaseURL.path)
        connection.ensureInitialized()
        repository = ServerAssetRepository(connection: connection)
        uploadRepository = UploadRecordRepository(connection: connection)
    }

    override func tearDown() {
        uploadRepository = nil
        repository = nil
        connection = nil
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
        }
        databaseURL = nil
        super.tearDown()
    }

    func testAssetUpsertWithoutICloudIdPreservesExistingValue() {
        XCTAssertTrue(repository.saveServerAssets([record(checksum: "old", iCloudId: "cloud-1")]))

        XCTAssertTrue(repository.saveServerAssets([record(checksum: "new", iCloudId: nil)], syncType: "delta"))

        XCTAssertEqual(repository.getServerAssetByChecksum("new")?.iCloudId, "cloud-1")
    }

    func testAssetUpsertWithICloudIdReplacesExistingValue() {
        XCTAssertTrue(repository.saveServerAssets([record(checksum: "old", iCloudId: "cloud-1")]))

        XCTAssertTrue(repository.saveServerAssets([record(checksum: "new", iCloudId: "cloud-2")], syncType: "delta"))

        XCTAssertEqual(repository.getServerAssetByChecksum("new")?.iCloudId, "cloud-2")
    }
    func testAssetDeltaPreservesSourceChecksumWhileUpdatingServerChecksum() {
        XCTAssertTrue(repository.saveServerAssets([
            record(checksum: "server-old", sourceChecksum: "original", iCloudId: "cloud-1")
        ]))

        XCTAssertTrue(repository.saveServerAssets([
            record(checksum: "server-new", sourceChecksum: nil, iCloudId: nil)
        ], syncType: "delta"))

        let asset = repository.getServerAssetByImmichId("asset-1")
        XCTAssertEqual(asset?.checksum, "server-new")
        XCTAssertEqual(asset?.sourceChecksum, "original")
        XCTAssertEqual(repository.getServerAssetByChecksum("original")?.immichId, "asset-1")
    }

    func testSourceChecksumLookupSkipsMissingRowsAndNullChecksums() {
        XCTAssertTrue(repository.saveServerAssets([
            record(checksum: "sum-a", sourceChecksum: "original-a", iCloudId: nil),
            ServerAssetRecord(immichId: "asset-null", checksum: "sum-n", sourceChecksum: nil, originalFilename: nil, assetType: "IMAGE", updatedAt: nil, iCloudId: nil, ownerId: "owner-1")
        ]))

        let found = repository.sourceChecksums(for: ["asset-1", "asset-null", "asset-missing"])

        XCTAssertEqual(found, ["asset-1": "original-a"])
    }


    func testMetadataOnlyUpsertUpdatesExistingAsset() {
        XCTAssertTrue(repository.saveServerAssets([record(checksum: "sum", iCloudId: nil)]))

        XCTAssertTrue(repository.updateICloudIds(["asset-1": "cloud-1"]))

        XCTAssertEqual(repository.getServerAssetByChecksum("sum")?.iCloudId, "cloud-1")
    }

    func testMetadataDeleteClearsExistingICloudId() {
        XCTAssertTrue(repository.saveServerAssets([record(checksum: "sum", iCloudId: "cloud-1")]))

        XCTAssertTrue(repository.clearICloudIds(for: ["asset-1"]))

        XCTAssertNil(repository.getServerAssetByChecksum("sum")?.iCloudId)
    }

    func testMetadataUpdateDoesNotCreateIncompleteAsset() {
        XCTAssertTrue(repository.updateICloudIds(["missing": "cloud-1"]))

        XCTAssertEqual(repository.getServerAssetsCacheCount(), 0)
    }

    func testAssetSaveReturnsFalseWhenCommitFails() {
        installDeferredCommitFailure(triggerEvent: "INSERT")

        XCTAssertFalse(repository.saveServerAssets([record(checksum: "sum", iCloudId: "cloud-1")]))
    }

    func testAlbumAssetIdsSelectsOnlyPrimaryResourceForOwnedAsset() {
        let assetId = "asset-primary"
        let immichId = "11111111-1111-4111-8111-111111111111"
        XCTAssertTrue(repository.saveServerAssets([
            ServerAssetRecord(
                immichId: immichId,
                checksum: "sum-primary",
                originalFilename: "photo.jpg",
                assetType: "IMAGE",
                updatedAt: "2026-08-25T00:00:00Z",
                iCloudId: nil,
                ownerId: "owner-1"
            )
        ]))
        uploadRepository.recordUploadedAsset(localIdentifier: assetId, resourceType: "jpeg", filename: "photo.jpg", immichId: immichId)
        uploadRepository.recordUploadedAsset(localIdentifier: assetId, resourceType: "raw", filename: "photo.dng", immichId: "22222222-2222-4222-8222-222222222222")

        XCTAssertEqual(try uploadRepository.albumAssetIds(for: [assetId], ownerId: "owner-1"), [immichId])
    }

    func testAlbumAssetIdsRejectsForeignOwnerAndVideoResource() {
        let assetId = "asset-video"
        let foreignId = "33333333-3333-4333-8333-333333333333"
        XCTAssertTrue(repository.saveServerAssets([
            ServerAssetRecord(
                immichId: foreignId,
                checksum: "sum-foreign",
                originalFilename: "clip.mov",
                assetType: "VIDEO",
                updatedAt: "2026-08-25T00:00:00Z",
                iCloudId: nil,
                ownerId: "owner-2"
            )
        ]))
        uploadRepository.recordUploadedAsset(localIdentifier: assetId, resourceType: "video", filename: "clip.mov", immichId: foreignId)

        XCTAssertTrue(try uploadRepository.albumAssetIds(for: [assetId], ownerId: "owner-1").isEmpty)
    }

    func testBackfillResolvesStandaloneVideosAndExcludesSecondaryRawResources() {
        let videoAssetId = "asset-video"
        let rawAssetId = "asset-raw"
        let livePhotoAssetId = "asset-live-photo"
        let videoId = "44444444-4444-4444-8444-444444444444"
        let rawId = "55555555-5555-4555-8555-555555555555"
        let livePhotoId = "66666666-6666-4666-8666-666666666666"
        XCTAssertTrue(repository.saveServerAssets([
            ServerAssetRecord(immichId: videoId, checksum: "video-sum", ownerId: "owner-1"),
            ServerAssetRecord(immichId: rawId, checksum: "raw-sum", ownerId: "owner-1"),
            ServerAssetRecord(immichId: livePhotoId, checksum: "live-photo-sum", ownerId: "owner-1")
        ]))
        uploadRepository.recordUploadedAsset(localIdentifier: videoAssetId, resourceType: "video", filename: "clip.mov", immichId: "unknown")
        uploadRepository.recordUploadedAsset(localIdentifier: rawAssetId, resourceType: "raw", filename: "photo.dng", immichId: "unknown")
        uploadRepository.recordUploadedAsset(localIdentifier: livePhotoAssetId, resourceType: "jpeg", filename: "photo.jpg", immichId: "unknown")
        uploadRepository.recordUploadedAsset(localIdentifier: livePhotoAssetId, resourceType: "raw", filename: "photo.dng", immichId: "unknown")
        execute("INSERT INTO hash_cache (asset_id, sha1_hash, calculated_at) VALUES ('asset-video', 'video-sum', 0);")
        execute("INSERT INTO hash_cache (asset_id, sha1_hash, calculated_at) VALUES ('asset-raw', 'raw-sum', 0);")
        execute("INSERT INTO hash_cache (asset_id, sha1_hash, calculated_at) VALUES ('asset-live-photo', 'live-photo-sum', 0);")

        let resolved = uploadRepository.getResolvedImmichIdsFromServerCache()

        XCTAssertEqual(resolved[videoAssetId], videoId)
        XCTAssertEqual(resolved[rawAssetId], rawId)
        XCTAssertEqual(resolved[livePhotoAssetId], livePhotoId)
    }

    func testAlbumAssetIdsIncludesStandaloneVideoAndRawUploadRecords() throws {
        let videoId = "77777777-7777-4777-8777-777777777777"
        let rawId = "88888888-8888-4888-8888-888888888888"
        XCTAssertTrue(repository.saveServerAssets([
            ServerAssetRecord(immichId: videoId, checksum: "video-exact", ownerId: "owner-1"),
            ServerAssetRecord(immichId: rawId, checksum: "raw-exact", ownerId: "owner-1")
        ]))
        uploadRepository.recordUploadedAsset(localIdentifier: "standalone-video", resourceType: "video", filename: "clip.mov", immichId: videoId)
        uploadRepository.recordUploadedAsset(localIdentifier: "raw-only", resourceType: "raw", filename: "photo.dng", immichId: rawId)

        let ids = try uploadRepository.albumAssetIds(
            for: ["standalone-video", "raw-only"],
            ownerId: "owner-1"
        )

        XCTAssertEqual(Set(ids), [videoId, rawId])
    }

    func testCheckedMissingAssetsOnlyRecheckAfterMatchingDelta() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(localIdentifier: "matching", primaryHash: "new-sum", rawHash: nil, hasRAW: false)
        hashes.saveMultiResourceHashCache(localIdentifier: "unrelated", primaryHash: "other-sum", rawHash: nil, hasRAW: false)
        execute("UPDATE hash_cache SET checked_at = 100, is_on_server = 0;")
        XCTAssertEqual(pendingCheckCount(), 0)

        XCTAssertTrue(repository.saveServerAssets([], syncType: "delta"))
        XCTAssertEqual(pendingCheckCount(), 0)

        XCTAssertTrue(repository.saveServerAssets([record(checksum: "new-sum", iCloudId: nil)], syncType: "delta"))
        XCTAssertEqual(pendingCheckCount(), 1)
        XCTAssertTrue(isUnchecked("matching"))
        XCTAssertFalse(isUnchecked("unrelated"))
    }

    func testChangedAndDeletedChecksumsInvalidatePrimaryAndRAW() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(localIdentifier: "old", primaryHash: "old-sum", rawHash: nil, hasRAW: false)
        hashes.saveMultiResourceHashCache(localIdentifier: "new", primaryHash: "new-sum", rawHash: nil, hasRAW: false)
        hashes.saveMultiResourceHashCache(localIdentifier: "paired", primaryHash: "jpeg-sum", rawHash: "old-sum", hasRAW: true)
        hashes.saveMultiResourceHashCache(localIdentifier: "other", primaryHash: "other-sum", rawHash: nil, hasRAW: false)
        XCTAssertTrue(repository.saveServerAssets([record(checksum: "old-sum", iCloudId: nil)]))
        execute("UPDATE hash_cache SET checked_at = 100, is_on_server = 1, raw_on_server = 1;")

        XCTAssertTrue(repository.saveServerAssets([record(checksum: "new-sum", iCloudId: nil)], syncType: "delta"))
        XCTAssertEqual(pendingCheckCount(), 3)
        XCTAssertTrue(isUnchecked("old"))
        XCTAssertTrue(isUnchecked("new"))
        XCTAssertTrue(isUnchecked("paired"))
        XCTAssertFalse(isUnchecked("other"))

        execute("UPDATE hash_cache SET checked_at = 100, is_on_server = 1, raw_on_server = 1;")
        XCTAssertTrue(repository.deleteServerAssets(["asset-1"]))
        XCTAssertTrue(isUnchecked("new"))
        XCTAssertFalse(isUnchecked("other"))
    }

    func testSourceChecksumChangeInvalidatesBothOldAndNewMatches() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(localIdentifier: "old", primaryHash: "server-sum", rawHash: nil, hasRAW: false)
        hashes.saveMultiResourceHashCache(localIdentifier: "new", primaryHash: "source-sum", rawHash: nil, hasRAW: false)
        XCTAssertTrue(repository.saveServerAssets([record(checksum: "server-sum", iCloudId: nil)]))
        execute("UPDATE hash_cache SET checked_at = 100;")
        XCTAssertTrue(repository.updateSourceChecksums(["asset-1": "source-sum"]))
        XCTAssertEqual(pendingCheckCount(), 2)
    }

    func testFullServerResetInvalidatesVerdictsWithoutDeletingHashes() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(localIdentifier: "a", primaryHash: "sum-a", rawHash: nil, hasRAW: false)
        hashes.saveMultiResourceHashCache(localIdentifier: "b", primaryHash: "sum-b", rawHash: nil, hasRAW: false)
        execute("UPDATE hash_cache SET checked_at = 100, is_on_server = 1;")
        XCTAssertEqual(pendingCheckCount(), 0)
        XCTAssertTrue(repository.clearServerAssetsCache())
        XCTAssertEqual(pendingCheckCount(), 2)
        XCTAssertEqual(count("SELECT COUNT(*) FROM hash_cache;"), 2)
    }

    private func pendingCheckCount() -> Int {
        count("SELECT COUNT(*) FROM hash_cache WHERE checked_at IS NULL;")
    }

    private func isUnchecked(_ id: String) -> Bool {
        count("SELECT COUNT(*) FROM hash_cache WHERE asset_id = '\(id)' AND checked_at IS NULL;") == 1
    }

    private func count(_ query: String) -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection.db, query, -1, &statement, nil) == SQLITE_OK else {
            XCTFail("SQL prepare failed")
            return -1
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            XCTFail("SQL query failed")
            return -1
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    func testServerDeletionRemovesObsoleteUploadHistory() {
        let immichId = "asset-1"
        let localId = "locally-uploaded-photo"
        XCTAssertTrue(repository.saveServerAssets([
            record(checksum: "deleted-checksum", iCloudId: nil)
        ]))
        uploadRepository.recordUploadedAsset(
            localIdentifier: localId,
            resourceType: "photo",
            filename: "deleted.jpg",
            immichId: immichId
        )
        XCTAssertEqual(count("SELECT COUNT(*) FROM uploaded_assets WHERE immich_id = 'asset-1';"), 1)

        XCTAssertTrue(repository.deleteServerAssets([immichId]))
        XCTAssertEqual(count("SELECT COUNT(*) FROM uploaded_assets WHERE immich_id = 'asset-1';"), 0)
    }

    func testStaleVerdictCannotOverwriteServerDelta() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(localIdentifier: "one", primaryHash: "one-sum", rawHash: nil, hasRAW: false)
        XCTAssertTrue(repository.saveServerAssets([
            record(checksum: "one-sum", iCloudId: nil)
        ], syncType: "delta"))

        // The delta incremented this row's revision from 0 to 1.
        XCTAssertFalse(hashes.updateMultiResourceHashCacheServerStatusIfCurrent(
            localIdentifier: "one", primaryOnServer: false,
            rawOnServer: false, expectedRevision: 0
        ))
        XCTAssertTrue(isUnchecked("one"))
        XCTAssertTrue(hashes.updateMultiResourceHashCacheServerStatusIfCurrent(
            localIdentifier: "one", primaryOnServer: true,
            rawOnServer: false, expectedRevision: 1
        ))
        XCTAssertFalse(isUnchecked("one"))
    }

    func testICloudShortcutRejectsDeletedAndChangedServerChecksums() {
        let hashes = HashCacheRepository(connection: connection)
        XCTAssertTrue(repository.saveServerAssets([
            record(checksum: "original-sum", iCloudId: "cloud-1")
        ]))
        XCTAssertTrue(hashes.saveCurrentICloudIDMatch(
            localIdentifier: "first", iCloudId: "cloud-1",
            expectedChecksum: "original-sum", modificationDate: nil
        ))
        XCTAssertFalse(isUnchecked("first"))

        XCTAssertTrue(repository.saveServerAssets([
            record(checksum: "replacement-sum", iCloudId: "cloud-1")
        ], syncType: "delta"))
        XCTAssertFalse(hashes.saveCurrentICloudIDMatch(
            localIdentifier: "stale", iCloudId: "cloud-1",
            expectedChecksum: "original-sum", modificationDate: nil
        ))
        XCTAssertTrue(hashes.saveCurrentICloudIDMatch(
            localIdentifier: "current", iCloudId: "cloud-1",
            expectedChecksum: "replacement-sum", modificationDate: nil
        ))
        XCTAssertEqual(count("SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'stale';"), 0)

        XCTAssertTrue(repository.deleteServerAssets(["asset-1"]))
        XCTAssertFalse(hashes.saveCurrentICloudIDMatch(
            localIdentifier: "deleted", iCloudId: "cloud-1",
            expectedChecksum: "replacement-sum", modificationDate: nil
        ))
        XCTAssertEqual(count("SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'deleted';"), 0)
    }

    func testICloudShortcutNeverClobbersExistingRAWHashCache() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "paired", primaryHash: "jpeg-sum",
            rawHash: "raw-sum", hasRAW: true
        )
        XCTAssertTrue(repository.saveServerAssets([
            record(checksum: "server-sum", iCloudId: "cloud-1")
        ]))
        XCTAssertFalse(hashes.saveCurrentICloudIDMatch(
            localIdentifier: "paired", iCloudId: "cloud-1",
            expectedChecksum: "server-sum", modificationDate: nil
        ))
        XCTAssertEqual(count("SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'paired' AND raw_hash = 'raw-sum' AND has_raw = 1;"), 1)
    }

    func testEmptyCompletedServerSnapshotIsAuthoritative() {
        XCTAssertFalse(repository.hasServerCache())
        XCTAssertTrue(repository.saveSyncMetadata(
            lastSyncTime: Date(), syncType: "full",
            userId: "owner-1", serverURL: "https://immich.example",
            totalAssets: 0, lastAck: "checkpoint"
        ))
        XCTAssertTrue(repository.hasServerCache())
    }

    func testCheckedUploadDisplayIgnoresStaleHistoricalUpload() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "deleted-on-server", primaryHash: "missing-sum",
            rawHash: nil, hasRAW: false
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "found-on-server", primaryHash: "present-sum",
            rawHash: nil, hasRAW: false
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "awaiting-check", primaryHash: "unknown-sum",
            rawHash: nil, hasRAW: false
        )
        execute("""
            UPDATE hash_cache SET
              checked_at = CASE WHEN asset_id = 'awaiting-check' THEN NULL ELSE 100 END,
              is_on_server = CASE WHEN asset_id = 'found-on-server' THEN 1 ELSE 0 END;
        """)
        let ready = expectation(description: "Status map reflects current verdicts")
        hashes.getAllSyncStatusAsync(
            uploadedResourceTypes: ["deleted-on-server": ["photo"]],
            hasServerCache: true
        ) { statuses in
            XCTAssertEqual(statuses["deleted-on-server"], .notUploaded)
            XCTAssertEqual(statuses["found-on-server"], .uploaded)
            XCTAssertEqual(statuses["awaiting-check"], .pending)
            ready.fulfill()
        }
        wait(for: [ready], timeout: 5)
    }

    func testFullSnapshotReconcilesPrimaryAndRAWWithoutPerAssetRecheck() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(localIdentifier: "server-primary",
            primaryHash: "server-sum", rawHash: nil, hasRAW: false)
        hashes.saveMultiResourceHashCache(localIdentifier: "missing-primary",
            primaryHash: "missing-sum", rawHash: nil, hasRAW: false)
        hashes.saveMultiResourceHashCache(localIdentifier: "raw-partial",
            primaryHash: "server-sum", rawHash: "raw-missing", hasRAW: true)
        hashes.saveMultiResourceHashCache(localIdentifier: "raw-complete",
            primaryHash: "server-sum", rawHash: "raw-present", hasRAW: true)
        execute("UPDATE hash_cache SET checked_at = 100, is_on_server = 1, raw_on_server = 1;")

        XCTAssertTrue(repository.clearServerAssetsCache())
        XCTAssertEqual(pendingCheckCount(), 4)
        XCTAssertTrue(repository.saveServerAssets([
            record(checksum: "server-sum", iCloudId: nil),
            ServerAssetRecord(immichId: "raw-1", checksum: "raw-present", ownerId: "owner-1")
        ], syncType: "full"))
        XCTAssertTrue(repository.finalizeFullServerSnapshot())

        XCTAssertEqual(pendingCheckCount(), 0)
        XCTAssertEqual(count("SELECT COUNT(*) FROM hash_cache WHERE is_on_server = 1;"), 3)
        XCTAssertEqual(count("SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'raw-partial' AND is_on_server = 1 AND raw_on_server = 0;"), 1)
        XCTAssertEqual(count("SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'raw-complete' AND is_on_server = 1 AND raw_on_server = 1;"), 1)
        XCTAssertEqual(count("SELECT COUNT(*) FROM background_upload_queue;"), 2)
        XCTAssertEqual(count("SELECT COUNT(*) FROM hash_cache WHERE sha1_hash = 'missing-sum';"), 1)
    }

    func testEmptyFullSnapshotMarksOldChecksAsNotUploadedWithoutRecheck() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(localIdentifier: "former-server-photo",
            primaryHash: "old-checksum", rawHash: nil, hasRAW: false)
        execute("UPDATE hash_cache SET checked_at = 100, is_on_server = 1;")
        XCTAssertTrue(repository.clearServerAssetsCache())
        XCTAssertTrue(repository.finalizeFullServerSnapshot())
        XCTAssertEqual(pendingCheckCount(), 0)
        XCTAssertEqual(count("SELECT COUNT(*) FROM hash_cache WHERE is_on_server = 1;"), 0)
        XCTAssertEqual(count("SELECT COUNT(*) FROM background_upload_queue;"), 1)
    }

    func testFullSnapshotMatchesSourceChecksumBeforeTranscodedChecksum() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(localIdentifier: "source",
            primaryHash: "original-sum", rawHash: nil, hasRAW: false)
        hashes.saveMultiResourceHashCache(localIdentifier: "transcode",
            primaryHash: "server-sum", rawHash: nil, hasRAW: false)
        XCTAssertTrue(repository.clearServerAssetsCache())
        XCTAssertTrue(repository.saveServerAssets([
            record(checksum: "server-sum", sourceChecksum: "original-sum", iCloudId: nil)
        ], syncType: "full"))
        XCTAssertTrue(repository.finalizeFullServerSnapshot())
        XCTAssertEqual(count("SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'source' AND is_on_server = 1;"), 1)
        XCTAssertEqual(count("SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'transcode' AND is_on_server = 0;"), 1)
    }

    func testFullSnapshotPreservesValidHistoryAndClearsOrphans() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "previous-miss", primaryHash: "missing-checksum",
            rawHash: nil, hasRAW: false
        )
        execute("UPDATE hash_cache SET checked_at = 100, is_on_server = 1;")

        XCTAssertTrue(repository.saveServerAssets([
            record(checksum: "still-present", iCloudId: "cloud-1")
        ], syncType: "full"))
        uploadRepository.recordUploadedAsset(
            localIdentifier: "valid", resourceType: "photo",
            filename: "valid.jpg", immichId: "asset-1"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "gone", resourceType: "photo",
            filename: "gone.jpg", immichId: "deleted-server-id"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "unresolved", resourceType: "photo",
            filename: "unknown.jpg", immichId: "unknown"
        )

        XCTAssertTrue(repository.finalizeFullServerSnapshot())
        XCTAssertEqual(count("SELECT COUNT(*) FROM uploaded_assets WHERE immich_id = 'asset-1';"), 1)
        XCTAssertEqual(count("SELECT COUNT(*) FROM uploaded_assets WHERE immich_id = 'deleted-server-id';"), 0)
        XCTAssertEqual(count("SELECT COUNT(*) FROM uploaded_assets WHERE immich_id = 'unknown';"), 0)
        XCTAssertEqual(count("SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'previous-miss' AND checked_at IS NOT NULL AND is_on_server = 0;"), 1)
        XCTAssertEqual(count("SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'previous-miss' AND sha1_hash = 'missing-checksum';"), 1)
    }

    private func installDeferredCommitFailure(triggerEvent: String) {
        execute("PRAGMA foreign_keys = ON;")
        execute("CREATE TABLE commit_failure_parent (id INTEGER PRIMARY KEY);")
        execute("CREATE TABLE commit_failure_child (parent_id INTEGER REFERENCES commit_failure_parent(id) DEFERRABLE INITIALLY DEFERRED);")
        execute("""
        CREATE TRIGGER fail_server_asset_commit
        AFTER \(triggerEvent) ON server_assets_cache
        BEGIN
            INSERT INTO commit_failure_child(parent_id) VALUES (1);
        END;
        """)
    }

    private func execute(_ sql: String) {
        XCTAssertEqual(sqlite3_exec(connection.db, sql, nil, nil, nil), SQLITE_OK)
    }

    private func record(checksum: String, sourceChecksum: String? = nil, iCloudId: String?) -> ServerAssetRecord {
        ServerAssetRecord(
            immichId: "asset-1",
            checksum: checksum,
            sourceChecksum: sourceChecksum,
            originalFilename: "photo.jpg",
            assetType: "IMAGE",
            updatedAt: "2026-08-25T00:00:00Z",
            iCloudId: iCloudId,
            ownerId: "owner-1"
        )
    }
}
