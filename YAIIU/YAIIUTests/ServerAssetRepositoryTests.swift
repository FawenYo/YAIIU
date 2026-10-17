import SQLite3
import XCTest
@testable import YAIIU

final class ServerAssetRepositoryTests: XCTestCase {
    private var databaseURL: URL!
    private var connection: SQLiteConnection!
    private var repository: ServerAssetRepository!
    private var uploadRepository: UploadRecordRepository!
    private var hashRepository: HashCacheRepository!
    override func setUp() {
        super.setUp()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaiiu-tests-\(UUID().uuidString).sqlite")
        connection = SQLiteConnection.testing(databasePath: databaseURL.path)
        connection.ensureInitialized()
        repository = ServerAssetRepository(connection: connection)
        uploadRepository = UploadRecordRepository(connection: connection)
        hashRepository = HashCacheRepository(connection: connection)
    }

    override func tearDown() {
        hashRepository = nil
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

    func testCompletedNegativeMatchesAreNotRecheckedWithoutServerDelta() async {
        execute("""
            INSERT INTO hash_cache (asset_id, sha1_hash, calculated_at, checked_at)
            VALUES ('existing-negative', 'sha-negative', 0, 100);
        """)
        let before = await uncheckedHashIds()
        XCTAssertTrue(before.isEmpty)
        XCTAssertTrue(hashRepository.invalidateHashChecksForServerChanges(
            checksums: [], fullReset: false
        ))
        let after = await uncheckedHashIds()
        XCTAssertTrue(after.isEmpty)
    }

    func testDeltaInvalidatesOnlyMatchingPrimaryAndRawHashes() async {
        execute("""
            INSERT INTO hash_cache
                (asset_id, sha1_hash, raw_hash, has_raw, is_on_server, calculated_at, checked_at)
            VALUES
                ('primary', 'sha-new', NULL, 0, 0, 0, 100),
                ('raw-companion', 'sha-other', 'raw-new', 1, 1, 0, 100),
                ('unrelated', 'sha-stable', NULL, 0, 0, 0, 100);
        """)
        XCTAssertTrue(hashRepository.invalidateHashChecksForServerChanges(
            checksums: ["sha-new", "raw-new"], fullReset: false
        ))
        let dirty = await uncheckedHashIds()
        XCTAssertEqual(Set(dirty), ["primary", "raw-companion"])
    }

    func testFullResetRetainsComputedHashes() async {
        execute("""
            INSERT INTO hash_cache (asset_id, sha1_hash, calculated_at, checked_at)
            VALUES ('first', 'sha-first', 0, 100), ('second', 'sha-second', 0, 100);
        """)
        XCTAssertTrue(hashRepository.invalidateHashChecksForServerChanges(
            checksums: [], fullReset: true
        ))
        let dirty = await uncheckedHashIds()
        XCTAssertEqual(Set(dirty), ["first", "second"])
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            connection.db, "SELECT sha1_hash FROM hash_cache WHERE asset_id='first';",
            -1, &statement, nil
        ), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "sha-first")
    }

    func testFullLibrarySnapshotPrunesEvenAlreadyCheckedOrphans() {
        execute("""
            INSERT INTO hash_cache (asset_id, sha1_hash, calculated_at, checked_at)
            VALUES ('still-local', 'sha-a', 0, 100), ('photo-deleted', 'sha-b', 0, 100);
        """)
        uploadRepository.recordUploadedAsset(
            localIdentifier: "photo-deleted", resourceType: "primary",
            filename: "deleted.jpg", immichId: "remote-asset"
        )
        hashRepository.resetCacheForModifiedAssets(
            snapshots: [PhotoAssetSnapshot(localIdentifier: "still-local", modificationDate: nil)],
            pruneOrphans: true
        )
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: "photo-deleted"))
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: "still-local"))
        XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: "photo-deleted"))
    }

    func testLimitedLibrarySnapshotDoesNotPruneInvisibleAssets() {
        execute("""
            INSERT INTO hash_cache (asset_id, sha1_hash, calculated_at, checked_at)
            VALUES ('hidden-but-existing', 'sha-a', 0, 100);
        """)
        hashRepository.resetCacheForModifiedAssets(
            snapshots: [PhotoAssetSnapshot(localIdentifier: "visible", modificationDate: nil)],
            pruneOrphans: false
        )
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: "hidden-but-existing"))
    }

    func testEmptyFullLibraryPrunesFinalOrphan() {
        execute("""
            INSERT INTO hash_cache (asset_id, sha1_hash, calculated_at, checked_at)
            VALUES ('deleted-last-photo', 'sha-last', 0, 100);
        """)
        hashRepository.resetCacheForModifiedAssets(snapshots: [], pruneOrphans: true)
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: "deleted-last-photo"))
    }

    func testFullSnapshotPrunesMissingBackgroundQueueAndPreservesHiddenPhotos() {
        execute("""
            INSERT INTO hash_cache (asset_id, sha1_hash, calculated_at, checked_at)
            VALUES ('visible', 'sha-visible', 0, 100),
                   ('hidden', 'sha-hidden', 0, 100),
                   ('deleted', 'sha-deleted', 0, 100);
            INSERT INTO background_upload_queue (asset_id, enqueued_at)
            VALUES ('visible', 1), ('hidden', 1), ('deleted', 1), ('queue-only-deleted', 1);
            INSERT INTO upload_jobs (asset_id, resource_type, filename, status, created_at, updated_at)
            VALUES ('deleted', 'primary', 'old.jpg', 'pending', 0, 0),
                   ('queue-only-deleted', 'raw', 'old.dng', 'failed', 0, 0),
                   ('hidden', 'primary', 'hidden.jpg', 'pending', 0, 0);
        """)
        let fullSnapshots = [
            PhotoAssetSnapshot(localIdentifier: "visible", modificationDate: nil),
            PhotoAssetSnapshot(localIdentifier: "hidden", modificationDate: nil, isHidden: true)
        ]
        XCTAssertEqual(PhotoAssetSnapshot.visibleIdentifiers(in: fullSnapshots), ["visible"])
        hashRepository.resetCacheForModifiedAssets(snapshots: fullSnapshots, pruneOrphans: true)

        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: "visible"))
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: "hidden"))
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: "deleted"))
        XCTAssertEqual(queuedIds(), ["hidden", "visible"])
        XCTAssertEqual(jobIds(), ["hidden"])
    }

    func testModifiedAssetPreservesBackgroundQueue() {
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "modified", primaryHash: "before",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100)
        )
        execute("INSERT INTO background_upload_queue (asset_id, enqueued_at) VALUES ('modified', 1);")
        hashRepository.resetCacheForModifiedAssets(
            snapshots: [
                PhotoAssetSnapshot(
                    localIdentifier: "modified", modificationDate: Date(timeIntervalSince1970: 110)
                )
            ],
            pruneOrphans: true
        )
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: "modified"))
        XCTAssertEqual(queuedIds(), ["modified"])
    }

    func testHiddenOnlyFullSnapshotDoesNotDeleteHiddenCache() {
        execute("""
            INSERT INTO hash_cache (asset_id, sha1_hash, calculated_at, checked_at)
            VALUES ('hidden', 'sha-hidden', 0, 100), ('deleted', 'sha-deleted', 0, 100);
        """)
        hashRepository.resetCacheForModifiedAssets(
            snapshots: [
                PhotoAssetSnapshot(localIdentifier: "hidden", modificationDate: nil, isHidden: true)
            ],
            pruneOrphans: true
        )
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: "hidden"))
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: "deleted"))
    }

    func testQueueDeleteErrorRollsBackCacheAndReceiptCleanup() {
        execute("""
            INSERT INTO hash_cache (asset_id, sha1_hash, calculated_at, checked_at)
            VALUES ('deleted', 'sha-deleted', 0, 100);
            INSERT INTO background_upload_queue (asset_id, enqueued_at) VALUES ('deleted', 1);
            CREATE TRIGGER block_queue_deletion BEFORE DELETE ON background_upload_queue
            BEGIN SELECT RAISE(ABORT, 'simulated queue failure'); END;
        """)
        uploadRepository.recordUploadedAsset(
            localIdentifier: "deleted", resourceType: "primary",
            filename: "deleted.jpg", immichId: "remote-id"
        )
        hashRepository.resetCacheForModifiedAssets(snapshots: [], pruneOrphans: true)
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: "deleted"))
        XCTAssertTrue(uploadRepository.isAnyResourceUploaded(localIdentifier: "deleted"))
        XCTAssertEqual(queuedIds(), ["deleted"])
    }

    private func queuedIds() -> [String] {
        ids(for: "SELECT asset_id FROM background_upload_queue ORDER BY asset_id;")
    }

    private func jobIds() -> [String] {
        ids(for: "SELECT asset_id FROM upload_jobs ORDER BY asset_id;")
    }

    private func ids(for sql: String) -> [String] {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        return result
    }

    func testRemoteDeletionPrunesOnlyMatchingUploadReceipts() {
        XCTAssertTrue(repository.saveServerAssets([record(checksum: "sha-deleted", iCloudId: nil)]))
        uploadRepository.recordUploadedAsset(
            localIdentifier: "deleted-local", resourceType: "primary",
            filename: "old.jpg", immichId: "asset-1"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "other-local", resourceType: "primary",
            filename: "other.jpg", immichId: "other-server-id"
        )
        XCTAssertTrue(repository.deleteServerAssets(["asset-1"]))
        XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: "deleted-local"))
        XCTAssertTrue(uploadRepository.isAnyResourceUploaded(localIdentifier: "other-local"))
    }

    private func uncheckedHashIds() async -> [String] {
        await withCheckedContinuation { continuation in
            hashRepository.getMultiResourceHashesNotFullyOnServerAsync { records in
                continuation.resume(returning: records.map(\.assetId))
            }
        }
    }

    // MARK: - Phase 2: Foreground PhotoKit Change Journal

    func testForegroundBootstrapQueuesOnlyUnhashedVisiblePhotos() {
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "cached", primaryHash: "sha-cached",
            rawHash: nil, hasRAW: false, modificationDate: nil
        )
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "hidden", primaryHash: "sha-hidden",
            rawHash: nil, hasRAW: false, modificationDate: nil
        )
        execute("INSERT INTO change_tokens(id, token_data, updated_at) VALUES (1, X'ABCD', 0);")
        let snapshots = [
            PhotoAssetSnapshot(localIdentifier: "cached", modificationDate: nil),
            PhotoAssetSnapshot(localIdentifier: "new-photo", modificationDate: nil),
            PhotoAssetSnapshot(localIdentifier: "hidden", modificationDate: nil, isHidden: true)
        ]
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: snapshots,
            pendingIdentifiers: Set(["cached", "new-photo"]),
            deletedIdentifiers: [],
            tokenData: Data([1, 2, 3]),
            bootstrap: true
        ))
        XCTAssertEqual(hashRepository.loadForegroundPhotoToken(), Data([1, 2, 3]))
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), ["new-photo"])
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: "hidden"))
        XCTAssertEqual(hexBlob("SELECT token_data FROM change_tokens WHERE id = 1"), "ABCD")
    }

    func testForegroundDeltaInvalidatesEditsAndDeletesAtomically() {
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "edited", primaryHash: "sha-old",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100)
        )
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "deleted", primaryHash: "sha-gone",
            rawHash: nil, hasRAW: false, modificationDate: nil
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "edited", resourceType: "primary", filename: "a.jpg", immichId: "remote-a"
        )
        execute("""
            INSERT INTO foreground_photo_pending_assets(asset_id) VALUES ('old-pending');
            INSERT INTO background_upload_queue(asset_id, enqueued_at) VALUES ('deleted', 1);
            INSERT INTO upload_jobs (asset_id, resource_type, filename, status, created_at, updated_at)
            VALUES ('deleted', 'primary', 'b.jpg', 'pending', 0, 0);
        """)
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [
                PhotoAssetSnapshot(localIdentifier: "edited", modificationDate: Date(timeIntervalSince1970: 120)),
                PhotoAssetSnapshot(localIdentifier: "new", modificationDate: nil)
            ],
            pendingIdentifiers: Set(["edited", "new"]),
            deletedIdentifiers: ["deleted"],
            tokenData: Data([5, 6]),
            bootstrap: false
        ))
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: "edited"))
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: "deleted"))
        XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: "edited"))
        XCTAssertEqual(Set(hashRepository.getPendingForegroundPhotoIdentifiers()), ["old-pending", "edited", "new"])
        XCTAssertTrue(queuedIds().isEmpty)
        XCTAssertTrue(jobIds().isEmpty)
        XCTAssertEqual(hashRepository.loadForegroundPhotoToken(), Data([5, 6]))
    }

    func testForegroundMetadataOnlyUpdateKeepsExistingHashAndReceipt() {
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "favorite-changed", primaryHash: "sha-1",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100)
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "favorite-changed", resourceType: "primary",
            filename: "a.jpg", immichId: "remote-id"
        )
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [
                PhotoAssetSnapshot(
                    localIdentifier: "favorite-changed",
                    modificationDate: Date(timeIntervalSince1970: 100)
                )
            ],
            pendingIdentifiers: ["favorite-changed"],
            deletedIdentifiers: [],
            tokenData: Data([2]),
            bootstrap: false
        ))
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: "favorite-changed"))
        XCTAssertTrue(uploadRepository.isAnyResourceUploaded(localIdentifier: "favorite-changed"))
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), [])
    }

    func testForegroundPendingWorkSurvivesUntilHashIsPersisted() {
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(localIdentifier: "pending", modificationDate: nil)],
            pendingIdentifiers: ["pending"], deletedIdentifiers: [],
            tokenData: Data([9]), bootstrap: false
        ))
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), ["pending"])
        let secondRepository = HashCacheRepository(connection: connection)
        XCTAssertEqual(secondRepository.getPendingForegroundPhotoIdentifiers(), ["pending"])
        secondRepository.saveMultiResourceHashCache(
            localIdentifier: "pending", primaryHash: "sha-done",
            rawHash: nil, hasRAW: false, modificationDate: nil
        )
        XCTAssertTrue(secondRepository.getPendingForegroundPhotoIdentifiers().isEmpty)
    }

    func testUnversionedHashBackfillPreservesRAWAndServerState() {
        let id = "imported-raw"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id, primaryHash: "primary",
            rawHash: "raw", hasRAW: true, modificationDate: nil
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: id, resourceType: "jpeg",
            filename: "a.jpg", immichId: "remote"
        )
        let pending = hashRepository.unversionedHashCacheRows()
        XCTAssertTrue(pending.contains { $0.localIdentifier == id && $0.sha1Hash == "primary" })
        XCTAssertEqual(hashRepository.backfillUnversionedHashDates([
            (localIdentifier: id, sha1Hash: "primary",
             modificationDate: Date(timeIntervalSince1970: 123.5))
        ]), 1)
        XCTAssertEqual(sqlCount("""
            SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'imported-raw'
            AND asset_modification_date = 123.5 AND has_raw = 1 AND raw_hash = 'raw';
            """), 1)
        XCTAssertTrue(uploadRepository.isAnyResourceUploaded(localIdentifier: id))
        XCTAssertFalse(hashRepository.unversionedHashCacheRows().contains {
            $0.localIdentifier == id
        })
        // Idempotent after the initial baseline.
        XCTAssertEqual(hashRepository.backfillUnversionedHashDates([
            (localIdentifier: id, sha1Hash: "primary",
             modificationDate: Date(timeIntervalSince1970: 999))
        ]), 0)
    }

    func testUnversionedHashBackfillNeverOverwritesConcurrentHash() {
        let id = "concurrent-version"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id, primaryHash: "old",
            rawHash: nil, hasRAW: false, modificationDate: nil
        )
        let old = hashRepository.unversionedHashCacheRows()
        XCTAssertTrue(old.contains { $0.localIdentifier == id && $0.sha1Hash == "old" })
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id, primaryHash: "new",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 400)
        )
        XCTAssertEqual(hashRepository.backfillUnversionedHashDates([
            (localIdentifier: id, sha1Hash: "old",
             modificationDate: Date(timeIntervalSince1970: 100))
        ]), 0)
        XCTAssertEqual(sqlCount("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'concurrent-version' AND sha1_hash = 'new'
              AND asset_modification_date = 400;
            """), 1)
    }

    func testImmichImportDoesNotOverwriteVersionedRAWCacheOrReceipts() {
        let id = "existing-pair"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id, primaryHash: "existing-primary",
            rawHash: "existing-raw", hasRAW: true,
            modificationDate: Date(timeIntervalSince1970: 123)
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: id, resourceType: "jpeg",
            filename: "image.jpg", immichId: "existing-remote"
        )
        hashRepository.batchSaveHashCache(items: [
            (localIdentifier: id, sha1Hash: "different-import", fileSize: 0, syncStatus: "checked"),
            (localIdentifier: "imported-new", sha1Hash: "imported-hash", fileSize: 0, syncStatus: "checked")
        ])

        XCTAssertEqual(hashRepository.getHashCache(localIdentifier: id)?.sha1Hash, "existing-primary")
        XCTAssertEqual(sqlCount("""
            SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'existing-pair'
              AND raw_hash = 'existing-raw' AND has_raw = 1
              AND asset_modification_date = 123 AND is_on_server = 0;
            """), 1)
        XCTAssertTrue(uploadRepository.isAnyResourceUploaded(localIdentifier: id))
        XCTAssertEqual(hashRepository.getHashCache(localIdentifier: "imported-new")?.sha1Hash, "imported-hash")
        XCTAssertEqual(sqlCount("""
            SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'imported-new'
              AND asset_modification_date IS NULL AND is_on_server = 1;
            """), 1)
    }

    func testImmichReimportMatchingHashPreservesVersionAndMarksOnServer() {
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "matching", primaryHash: "matching-hash",
            rawHash: "raw-hash", hasRAW: true,
            modificationDate: Date(timeIntervalSince1970: 150)
        )
        hashRepository.batchSaveHashCache(items: [
            (localIdentifier: "matching", sha1Hash: "matching-hash", fileSize: 0, syncStatus: "checked")
        ])
        XCTAssertEqual(sqlCount("""
            SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'matching'
              AND sha1_hash = 'matching-hash' AND raw_hash = 'raw-hash'
              AND has_raw = 1 AND asset_modification_date = 150 AND is_on_server = 1;
            """), 1)
        // The imported primary exists remotely, but its RAW companion still
        // needs checking and must not be stranded after checked_at is set.
        XCTAssertTrue(queuedIds().contains("matching"))
    }

    func testImportRollsBackServerStatusIfRAWQueueInsertFails() {
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "incomplete-raw", primaryHash: "primary",
            rawHash: "raw", hasRAW: true,
            modificationDate: Date(timeIntervalSince1970: 250)
        )
        execute("""
            CREATE TRIGGER reject_import_queue
            BEFORE INSERT ON background_upload_queue
            BEGIN SELECT RAISE(ABORT, 'queue write failed'); END;
        """)
        XCTAssertFalse(hashRepository.batchSaveHashCache(items: [
            (localIdentifier: "incomplete-raw", sha1Hash: "primary",
             fileSize: 0, syncStatus: "checked")
        ]))
        XCTAssertEqual(sqlCount("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'incomplete-raw' AND is_on_server = 0
              AND checked_at IS NULL AND raw_hash = 'raw'
              AND asset_modification_date = 250;
            """), 1)
        XCTAssertFalse(queuedIds().contains("incomplete-raw"))
    }

    func testUploadVersionHeaderRetainsSubsecondPrecisionAndRejectsLegacyJobs() {
        let recorded = Date(timeIntervalSince1970: 1_791_297_704.25)
        let same = Date(timeIntervalSince1970: 1_791_297_704.25)
        let edited = Date(timeIntervalSince1970: 1_791_297_704.75)
        let header = PhotoAssetVersionPolicy.uploadVersionHeader(for: recorded)

        XCTAssertNotNil(header)
        XCTAssertTrue(PhotoAssetVersionPolicy.matchesUploadVersion(header, currentDate: same))
        XCTAssertFalse(PhotoAssetVersionPolicy.matchesUploadVersion(header, currentDate: edited))
        XCTAssertFalse(PhotoAssetVersionPolicy.matchesUploadVersion(header, currentDate: nil))
        XCTAssertFalse(PhotoAssetVersionPolicy.matchesUploadVersion(nil, currentDate: same))
        XCTAssertFalse(PhotoAssetVersionPolicy.matchesUploadVersion("not-a-version", currentDate: same))
        XCTAssertEqual(PhotoAssetVersionPolicy.uploadVersionHeader(for: nil), "unknown")
        XCTAssertTrue(PhotoAssetVersionPolicy.matchesUploadVersion("unknown", currentDate: nil))
        XCTAssertFalse(PhotoAssetVersionPolicy.matchesUploadVersion("unknown", currentDate: same))
        XCTAssertFalse(PhotoAssetVersionPolicy.matchesUploadVersion(header, currentDate: nil))
    }

    func testBatchedUploadCachePresenceAcrossSQLiteParameterChunks() {
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "asset-0", primaryHash: "first",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100)
        )
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "asset-401", primaryHash: "second",
            rawHash: "raw", hasRAW: true,
            modificationDate: Date(timeIntervalSince1970: 200)
        )
        let selected = (0..<450).map { "asset-\($0)" }
        XCTAssertEqual(
            hashRepository.cachedHashIdentifiers(for: selected),
            Set(["asset-0", "asset-401"])
        )
        XCTAssertEqual(hashRepository.cachedHashIdentifiers(for: []), Set<String>())
    }

    func testForegroundBootstrapKeepsUnknownVersionUnverified() {
        let id = "legacy"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id, primaryHash: "sha-legacy",
            rawHash: nil, hasRAW: false, modificationDate: nil
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: id, resourceType: "jpeg",
            filename: "image.jpg", immichId: "existing-remote"
        )
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(
                localIdentifier: id, modificationDate: Date(timeIntervalSince1970: 100)
            )],
            pendingIdentifiers: [id], deletedIdentifiers: [],
            tokenData: Data([1]), bootstrap: true
        ))
        XCTAssertEqual(sqlCount("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'legacy' AND asset_modification_date IS NULL;
            """), 1)
        XCTAssertTrue(uploadRepository.isAnyResourceUploaded(localIdentifier: id))
        // A later PhotoKit update cannot falsely reuse the unknown version.
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(
                localIdentifier: id, modificationDate: Date(timeIntervalSince1970: 100)
            )],
            pendingIdentifiers: [id], deletedIdentifiers: [],
            tokenData: Data([2]), bootstrap: false
        ))
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: id))
        XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: id))
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), [id])
    }

    func testFallbackSnapshotRehashesUnknownVisibleVersion() {
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "fallback-legacy", primaryHash: "cached",
            rawHash: nil, hasRAW: false, modificationDate: nil
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "fallback-legacy", resourceType: "jpeg",
            filename: "photo.jpg", immichId: "remote"
        )
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "hidden-legacy", primaryHash: "hidden",
            rawHash: nil, hasRAW: false, modificationDate: nil
        )
        hashRepository.resetCacheForModifiedAssets(
            snapshots: [
                PhotoAssetSnapshot(localIdentifier: "fallback-legacy",
                                   modificationDate: Date(timeIntervalSince1970: 200)),
                PhotoAssetSnapshot(localIdentifier: "hidden-legacy",
                                   modificationDate: nil, isHidden: true)
            ]
        )
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: "fallback-legacy"))
        XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: "fallback-legacy"))
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: "hidden-legacy"))
    }

    func testUnknownModificationDateIsConservativelyInvalidatedOnUpdate() {
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "legacy", primaryHash: "sha-legacy",
            rawHash: nil, hasRAW: false, modificationDate: nil
        )
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [
                PhotoAssetSnapshot(
                    localIdentifier: "legacy", modificationDate: Date(timeIntervalSince1970: 120)
                )
            ],
            pendingIdentifiers: ["legacy"], deletedIdentifiers: [],
            tokenData: Data([1]), bootstrap: false
        ))
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: "legacy"))
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), ["legacy"])
    }

    func testForegroundDeltaFailureRollsBackCheckpointAndHashInvalidation() {
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "edited", primaryHash: "sha-before",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100)
        )
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [], pendingIdentifiers: [], deletedIdentifiers: [],
            tokenData: Data([1]), bootstrap: false
        ))
        execute("""
            CREATE TRIGGER block_pending_ingestion
            BEFORE INSERT ON foreground_photo_pending_assets
            BEGIN SELECT RAISE(ABORT, 'simulate interrupted delta'); END;
        """)
        XCTAssertFalse(hashRepository.applyForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(
                localIdentifier: "edited", modificationDate: Date(timeIntervalSince1970: 120)
            )],
            pendingIdentifiers: ["edited"], deletedIdentifiers: [],
            tokenData: Data([2]), bootstrap: false
        ))
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: "edited"))
        XCTAssertEqual(hashRepository.loadForegroundPhotoToken(), Data([1]))
    }

    func testBootstrapPrunesDeletedQueueOnlyButPreservesHiddenCache() {
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "hidden", primaryHash: "sha-hidden",
            rawHash: nil, hasRAW: false, modificationDate: nil
        )
        execute("""
            INSERT INTO background_upload_queue(asset_id, enqueued_at)
            VALUES ('deleted-queue-only', 1), ('hidden', 2);
        """)
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [
                PhotoAssetSnapshot(localIdentifier: "hidden", modificationDate: nil, isHidden: true)
            ],
            pendingIdentifiers: [], deletedIdentifiers: [],
            tokenData: Data([0]), bootstrap: true
        ))
        XCTAssertEqual(queuedIds(), ["hidden"])
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: "hidden"))
        XCTAssertTrue(hashRepository.getPendingForegroundPhotoIdentifiers().isEmpty)
    }

    func testBackgroundPhotoKitMetadataUpdateRetainsKnownHashAndUploadReceipts() {
        let id = "unchanged-raw-pair"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id, primaryHash: "sha-jpeg", rawHash: "sha-raw",
            hasRAW: true, modificationDate: Date(timeIntervalSince1970: 100)
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: id, resourceType: "jpeg", filename: "image.jpg", immichId: "remote-jpeg"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: id, resourceType: "raw", filename: "image.dng", immichId: "remote-raw"
        )
        execute("""
            INSERT INTO upload_jobs (asset_id, resource_type, filename, status, created_at, updated_at)
            VALUES ('unchanged-raw-pair', 'jpeg', 'image.jpg', 'completed', 0, 0),
                   ('unchanged-raw-pair', 'raw', 'image.dng', 'completed', 0, 0);
        """)

        let background = BackgroundUploadDatabase(testingDatabasePath: databaseURL.path)
        let summary = background.commitPersistentChange(
            insertedAssetIds: [], updatedAssetIds: [id], deletedAssetIds: [],
            updatedAssetModificationDates: [id: Date(timeIntervalSince1970: 100)],
            tokenData: Data([1])
        )

        XCTAssertEqual(summary?.retainedVersions, 1)
        XCTAssertEqual(summary?.invalidatedVersions, 0)
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: id))
        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM hash_cache WHERE raw_hash = 'sha-raw';"), 1)
        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM uploaded_assets WHERE asset_id = 'unchanged-raw-pair';"), 2)
        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM upload_jobs WHERE asset_id = 'unchanged-raw-pair';"), 2)
        XCTAssertEqual(background.loadChangeToken(), Data([1]))
        XCTAssertTrue(queuedIds().contains(id))
    }

    func testBackgroundInvalidatesVersionChangedWithinOneSecond() {
        let id = "adjacent-version"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id, primaryHash: "sha-old",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100)
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: id, resourceType: "jpeg",
            filename: "a.jpg", immichId: "remote-id"
        )
        let background = BackgroundUploadDatabase(testingDatabasePath: databaseURL.path)
        let summary = background.commitPersistentChange(
            insertedAssetIds: [], updatedAssetIds: [id], deletedAssetIds: [],
            updatedAssetModificationDates: [id: Date(timeIntervalSince1970: 100.5)],
            tokenData: Data([3])
        )

        XCTAssertEqual(summary?.retainedVersions, 0)
        XCTAssertEqual(summary?.invalidatedVersions, 1)
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: id))
        XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: id))
        XCTAssertEqual(background.loadChangeToken(), Data([3]))
    }

    func testForegroundInvalidatesVersionChangedWithinOneSecond() {
        let id = "short-edit"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id, primaryHash: "sha-old",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100)
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: id, resourceType: "jpeg",
            filename: "a.jpg", immichId: "remote-id"
        )

        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(
                localIdentifier: id, modificationDate: Date(timeIntervalSince1970: 100.5)
            )],
            pendingIdentifiers: [id],
            deletedIdentifiers: [],
            tokenData: Data([5]),
            bootstrap: false
        ))
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: id))
        XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: id))
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), [id])
    }

    func testForegroundBootstrapInvalidatesShortVersionChange() {
        let id = "bootstrap-edit"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id, primaryHash: "sha-old",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100)
        )
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(
                localIdentifier: id, modificationDate: Date(timeIntervalSince1970: 100.5)
            )],
            pendingIdentifiers: [id],
            deletedIdentifiers: [],
            tokenData: Data([6]),
            bootstrap: true
        ))
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: id))
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), [id])
    }

    func testBackgroundPhotoKitInvalidatesChangedAndUnversionedAssets() {
        let ids = ["edited", "legacy", "missing-date", "receipt-only"]
        for id in ids {
            if id != "receipt-only" {
                hashRepository.saveMultiResourceHashCache(
                    localIdentifier: id, primaryHash: "sha-\(id)",
                    rawHash: nil, hasRAW: false,
                    modificationDate: id == "legacy" ? nil : Date(timeIntervalSince1970: 100)
                )
            }
            uploadRepository.recordUploadedAsset(
                localIdentifier: id, resourceType: "jpeg", filename: "image.jpg", immichId: "remote"
            )
        }
        execute("""
            INSERT INTO upload_jobs (asset_id, resource_type, filename, status, created_at, updated_at)
            VALUES ('edited', 'jpeg', 'image.jpg', 'completed', 0, 0),
                   ('legacy', 'jpeg', 'image.jpg', 'completed', 0, 0);
        """)

        let background = BackgroundUploadDatabase(testingDatabasePath: databaseURL.path)
        let summary = background.commitPersistentChange(
            insertedAssetIds: [], updatedAssetIds: Set(ids), deletedAssetIds: [],
            updatedAssetModificationDates: [
                "edited": Date(timeIntervalSince1970: 120),
                "legacy": Date(timeIntervalSince1970: 100),
                "receipt-only": Date(timeIntervalSince1970: 100)
            ],
            tokenData: Data([2])
        )

        XCTAssertEqual(summary?.retainedVersions, 0)
        XCTAssertEqual(summary?.invalidatedVersions, ids.count)
        for id in ids {
            XCTAssertNil(hashRepository.getHashCache(localIdentifier: id))
            XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: id))
            XCTAssertTrue(queuedIds().contains(id))
        }
        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM upload_jobs WHERE status = 'completed';"), 0)
        XCTAssertEqual(background.loadChangeToken(), Data([2]))
    }

    func testBackgroundPhotoKitInvalidationFailureRollsBackTokenAndRecords() {
        let id = "edited"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id, primaryHash: "sha-original", rawHash: nil,
            hasRAW: false, modificationDate: Date(timeIntervalSince1970: 100)
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: id, resourceType: "jpeg", filename: "image.jpg", immichId: "remote"
        )
        let background = BackgroundUploadDatabase(testingDatabasePath: databaseURL.path)
        XCTAssertNotNil(background.commitPersistentChange(
            insertedAssetIds: [], updatedAssetIds: [], deletedAssetIds: [],
            updatedAssetModificationDates: [:], tokenData: Data([1])
        ))
        execute("""
            CREATE TRIGGER reject_changed_hash
            BEFORE DELETE ON hash_cache
            BEGIN SELECT RAISE(ABORT, 'forced failure'); END;
        """)

        XCTAssertNil(background.commitPersistentChange(
            insertedAssetIds: [], updatedAssetIds: [id], deletedAssetIds: [],
            updatedAssetModificationDates: [id: Date(timeIntervalSince1970: 120)],
            tokenData: Data([2])
        ))

        XCTAssertEqual(background.loadChangeToken(), Data([1]))
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: id))
        XCTAssertTrue(uploadRepository.isAnyResourceUploaded(localIdentifier: id))
        XCTAssertFalse(queuedIds().contains(id))
    }

    func testBackgroundPhotoKitRehashDoesNotKeepOldCompletedJobsWithoutReceipts() {
        let id = "foreground-rehashed"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id, primaryHash: "sha-new",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 120)
        )
        execute("""
            INSERT INTO upload_jobs (asset_id, resource_type, filename, status, created_at, updated_at)
            VALUES ('foreground-rehashed', 'jpeg', 'image.jpg', 'completed', 0, 0);
        """)
        let background = BackgroundUploadDatabase(testingDatabasePath: databaseURL.path)
        let summary = background.commitPersistentChange(
            insertedAssetIds: [], updatedAssetIds: [id], deletedAssetIds: [],
            updatedAssetModificationDates: [id: Date(timeIntervalSince1970: 120)],
            tokenData: Data([1])
        )
        XCTAssertEqual(summary?.retainedVersions, 1)
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: id))
        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM upload_jobs WHERE asset_id = 'foreground-rehashed';"), 0)
    }

    func testBackgroundExtensionFallsBackWhenHostHasNotMigratedVersionColumn() {
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "legacy", primaryHash: "sha-old",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100)
        )
        // Simulate an old app-group database that the host has not migrated.
        execute("ALTER TABLE hash_cache DROP COLUMN asset_modification_date;")
        let background = BackgroundUploadDatabase(testingDatabasePath: databaseURL.path)
        let summary = background.commitPersistentChange(
            insertedAssetIds: [], updatedAssetIds: ["legacy"], deletedAssetIds: [],
            updatedAssetModificationDates: ["legacy": Date(timeIntervalSince1970: 100)],
            tokenData: Data([1])
        )
        XCTAssertEqual(summary?.retainedVersions, 0)
        XCTAssertEqual(summary?.invalidatedVersions, 1)
        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'legacy';"), 0)
        XCTAssertEqual(background.loadChangeToken(), Data([1]))
    }

    private func sqlCount(_ sql: String) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            XCTFail("Could not prepare count query")
            return -1
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            XCTFail("Could not read count query")
            return -1
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func hexBlob(_ sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        return data.map { String(format: "%02X", $0) }.joined()
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
