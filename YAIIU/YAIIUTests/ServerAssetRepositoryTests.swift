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

    func testPhotoAssetSnapshotDiagnosticSummaryIncludesStableMetadata() {
        let snapshot = PhotoAssetSnapshot(
            localIdentifier: "asset-1",
            modificationDate: Date(timeIntervalSince1970: 200),
            isHidden: false,
            creationDate: Date(timeIntervalSince1970: 100),
            isFavorite: true,
            hasAdjustments: false,
            adjustmentFormatIdentifier: nil,
            resources: [
                PhotoAssetResourceSnapshot(
                    typeDescription: "fullSizePhoto",
                    uniformTypeIdentifier: "public.jpeg",
                    originalFilename: "photo.jpg",
                    fileSize: 1234
                )
            ]
        )

        let summary = snapshot.diagnosticSummary(
            storedModificationDate: Date(timeIntervalSince1970: 100)
        )

        XCTAssertTrue(summary.contains("asset=asset-1"))
        XCTAssertTrue(summary.contains("storedModificationDate=100.0"))
        XCTAssertTrue(summary.contains("currentModificationDate=200.0"))
        XCTAssertTrue(summary.contains("creationDate=100.0"))
        XCTAssertTrue(summary.contains("favorite=true"))
        XCTAssertTrue(summary.contains("hasAdjustments=false"))
        XCTAssertTrue(summary.contains("public.jpeg/photo.jpg/1234"))
    }

    func testUploadReceiptQueriesMatchIdentifierAndResourceType() {
        execute("""
            INSERT INTO uploaded_assets
              (asset_id, resource_type, filename, immich_id, uploaded_at)
            VALUES ('receipt-identifier-with-a-long-lived-value/L0/001', 'jpeg',
                    'image.jpg', 'remote-receipt', 100);
            """)
        let identifier = "receipt-identifier-with-a-long-lived-value/L0/001"

        XCTAssertTrue(uploadRepository.isAnyResourceUploaded(localIdentifier: identifier))
        XCTAssertTrue(uploadRepository.isAssetUploaded(localIdentifier: identifier, resourceType: "jpeg"))
        XCTAssertFalse(uploadRepository.isAssetUploaded(localIdentifier: identifier, resourceType: "raw"))
        XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: "missing-receipt"))
        XCTAssertEqual(uploadRepository.getUploadRecords(for: identifier).map(\.filename), ["image.jpg"])
    }

    func testDeletingUploadReceiptRemovesOnlyMatchingIdentifier() {
        execute("""
            INSERT INTO uploaded_assets
              (asset_id, resource_type, filename, immich_id, uploaded_at)
            VALUES ('receipt-to-delete-with-a-long-identifier/L0/001', 'jpeg', 'image.jpg', 'remote', 100),
                   ('keep-this-receipt', 'jpeg', 'other.jpg', 'other-remote', 100);
            """)

        uploadRepository.deleteUploadRecord(for: "receipt-to-delete-with-a-long-identifier/L0/001")

        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM uploaded_assets;"), 1)
        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM uploaded_assets WHERE asset_id = 'keep-this-receipt';"), 1)
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


    func testBatchVerificationMatchesPrimaryAndRAWAndQueuesMissingResources() {
        XCTAssertTrue(repository.saveServerAssets([
            ServerAssetRecord(immichId: "remote-primary", checksum: "converted",
                              sourceChecksum: "source-primary", ownerId: "owner-1"),
            ServerAssetRecord(immichId: "remote-raw", checksum: "raw-present", ownerId: "owner-1"),
            ServerAssetRecord(immichId: "foreign", checksum: "foreign-sha", ownerId: "owner-2")
        ]))
        execute("""
            INSERT INTO hash_cache
              (asset_id, sha1_hash, raw_hash, has_raw, calculated_at)
            VALUES ('source', 'source-primary', NULL, 0, 0),
                   ('raw-missing', 'source-primary', 'raw-absent', 1, 0),
                   ('raw-present', 'source-primary', 'raw-present', 1, 0),
                   ('absent', 'not-on-server', NULL, 0, 0),
                   ('foreign', 'foreign-sha', NULL, 0, 0);
            """)
        let ids = ["source", "raw-missing", "raw-present", "absent", "foreign"]
        let candidates = hashRepository.verifyHashCacheBatch(identifiers: ids, ownerId: "owner-1")
        XCTAssertNotNil(candidates)
        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM hash_cache WHERE checked_at IS NOT NULL;"), 5)
        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM hash_cache WHERE is_on_server = 1;"), 4)
        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM hash_cache WHERE has_raw = 1 AND raw_on_server = 1;"), 1)
        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM background_upload_queue;"), 2)
        XCTAssertEqual(Set(candidates?.map(\.assetId) ?? []), ["source", "raw-missing", "raw-present"])
        XCTAssertFalse(candidates?.contains(where: { $0.assetId == "foreign" }) ?? true)
    }

    func testBatchVerificationKeepsCheckedAndOutsideRowsAndUsesUploadReceipt() {
        execute("""
            INSERT INTO hash_cache (asset_id, sha1_hash, calculated_at, checked_at, is_on_server)
            VALUES ('pending', 'no-match', 0, NULL, 0),
                   ('already-checked', 'no-match', 0, 123, 1),
                   ('outside-batch', 'no-match', 0, NULL, 0);
            INSERT INTO uploaded_assets (asset_id, resource_type, filename, immich_id, uploaded_at)
            VALUES ('pending', 'primary', 'image.jpg', 'uploaded', 10);
            """)
        let candidates = hashRepository.verifyHashCacheBatch(
            identifiers: ["pending", "already-checked"], ownerId: "owner-1"
        )
        XCTAssertNotNil(candidates)
        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM hash_cache WHERE asset_id='pending' AND is_on_server=1 AND checked_at IS NOT NULL;"), 1)
        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM hash_cache WHERE asset_id='already-checked' AND is_on_server=1 AND checked_at=123;"), 1)
        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM hash_cache WHERE asset_id='outside-batch' AND checked_at IS NULL;"), 1)
    }

    func testBatchMetadataCandidatePrefersReceiptAndFiltersForeignOwner() {
        XCTAssertTrue(repository.saveServerAssets([
            ServerAssetRecord(immichId: "by-hash", checksum: "checksum", iCloudId: "cloud-old", ownerId: "owner-1"),
            ServerAssetRecord(immichId: "receipt-remote", checksum: "elsewhere", iCloudId: "cloud-new", ownerId: "owner-1"),
            ServerAssetRecord(immichId: "other-owner", checksum: "other-checksum", iCloudId: nil, ownerId: "owner-2")
        ]))
        execute("""
            INSERT INTO hash_cache (asset_id, sha1_hash, calculated_at)
            VALUES ('receipt-asset', 'checksum', 0), ('other-asset', 'other-checksum', 0);
            INSERT INTO uploaded_assets (asset_id, resource_type, filename, immich_id, uploaded_at)
            VALUES ('receipt-asset', 'primary', 'photo.jpg', 'receipt-remote', 100);
            """)
        let candidates = hashRepository.verifyHashCacheBatch(
            identifiers: ["receipt-asset", "other-asset"], ownerId: "owner-1"
        )
        XCTAssertEqual(candidates?.count, 1)
        XCTAssertEqual(candidates?.first?.immichId, "receipt-remote")
        XCTAssertEqual(candidates?.first?.serverICloudId, "cloud-new")
    }

    func testBatchMetadataCandidatePrefersLivePhotoImageOverVideoReceipt() {
        XCTAssertTrue(repository.saveServerAssets([
            ServerAssetRecord(immichId: "live-image", checksum: "image-hash",
                              iCloudId: "image-cloud", ownerId: "owner-1"),
            ServerAssetRecord(immichId: "live-video", checksum: "video-hash",
                              iCloudId: "video-cloud", ownerId: "owner-1")
        ]))
        execute("""
            INSERT INTO hash_cache (asset_id, sha1_hash, calculated_at)
            VALUES ('live-photo', 'image-hash', 0),
                   ('video-only', 'video-hash', 0);
            INSERT INTO uploaded_assets
                (asset_id, resource_type, filename, immich_id, uploaded_at)
            VALUES ('live-photo', 'jpeg', 'image.heic', 'live-image', 100),
                   ('live-photo', 'video', 'image.mov', 'live-video', 101),
                   ('video-only', 'video', 'standalone.mov', 'live-video', 102);
            """)
        let candidates = hashRepository.verifyHashCacheBatch(
            identifiers: ["live-photo", "video-only"], ownerId: "owner-1"
        )
        XCTAssertEqual(candidates?.count, 2)
        let live = candidates?.first(where: { $0.assetId == "live-photo" })
        XCTAssertEqual(live?.immichId, "live-image")
        XCTAssertEqual(live?.serverICloudId, "image-cloud")
        let video = candidates?.first(where: { $0.assetId == "video-only" })
        XCTAssertEqual(video?.immichId, "live-video")
        XCTAssertEqual(video?.serverICloudId, "video-cloud")
    }

    func testMetadataRetryInvalidatesOnlyRequestedLocalHashes() async {
        execute("""
            INSERT INTO hash_cache (asset_id, sha1_hash, calculated_at, checked_at)
            VALUES ('first', 'h1', 0, 10),
                   ('second', 'h2', 0, 11),
                   ('third', 'h3', 0, 12);
            """)
        XCTAssertTrue(hashRepository.invalidateHashChecksForLocalIdentifiers(["first", "third", "first"]))
        let dirty = await uncheckedHashIds()
        XCTAssertEqual(Set(dirty), ["first", "third"])
        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM hash_cache WHERE asset_id='second' AND checked_at=11;"), 1)
        XCTAssertTrue(hashRepository.invalidateHashChecksForLocalIdentifiers([]))
        let stillDirty = await uncheckedHashIds()
        XCTAssertEqual(Set(stillDirty), ["first", "third"])
    }

    func testMetadataRetrySpansSqliteParameterBatches() {
        let identifiers = (0..<625).map { "retry-\($0)" }
        connection.dbQueue.sync {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(
                connection.db,
                "INSERT INTO hash_cache (asset_id, sha1_hash, calculated_at, checked_at) VALUES (?, ?, 0, 10);",
                -1, &statement, nil
            ), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for id in identifiers {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, id, -1, transient)
                sqlite3_bind_text(statement, 2, id, -1, transient)
                XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            }
        }
        XCTAssertTrue(hashRepository.invalidateHashChecksForLocalIdentifiers(identifiers))
        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM hash_cache WHERE checked_at IS NULL;"), 625)
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
            INSERT INTO hash_cache (asset_id, sha1_hash, calculated_at, checked_at, asset_modification_date)
            VALUES ('still-local', 'sha-a', 0, 100, 100), ('photo-deleted', 'sha-b', 0, 100, 100);
        """)
        uploadRepository.recordUploadedAsset(
            localIdentifier: "photo-deleted", resourceType: "primary",
            filename: "deleted.jpg", immichId: "remote-asset"
        )
        hashRepository.resetCacheForModifiedAssets(
            snapshots: [PhotoAssetSnapshot(
                localIdentifier: "still-local", modificationDate: Date(timeIntervalSince1970: 100)
            )],
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
            INSERT INTO hash_cache (asset_id, sha1_hash, calculated_at, checked_at, asset_modification_date)
            VALUES ('visible', 'sha-visible', 0, 100, 100),
                   ('hidden', 'sha-hidden', 0, 100, NULL),
                   ('deleted', 'sha-deleted', 0, 100, NULL);
            INSERT INTO background_upload_queue (asset_id, enqueued_at)
            VALUES ('visible', 1), ('hidden', 1), ('deleted', 1), ('queue-only-deleted', 1);
            INSERT INTO upload_jobs (asset_id, resource_type, filename, status, created_at, updated_at)
            VALUES ('deleted', 'primary', 'old.jpg', 'pending', 0, 0),
                   ('queue-only-deleted', 'raw', 'old.dng', 'failed', 0, 0),
                   ('hidden', 'primary', 'hidden.jpg', 'pending', 0, 0);
        """)
        let fullSnapshots = [
            PhotoAssetSnapshot(localIdentifier: "visible", modificationDate: Date(timeIntervalSince1970: 100)),
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
            modificationDate: Date(timeIntervalSince1970: 100),
            resourceFingerprint: "resource-v1"
        )
        execute("INSERT INTO background_upload_queue (asset_id, enqueued_at) VALUES ('modified', 1);")
        hashRepository.resetCacheForModifiedAssets(
            snapshots: [
                PhotoAssetSnapshot(
                    localIdentifier: "modified",
                    modificationDate: Date(timeIntervalSince1970: 110),
                    resourceFingerprint: "resource-v2"
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


    // MARK: - Persistent Local PhotoKit Inventory

    func testLocalPhotoCountRequiresCompletedBaseline() {
        XCTAssertFalse(hashRepository.isLocalPhotoInventoryReady())
        XCTAssertNil(hashRepository.countNotUploadedVisibleAssets())

        XCTAssertTrue(hashRepository.beginLocalPhotoInventoryBootstrap())
        XCTAssertTrue(hashRepository.appendLocalPhotoInventoryBatch([
            (identifier: "visible", isHidden: false),
            (identifier: "hidden", isHidden: true)
        ]))
        // An interrupted baseline must NEVER expose its partial count.
        XCTAssertNil(hashRepository.countNotUploadedVisibleAssets())
        XCTAssertTrue(hashRepository.finishLocalPhotoInventoryBootstrap())
        XCTAssertTrue(hashRepository.isLocalPhotoInventoryReady())
        XCTAssertEqual(hashRepository.countNotUploadedVisibleAssets(), 1)

        XCTAssertTrue(hashRepository.beginLocalPhotoInventoryBootstrap())
        XCTAssertNil(hashRepository.countNotUploadedVisibleAssets())
        XCTAssertTrue(hashRepository.appendLocalPhotoInventoryBatch([
            (identifier: "new-only", isHidden: false)
        ]))
        XCTAssertTrue(hashRepository.finishLocalPhotoInventoryBootstrap())
        XCTAssertEqual(hashRepository.countNotUploadedVisibleAssets(), 1)
        XCTAssertEqual(ids(for: "SELECT asset_id FROM local_photo_assets;"), ["new-only"])
    }

    func testInventoryRemainsUnreadyWhilePersistedDeltaReplays() {
        // This models an upgraded database with an old PhotoKit cursor.
        XCTAssertTrue(hashRepository.beginLocalPhotoInventoryBootstrap())
        XCTAssertTrue(hashRepository.appendLocalPhotoInventoryBatch([
            (identifier: "kept", isHidden: false),
            (identifier: "deleted", isHidden: false)
        ]))
        XCTAssertFalse(hashRepository.isLocalPhotoInventoryReady())
        XCTAssertNil(hashRepository.countNotUploadedVisibleAssets())

        // A committed journal window must not implicitly publish inventory
        // readiness, even if it persisted its own new cursor successfully.
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(
                localIdentifier: "inserted", modificationDate: nil
            )],
            pendingIdentifiers: ["inserted"],
            deletedIdentifiers: ["deleted"],
            tokenData: Data([4]), bootstrap: false
        ))
        XCTAssertFalse(hashRepository.isLocalPhotoInventoryReady())
        XCTAssertNil(hashRepository.countNotUploadedVisibleAssets())
        XCTAssertEqual(hashRepository.loadForegroundPhotoToken(), Data([4]))

        XCTAssertTrue(hashRepository.finishLocalPhotoInventoryBootstrap())
        XCTAssertEqual(hashRepository.countNotUploadedVisibleAssets(), 2)
        XCTAssertEqual(ids(for: "SELECT asset_id FROM local_photo_assets ORDER BY asset_id;"),
                       ["inserted", "kept"])
        XCTAssertTrue(hashRepository.invalidateLocalPhotoInventory())
        XCTAssertNil(hashRepository.countNotUploadedVisibleAssets())
    }

    func testRecoveredPendingPhotoCreatesVisibleInventoryEvenWithoutFingerprint() {
        XCTAssertTrue(hashRepository.beginLocalPhotoInventoryBootstrap())
        XCTAssertTrue(hashRepository.finishLocalPhotoInventoryBootstrap())
        execute("INSERT INTO foreground_photo_pending_assets(asset_id) VALUES ('late-photo');")
        XCTAssertEqual(hashRepository.countNotUploadedVisibleAssets(), 0)
        let retained = hashRepository.reconcileForegroundPendingAssets(snapshots: [
            PhotoAssetSnapshot(localIdentifier: "late-photo", modificationDate: nil)
        ])
        XCTAssertEqual(retained, ["late-photo"])
        XCTAssertEqual(hashRepository.countNotUploadedVisibleAssets(), 1)
        XCTAssertEqual(ids(for: "SELECT asset_id FROM local_photo_assets;"), ["late-photo"])
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), ["late-photo"])
    }

    func testRecoveredHiddenPhotoHidesInventoryAndAcknowledgesPending() {
        XCTAssertTrue(hashRepository.beginLocalPhotoInventoryBootstrap())
        XCTAssertTrue(hashRepository.appendLocalPhotoInventoryBatch([
            (identifier: "late-hidden", isHidden: false)
        ]))
        XCTAssertTrue(hashRepository.finishLocalPhotoInventoryBootstrap())
        execute("INSERT INTO foreground_photo_pending_assets(asset_id) VALUES ('late-hidden');")
        XCTAssertEqual(hashRepository.countNotUploadedVisibleAssets(), 1)

        XCTAssertTrue(hashRepository.discardForegroundPendingIdentifiers(["late-hidden"]))
        XCTAssertEqual(hashRepository.countNotUploadedVisibleAssets(), 0)
        XCTAssertTrue(hashRepository.getPendingForegroundPhotoIdentifiers().isEmpty)
        XCTAssertEqual(sqlCount(
            "SELECT COUNT(*) FROM local_photo_assets WHERE asset_id = 'late-hidden' AND is_hidden = 1;"
        ), 1)
    }

    func testFailedHiddenAcknowledgementRollsBackInventory() {
        XCTAssertTrue(hashRepository.beginLocalPhotoInventoryBootstrap())
        XCTAssertTrue(hashRepository.appendLocalPhotoInventoryBatch([
            (identifier: "hidden-pending", isHidden: false)
        ]))
        XCTAssertTrue(hashRepository.finishLocalPhotoInventoryBootstrap())
        execute("""
            INSERT INTO foreground_photo_pending_assets(asset_id) VALUES ('hidden-pending');
            CREATE TRIGGER fail_hidden_pending_delete
            BEFORE DELETE ON foreground_photo_pending_assets
            BEGIN SELECT RAISE(ABORT, 'simulated deletion failure'); END;
            """)
        XCTAssertFalse(hashRepository.discardForegroundPendingIdentifiers(["hidden-pending"]))
        XCTAssertEqual(hashRepository.countNotUploadedVisibleAssets(), 1)
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), ["hidden-pending"])
        XCTAssertEqual(sqlCount(
            "SELECT COUNT(*) FROM local_photo_assets WHERE asset_id = 'hidden-pending' AND is_hidden = 0;"
        ), 1)
    }

    func testSQLiteLocalCountMatchesPendingReceiptsAndRAWPairSemantics() {
        XCTAssertTrue(hashRepository.beginLocalPhotoInventoryBootstrap())
        let ids = ["primary-done", "raw-partial", "raw-receipt", "receipt", "pending", "new", "hidden"]
        XCTAssertTrue(hashRepository.appendLocalPhotoInventoryBatch(
            ids.map { (identifier: $0, isHidden: $0 == "hidden") }
        ))
        XCTAssertTrue(hashRepository.finishLocalPhotoInventoryBootstrap())
        execute("""
            INSERT INTO hash_cache
                (asset_id, sha1_hash, calculated_at, checked_at, is_on_server, has_raw, raw_on_server)
            VALUES
                ('primary-done', 'sha-1', 0, 100, 1, 0, 0),
                ('raw-partial', 'sha-2', 0, 100, 1, 1, 0),
                ('raw-receipt', 'sha-3', 0, 100, 1, 1, 0),
                ('receipt', 'sha-4', 0, 100, 0, 0, 0),
                ('pending', 'sha-5', 0, NULL, 1, 0, 0);
            INSERT INTO uploaded_assets
                (asset_id, resource_type, filename, immich_id, uploaded_at)
            VALUES
                ('raw-receipt', 'raw', 'a.dng', 'immich-raw', 10),
                ('receipt', 'jpeg', 'a.jpeg', 'immich-primary', 10);
            INSERT INTO server_assets_cache(immich_id, checksum, synced_at)
            VALUES ('remote', 'remote-sha', 10);
            """)
        // raw-partial, pending (unchecked with a server cache), new (no hash).
        XCTAssertEqual(hashRepository.countNotUploadedVisibleAssets(), 3)
        execute("DELETE FROM server_assets_cache;")
        XCTAssertEqual(hashRepository.countNotUploadedVisibleAssets(), 2)
        execute("UPDATE hash_cache SET raw_on_server = 1 WHERE asset_id = 'raw-partial';")
        XCTAssertEqual(hashRepository.countNotUploadedVisibleAssets(), 1)
    }

    func testLegacyNullableHashFlagsCountAsNotUploaded() {
        XCTAssertTrue(hashRepository.beginLocalPhotoInventoryBootstrap())
        XCTAssertTrue(hashRepository.appendLocalPhotoInventoryBatch([
            (identifier: "legacy", isHidden: false)
        ]))
        XCTAssertTrue(hashRepository.finishLocalPhotoInventoryBootstrap())
        execute("""
            INSERT INTO hash_cache(asset_id, sha1_hash, calculated_at,
                                   checked_at, is_on_server, has_raw)
            VALUES ('legacy', 'old-hash', 0, 1, NULL, NULL);
            """)
        XCTAssertEqual(hashRepository.countNotUploadedVisibleAssets(), 1)
    }

    func testLocalInventoryAndPhotoKitDeltaCommitTogether() {
        let initial = [
            PhotoAssetSnapshot(localIdentifier: "visible", modificationDate: nil),
            PhotoAssetSnapshot(localIdentifier: "deleted", modificationDate: nil),
            PhotoAssetSnapshot(localIdentifier: "hidden", modificationDate: nil, isHidden: true)
        ]
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: initial,
            pendingIdentifiers: ["visible", "deleted"],
            deletedIdentifiers: [], tokenData: Data([1]), bootstrap: true
        ))
        XCTAssertTrue(hashRepository.isLocalPhotoInventoryReady())
        XCTAssertEqual(hashRepository.countNotUploadedVisibleAssets(), 2)

        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [
                PhotoAssetSnapshot(localIdentifier: "visible", modificationDate: nil, isHidden: true),
                PhotoAssetSnapshot(localIdentifier: "new", modificationDate: nil)
            ],
            pendingIdentifiers: ["visible", "new"],
            deletedIdentifiers: ["deleted"], tokenData: Data([2]), bootstrap: false
        ))
        XCTAssertEqual(hashRepository.countNotUploadedVisibleAssets(), 1)
        XCTAssertEqual(ids(for: "SELECT asset_id FROM local_photo_assets ORDER BY asset_id;"),
                       ["hidden", "new", "visible"])
        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM local_photo_assets WHERE is_hidden = 1;"), 2)
        XCTAssertEqual(hashRepository.loadForegroundPhotoToken(), Data([2]))
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

    func testForegroundJournalBatchCoalescesRepeatedUpdatesAndUsesLastToken() {
        var batch = ForegroundPhotoChangeBatch()
        batch.append(affected: ["photo-a"], deleted: [], tokenData: Data([1]))
        batch.append(affected: ["photo-a", "photo-b"], deleted: [], tokenData: Data([2]))
        batch.append(affected: ["photo-b"], deleted: [], tokenData: Data([3]))

        XCTAssertEqual(batch.affectedIdentifiers, Set(["photo-a", "photo-b"]))
        XCTAssertTrue(batch.deletedIdentifiers.isEmpty)
        XCTAssertEqual(batch.changeCount, 3)
        XCTAssertEqual(batch.tokenData, Data([3]))
        XCTAssertFalse(batch.shouldFlush)

        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "photo-a", primaryHash: "previous",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100)
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "photo-a", resourceType: "jpeg",
            filename: "a.jpg", immichId: "remote-a"
        )
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [
                PhotoAssetSnapshot(localIdentifier: "photo-a", modificationDate: Date(timeIntervalSince1970: 100)),
                PhotoAssetSnapshot(localIdentifier: "photo-b", modificationDate: Date(timeIntervalSince1970: 150))
            ],
            pendingIdentifiers: batch.affectedIdentifiers,
            deletedIdentifiers: batch.deletedIdentifiers,
            tokenData: batch.tokenData!,
            bootstrap: false
        ))
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: "photo-a"))
        XCTAssertTrue(uploadRepository.isAnyResourceUploaded(localIdentifier: "photo-a"))
        XCTAssertEqual(
            Set(hashRepository.getPendingForegroundPhotoIdentifiers()),
            Set(["photo-a", "photo-b"])
        )
        XCTAssertEqual(hashRepository.loadForegroundPhotoToken(), Data([3]))
    }

    func testForegroundJournalBatchFlushesEvenWhenOnlyJobEventsOccur() {
        var batch = ForegroundPhotoChangeBatch()
        for i in 0..<ForegroundPhotoChangeBatch.maxChangeBatches {
            batch.append(affected: [], deleted: [], tokenData: Data([UInt8(i)]))
        }
        XCTAssertTrue(batch.shouldFlush)
        XCTAssertTrue(batch.affectedIdentifiers.isEmpty)
        XCTAssertTrue(batch.deletedIdentifiers.isEmpty)
        XCTAssertEqual(batch.changeCount, ForegroundPhotoChangeBatch.maxChangeBatches)

        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [],
            pendingIdentifiers: batch.affectedIdentifiers,
            deletedIdentifiers: batch.deletedIdentifiers,
            tokenData: batch.tokenData!,
            bootstrap: false
        ))
        XCTAssertEqual(hashRepository.loadForegroundPhotoToken(), Data([127]))
        XCTAssertTrue(hashRepository.getPendingForegroundPhotoIdentifiers().isEmpty)
        batch.reset()
        XCTAssertFalse(batch.hasPending)
        XCTAssertEqual(batch.changeCount, 0)
    }

    func testForegroundJournalDeletionAndReinsertionCannotReuseOldReceipt() {
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "same-local-id", primaryHash: "old-hash",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100)
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "same-local-id", resourceType: "jpeg",
            filename: "old.jpg", immichId: "old-remote"
        )
        var window = ForegroundPhotoChangeBatch()
        window.append(affected: ["same-local-id"], deleted: [], tokenData: Data([10]))
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(
                localIdentifier: "same-local-id", modificationDate: Date(timeIntervalSince1970: 100)
            )],
            pendingIdentifiers: window.affectedIdentifiers,
            deletedIdentifiers: window.deletedIdentifiers,
            tokenData: window.tokenData!, bootstrap: false
        ))
        XCTAssertTrue(uploadRepository.isAnyResourceUploaded(localIdentifier: "same-local-id"))
        XCTAssertTrue(window.requiresFlushBefore(deleting: ["same-local-id"]))

        window.reset()
        window.append(affected: [], deleted: ["same-local-id"], tokenData: Data([11]))
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [], pendingIdentifiers: window.affectedIdentifiers,
            deletedIdentifiers: window.deletedIdentifiers,
            tokenData: window.tokenData!, bootstrap: false
        ))
        XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: "same-local-id"))

        window.reset()
        window.append(affected: ["same-local-id"], deleted: [], tokenData: Data([12]))
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(
                localIdentifier: "same-local-id", modificationDate: Date(timeIntervalSince1970: 100)
            )],
            pendingIdentifiers: window.affectedIdentifiers,
            deletedIdentifiers: window.deletedIdentifiers,
            tokenData: window.tokenData!, bootstrap: false
        ))
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: "same-local-id"))
        XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: "same-local-id"))
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), ["same-local-id"])
        XCTAssertEqual(hashRepository.loadForegroundPhotoToken(), Data([12]))
    }

    func testForegroundJournalBatchBoundsUniqueAssetCountAndKeepsDeletionBarrier() {
        var batch = ForegroundPhotoChangeBatch()
        for i in 0..<ForegroundPhotoChangeBatch.maxChangedIdentifiers {
            batch.append(affected: ["id-\(i)"], deleted: [], tokenData: Data([2]))
        }
        XCTAssertTrue(batch.shouldFlush)
        XCTAssertEqual(batch.affectedIdentifiers.count, ForegroundPhotoChangeBatch.maxChangedIdentifiers)
        XCTAssertTrue(batch.requiresFlushBefore(deleting: ["id-1"]))
        XCTAssertFalse(batch.requiresFlushBefore(deleting: []))

        batch.reset()
        batch.append(affected: ["reinserted"], deleted: [], tokenData: Data([3]))
        XCTAssertTrue(batch.requiresFlushBefore(deleting: ["reinserted"]))
        // The caller must commit the first window before processing a delete.
        batch.reset()
        batch.append(affected: [], deleted: ["reinserted"], tokenData: Data([4]))
        XCTAssertTrue(batch.deletedIdentifiers.contains("reinserted"))
        XCTAssertFalse(batch.affectedIdentifiers.contains("reinserted"))
    }

    // MARK: - Phase 2: Foreground PhotoKit Change Journal

    func testForegroundBootstrapQueuesOnlyUnhashedVisiblePhotos() {
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "cached", primaryHash: "sha-cached",
            rawHash: nil, hasRAW: false, modificationDate: nil,
            resourceFingerprint: "resource-cached"
        )
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "hidden", primaryHash: "sha-hidden",
            rawHash: nil, hasRAW: false, modificationDate: nil
        )
        execute("INSERT INTO change_tokens(id, token_data, updated_at) VALUES (1, X'ABCD', 0);")
        let snapshots = [
            PhotoAssetSnapshot(
                localIdentifier: "cached",
                modificationDate: nil,
                resourceFingerprint: "resource-cached"
            ),
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
            modificationDate: Date(timeIntervalSince1970: 100),
            resourceFingerprint: "resource-v1"
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
                PhotoAssetSnapshot(
                    localIdentifier: "edited",
                    modificationDate: Date(timeIntervalSince1970: 120),
                    resourceFingerprint: "resource-v2"
                ),
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
            modificationDate: Date(timeIntervalSince1970: 100),
            resourceFingerprint: "resource-v1"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "favorite-changed", resourceType: "primary",
            filename: "a.jpg", immichId: "remote-id"
        )
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [
                PhotoAssetSnapshot(
                    localIdentifier: "favorite-changed",
                    modificationDate: Date(timeIntervalSince1970: 120),
                    resourceFingerprint: "resource-v1"
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

    func testForegroundMetadataUpdateRetainsHashWhenResourceFingerprintUnavailable() {
        let id = "icloud-refresh"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id,
            primaryHash: "sha-1",
            rawHash: nil,
            hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100),
            resourceFingerprint: "resource-v1"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: id,
            resourceType: "primary",
            filename: "video.mp4",
            immichId: "remote-id"
        )

        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(
                localIdentifier: id,
                modificationDate: Date(timeIntervalSince1970: 200),
                resourceFingerprint: nil
            )],
            pendingIdentifiers: [id],
            deletedIdentifiers: [],
            tokenData: Data([10]),
            bootstrap: false
        ))

        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: id))
        XCTAssertTrue(uploadRepository.isAnyResourceUploaded(localIdentifier: id))
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), [id])
    }

    func testForegroundResourceFingerprintChangeInvalidatesHash() {
        let id = "resource-edited"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id,
            primaryHash: "sha-old",
            rawHash: nil,
            hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100),
            resourceFingerprint: "resource-v1"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: id,
            resourceType: "primary",
            filename: "photo.jpg",
            immichId: "remote-id"
        )

        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(
                localIdentifier: id,
                modificationDate: Date(timeIntervalSince1970: 100),
                resourceFingerprint: "resource-v2"
            )],
            pendingIdentifiers: [id],
            deletedIdentifiers: [],
            tokenData: Data([11]),
            bootstrap: false
        ))

        XCTAssertNil(hashRepository.getHashCache(localIdentifier: id))
        XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: id))
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), [id])
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
            rawHash: nil, hasRAW: false, modificationDate: nil,
            resourceFingerprint: "resource-v1"
        )
        XCTAssertTrue(secondRepository.getPendingForegroundPhotoIdentifiers().isEmpty)
    }

    func testPendingPhotoKitEditRetainsLegacyHashUntilResourceEvidenceExists() {
        let id = "offline-edited"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id, primaryHash: "before-edit",
            rawHash: nil, hasRAW: false, modificationDate: nil
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: id, resourceType: "jpeg",
            filename: "original.jpg", immichId: "old-remote"
        )
        let pending = hashRepository.unversionedHashCacheRows()
        XCTAssertTrue(pending.contains { $0.localIdentifier == id })

        // Simulate replaying a persistent edit made while the app was closed.
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(
                localIdentifier: id,
                modificationDate: Date(timeIntervalSince1970: 300)
            )],
            pendingIdentifiers: [id], deletedIdentifiers: [],
            tokenData: Data([7]), bootstrap: false
        ))
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: id))
        XCTAssertTrue(uploadRepository.isAnyResourceUploaded(localIdentifier: id))
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), [id])

        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(
                localIdentifier: id,
                modificationDate: Date(timeIntervalSince1970: 300),
                resourceFingerprint: "resource-v1"
            )],
            pendingIdentifiers: [id], deletedIdentifiers: [],
            tokenData: Data([8]), bootstrap: false
        ))
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: id))
        XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: id))
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), [id])
    }

    func testImportThenPendingPhotoKitEditInvalidatesImportedChecksumWithResourceEvidence() {
        let id = "imported-while-offline"
        XCTAssertTrue(hashRepository.batchSaveHashCache(items: [
            (localIdentifier: id, sha1Hash: "old-import",
             fileSize: 0, syncStatus: "checked")
        ]))
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(
                localIdentifier: id,
                modificationDate: Date(timeIntervalSince1970: 500),
                resourceFingerprint: "resource-v1"
            )],
            pendingIdentifiers: [id], deletedIdentifiers: [],
            tokenData: Data([9]), bootstrap: false
        ))
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: id))
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), [id])
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

    func testPhotoKitBaselineBackfillIncludesMissingFingerprintAndPreservesHashState() {
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "missing-date-and-fingerprint", primaryHash: "primary-a",
            rawHash: "raw-a", hasRAW: true, modificationDate: nil
        )
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "missing-fingerprint", primaryHash: "primary-b",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 200)
        )
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "stale-fingerprint", primaryHash: "primary-c",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 200)
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "stale-fingerprint",
            resourceType: "jpeg",
            filename: "stale.jpg",
            immichId: "stale-remote"
        )

        let rows = hashRepository.hashCacheRowsNeedingPhotoKitBaseline()
        XCTAssertEqual(
            Set(rows.map(\.localIdentifier)),
            Set(["missing-date-and-fingerprint", "missing-fingerprint", "stale-fingerprint"])
        )

        XCTAssertEqual(hashRepository.backfillPhotoKitVersionMetadata([
            (
                localIdentifier: "missing-date-and-fingerprint",
                sha1Hash: "primary-a",
                modificationDate: Date(timeIntervalSince1970: 100),
                resourceFingerprint: "resource-a"
            ),
            (
                localIdentifier: "missing-fingerprint",
                sha1Hash: "primary-b",
                modificationDate: Date(timeIntervalSince1970: 200),
                resourceFingerprint: "resource-b"
            ),
            (
                localIdentifier: "stale-fingerprint",
                sha1Hash: "primary-c",
                modificationDate: Date(timeIntervalSince1970: 300),
                resourceFingerprint: "resource-c"
            )
        ]), 3)

        XCTAssertEqual(sqlCount("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'missing-date-and-fingerprint'
              AND asset_modification_date = 100
              AND asset_resource_fingerprint = 'resource-a'
              AND raw_hash = 'raw-a' AND has_raw = 1;
            """), 1)
        XCTAssertEqual(sqlCount("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'missing-fingerprint'
              AND asset_modification_date = 200
              AND asset_resource_fingerprint = 'resource-b';
            """), 1)
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: "stale-fingerprint"))
        XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: "stale-fingerprint"))
        XCTAssertEqual(sqlCount("""
            SELECT COUNT(*) FROM foreground_photo_pending_assets
            WHERE asset_id = 'stale-fingerprint';
            """), 1)
        XCTAssertTrue(hashRepository.hashCacheRowsNeedingPhotoKitBaseline().isEmpty)
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

    func testForegroundBootstrapRetainsLegacyHashUntilResourceEvidenceExists() {
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
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), [id])

        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(
                localIdentifier: id,
                modificationDate: Date(timeIntervalSince1970: 100),
                resourceFingerprint: "resource-v1"
            )],
            pendingIdentifiers: [id], deletedIdentifiers: [],
            tokenData: Data([2]), bootstrap: false
        ))
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: id))
        XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: id))
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), [id])
    }

    func testFallbackSnapshotRetainsUnknownVisibleVersion() {
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
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: "fallback-legacy"))
        XCTAssertTrue(uploadRepository.isAnyResourceUploaded(localIdentifier: "fallback-legacy"))
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: "hidden-legacy"))
    }

    func testUnknownModificationDateDoesNotInvalidateWithoutResourceEvidence() {
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
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: "legacy"))
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), ["legacy"])
    }

    func testBootstrapKeepsPendingAssetWhenResourceFingerprintIsUnavailable() {
        let id = "bootstrap-resource-unavailable"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id, primaryHash: "sha-legacy",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100),
            resourceFingerprint: "resource-v1"
        )
        execute("INSERT INTO foreground_photo_pending_assets(asset_id) VALUES ('bootstrap-resource-unavailable');")

        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(
                localIdentifier: id,
                modificationDate: Date(timeIntervalSince1970: 120),
                resourceFingerprint: nil
            )],
            pendingIdentifiers: [id], deletedIdentifiers: [],
            tokenData: Data([8]), bootstrap: true
        ))

        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), [id])
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: id))
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
            hasRAW: true, modificationDate: Date(timeIntervalSince1970: 100),
            resourceFingerprint: "resource-v1"
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
            updatedAssetResourceFingerprints: [id: "resource-v1"],
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
            modificationDate: Date(timeIntervalSince1970: 100),
            resourceFingerprint: "resource-v1"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: id, resourceType: "jpeg",
            filename: "a.jpg", immichId: "remote-id"
        )
        let background = BackgroundUploadDatabase(testingDatabasePath: databaseURL.path)
        let summary = background.commitPersistentChange(
            insertedAssetIds: [], updatedAssetIds: [id], deletedAssetIds: [],
            updatedAssetModificationDates: [id: Date(timeIntervalSince1970: 100.5)],
            updatedAssetResourceFingerprints: [id: "resource-v2"],
            tokenData: Data([3])
        )

        XCTAssertEqual(summary?.retainedVersions, 0)
        XCTAssertEqual(summary?.invalidatedVersions, 1)
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: id))
        XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: id))
        XCTAssertEqual(background.loadChangeToken(), Data([3]))
    }

    func testForegroundInvalidatesResourceFingerprintChangedWithinOneSecond() {
        let id = "short-edit"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id, primaryHash: "sha-old",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100),
            resourceFingerprint: "resource-v1"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: id, resourceType: "jpeg",
            filename: "a.jpg", immichId: "remote-id"
        )

        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(
                localIdentifier: id,
                modificationDate: Date(timeIntervalSince1970: 100.5),
                resourceFingerprint: "resource-v2"
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

    func testForegroundBootstrapInvalidatesResourceFingerprintChange() {
        let id = "bootstrap-edit"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id, primaryHash: "sha-old",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100),
            resourceFingerprint: "resource-v1"
        )
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(
                localIdentifier: id,
                modificationDate: Date(timeIntervalSince1970: 100.5),
                resourceFingerprint: "resource-v2"
            )],
            pendingIdentifiers: [id],
            deletedIdentifiers: [],
            tokenData: Data([6]),
            bootstrap: true
        ))
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: id))
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), [id])
    }

    func testBackgroundPhotoKitInvalidatesOnlyResourceFingerprintChanges() {
        let ids = ["edited", "legacy", "missing-date", "receipt-only"]
        for id in ids {
            if id != "receipt-only" {
                hashRepository.saveMultiResourceHashCache(
                    localIdentifier: id, primaryHash: "sha-\(id)",
                    rawHash: nil, hasRAW: false,
                    modificationDate: id == "legacy" ? nil : Date(timeIntervalSince1970: 100),
                    resourceFingerprint: id == "edited" ? "resource-v1" : nil
                )
            }
            uploadRepository.recordUploadedAsset(
                localIdentifier: id, resourceType: "jpeg", filename: "image.jpg", immichId: "remote"
            )
        }
        execute("UPDATE uploaded_assets SET asset_resource_fingerprint = 'resource-v1' WHERE asset_id = 'receipt-only';")
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
            updatedAssetResourceFingerprints: [
                "edited": "resource-v2",
                "legacy": "resource-v1",
                "missing-date": "resource-v1",
                "receipt-only": "resource-v1"
            ],
            tokenData: Data([2])
        )

        XCTAssertEqual(summary?.retainedVersions, 1)
        XCTAssertEqual(summary?.invalidatedVersions, 3)
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: "edited"))
        XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: "edited"))
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: "legacy"))
        XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: "legacy"))
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: "missing-date"))
        XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: "missing-date"))
        XCTAssertTrue(uploadRepository.isAnyResourceUploaded(localIdentifier: "receipt-only"))
        for id in ids {
            XCTAssertTrue(queuedIds().contains(id))
        }
        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM upload_jobs WHERE status = 'completed';"), 0)
        XCTAssertEqual(background.loadChangeToken(), Data([2]))
    }

    func testBackgroundPhotoKitInvalidationFailureRollsBackTokenAndRecords() {
        let id = "edited"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id, primaryHash: "sha-original", rawHash: nil,
            hasRAW: false, modificationDate: Date(timeIntervalSince1970: 100),
            resourceFingerprint: "resource-v1"
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
            updatedAssetResourceFingerprints: [id: "resource-v2"],
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
            modificationDate: Date(timeIntervalSince1970: 120),
            resourceFingerprint: "resource-v1"
        )
        execute("""
            INSERT INTO upload_jobs (asset_id, resource_type, filename, status, created_at, updated_at)
            VALUES ('foreground-rehashed', 'jpeg', 'image.jpg', 'completed', 0, 0);
        """)
        let background = BackgroundUploadDatabase(testingDatabasePath: databaseURL.path)
        let summary = background.commitPersistentChange(
            insertedAssetIds: [], updatedAssetIds: [id], deletedAssetIds: [],
            updatedAssetModificationDates: [id: Date(timeIntervalSince1970: 120)],
            updatedAssetResourceFingerprints: [id: "resource-v1"],
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
        execute("ALTER TABLE hash_cache DROP COLUMN asset_resource_fingerprint;")
        let background = BackgroundUploadDatabase(testingDatabasePath: databaseURL.path)
        let summary = background.commitPersistentChange(
            insertedAssetIds: [], updatedAssetIds: ["legacy"], deletedAssetIds: [],
            updatedAssetModificationDates: ["legacy": Date(timeIntervalSince1970: 100)],
            updatedAssetResourceFingerprints: ["legacy": "resource-v1"],
            tokenData: Data([1])
        )
        XCTAssertNil(summary)
        XCTAssertEqual(sqlCount("SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'legacy';"), 1)
        XCTAssertNil(background.loadChangeToken())
        XCTAssertFalse(queuedIds().contains("legacy"))
    }

    func testBackgroundRetainsUnresolvedUpdatedAssetUntilPhotoKitResolvesIt() {
        let id = "updated-then-deleted"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id, primaryHash: "sha-old",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100),
            resourceFingerprint: "resource-v1"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: id, resourceType: "jpeg",
            filename: "image.jpg", immichId: "remote"
        )
        execute("INSERT INTO background_upload_queue(asset_id, enqueued_at) VALUES ('updated-then-deleted', 1);")

        let background = BackgroundUploadDatabase(testingDatabasePath: databaseURL.path)
        let summary = background.commitPersistentChange(
            insertedAssetIds: [], updatedAssetIds: [id], deletedAssetIds: [],
            updatedAssetModificationDates: [:],
            updatedAssetResourceFingerprints: [:],
            tokenData: Data([7])
        )

        XCTAssertNil(summary)
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: id))
        XCTAssertTrue(uploadRepository.isAnyResourceUploaded(localIdentifier: id))
        XCTAssertTrue(queuedIds().contains(id))
        XCTAssertNil(background.loadChangeToken())
    }

    func testBackgroundDeletesAssetWhenPhotoKitReportsExplicitDeletion() {
        let id = "explicitly-deleted"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id, primaryHash: "sha-old",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100),
            resourceFingerprint: "resource-v1"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: id, resourceType: "jpeg",
            filename: "image.jpg", immichId: "remote"
        )
        execute("INSERT INTO background_upload_queue(asset_id, enqueued_at) VALUES ('explicitly-deleted', 1);")

        let background = BackgroundUploadDatabase(testingDatabasePath: databaseURL.path)
        let summary = background.commitPersistentChange(
            insertedAssetIds: [], updatedAssetIds: [id], deletedAssetIds: [id],
            updatedAssetModificationDates: [:],
            updatedAssetResourceFingerprints: [:],
            tokenData: Data([8])
        )

        XCTAssertNotNil(summary)
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: id))
        XCTAssertFalse(uploadRepository.isAnyResourceUploaded(localIdentifier: id))
        XCTAssertFalse(queuedIds().contains(id))
        XCTAssertEqual(background.loadChangeToken(), Data([8]))
    }

    func testForegroundPendingAssetWithRecoveredFingerprintClearsPending() {
        let id = "pending-resource-recovered"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id, primaryHash: "sha-old",
            rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100),
            resourceFingerprint: "resource-v1"
        )
        execute("INSERT INTO foreground_photo_pending_assets(asset_id) VALUES ('pending-resource-recovered');")

        hashRepository.reconcileForegroundPendingAssets(snapshots: [
            PhotoAssetSnapshot(
                localIdentifier: id,
                modificationDate: Date(timeIntervalSince1970: 120),
                resourceFingerprint: "resource-v1"
            )
        ])

        XCTAssertTrue(hashRepository.getPendingForegroundPhotoIdentifiers().isEmpty)
        XCTAssertNotNil(hashRepository.getHashCache(localIdentifier: id))
    }

    func testForegroundPendingAssetRetainsCurrentBackgroundReceiptWithoutHashCache() {
        let id = "pending-current-background-receipt"
        execute("""
            INSERT INTO uploaded_assets
              (asset_id, resource_type, filename, immich_id, uploaded_at, asset_resource_fingerprint)
            VALUES ('pending-current-background-receipt', 'jpeg', 'image.jpg', 'remote', 100, 'resource-v1');
            INSERT INTO foreground_photo_pending_assets(asset_id)
            VALUES ('pending-current-background-receipt');
        """)

        hashRepository.reconcileForegroundPendingAssets(snapshots: [
            PhotoAssetSnapshot(
                localIdentifier: id,
                modificationDate: Date(timeIntervalSince1970: 120),
                resourceFingerprint: "resource-v1"
            )
        ])

        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), [id])
        XCTAssertTrue(uploadRepository.isAnyResourceUploaded(localIdentifier: id))
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: id))
    }

    func testForegroundPendingAssetInvalidatesLegacyHashButRetainsCurrentBackgroundReceipt() {
        let id = "pending-legacy-hash-current-receipt"
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: id,
            primaryHash: "legacy-hash",
            rawHash: nil,
            hasRAW: false,
            modificationDate: nil,
            resourceFingerprint: nil
        )
        execute("""
            INSERT INTO uploaded_assets
              (asset_id, resource_type, filename, immich_id, uploaded_at, asset_resource_fingerprint)
            VALUES ('pending-legacy-hash-current-receipt', 'jpeg', 'image.jpg', 'remote', 100, 'resource-v1');
            INSERT INTO foreground_photo_pending_assets(asset_id)
            VALUES ('pending-legacy-hash-current-receipt');
        """)

        hashRepository.reconcileForegroundPendingAssets(snapshots: [
            PhotoAssetSnapshot(
                localIdentifier: id,
                modificationDate: Date(timeIntervalSince1970: 120),
                resourceFingerprint: "resource-v1"
            )
        ])

        XCTAssertTrue(hashRepository.getPendingForegroundPhotoIdentifiers().contains(id))
        XCTAssertTrue(uploadRepository.isAnyResourceUploaded(localIdentifier: id))
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: id))
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
