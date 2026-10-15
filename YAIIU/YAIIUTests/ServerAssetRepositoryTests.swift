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

    func testForegroundUploadsUpdateCachedVerdictsWithoutRehashing() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "foreground-pair", primaryHash: "jpeg-hash",
            rawHash: "raw-hash", hasRAW: true
        )
        execute("UPDATE hash_cache SET checked_at = 100, is_on_server = 0, raw_on_server = 0 WHERE asset_id = 'foreground-pair';")

        uploadRepository.recordUploadedAsset(
            localIdentifier: "foreground-pair", resourceType: "jpeg",
            filename: "image.jpg", immichId: "immich-jpeg"
        )
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'foreground-pair' AND is_on_server = 1
              AND raw_on_server = 0 AND checked_at IS NOT NULL
              AND server_check_revision = 1 AND sha1_hash = 'jpeg-hash'
              AND raw_hash = 'raw-hash';
        """), 1)

        uploadRepository.recordUploadedAsset(
            localIdentifier: "foreground-pair", resourceType: "raw",
            filename: "image.dng", immichId: "immich-raw"
        )
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'foreground-pair' AND is_on_server = 1
              AND raw_on_server = 1 AND server_check_revision = 2
              AND sha1_hash = 'jpeg-hash' AND raw_hash = 'raw-hash';
        """), 1)
        XCTAssertEqual(count("SELECT COUNT(*) FROM uploaded_assets WHERE asset_id = 'foreground-pair';"), 2)
    }

    func testUploadBeforeHashReusesFreshDestinationTaggedHistory() {
        let hashes = HashCacheRepository(connection: connection)
        XCTAssertTrue(repository.saveSyncMetadata(
            lastSyncTime: Date(timeIntervalSince1970: 100),
            syncType: "full", userId: "owner-1",
            serverURL: "https://immich.example", totalAssets: 0,
            lastAck: "checkpoint"
        ))
        uploadRepository.recordUploadedAsset(
            localIdentifier: "upload-before-hash",
            resourceType: "jpeg", filename: "fresh.jpg",
            immichId: "remote-fresh",
            destinationIdentity: "current-destination"
        )
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'upload-before-hash';
        """), 0)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM uploaded_assets WHERE asset_id = 'upload-before-hash';
        """), 1)

        hashes.saveMultiResourceHashCache(
            localIdentifier: "upload-before-hash",
            primaryHash: "cached-original-sha1", rawHash: nil, hasRAW: false
        )
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'upload-before-hash'
              AND sha1_hash = 'cached-original-sha1'
              AND is_on_server = 1 AND checked_at IS NOT NULL;
        """), 1)

        uploadRepository.recordUploadedAsset(
            localIdentifier: "legacy-upload", resourceType: "jpeg",
            filename: "old.jpg", immichId: "remote-old"
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "legacy-upload",
            primaryHash: "legacy-sha1", rawHash: nil, hasRAW: false
        )
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'legacy-upload'
              AND is_on_server = 0 AND checked_at IS NULL;
        """), 1)
    }

    func testPendingRawPairUploadBeforeHashPreservesPartialVerdict() {
        let hashes = HashCacheRepository(connection: connection)
        uploadRepository.recordUploadedAsset(
            localIdentifier: "raw-after-upload", resourceType: "raw",
            filename: "pair.dng", immichId: "remote-pair-raw",
            destinationIdentity: "destination"
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "raw-after-upload",
            primaryHash: "primary-sha", rawHash: "raw-sha", hasRAW: true
        )
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'raw-after-upload' AND is_on_server = 0
              AND raw_on_server = 1 AND checked_at IS NOT NULL
              AND sha1_hash = 'primary-sha' AND raw_hash = 'raw-sha';
        """), 1)
    }

    func testDestinationIdentityRemainsStableAcrossInternalExternalRouting() {
        let external = "https://my-immich.example"
        let internalURL = "http://192.168.1.12:2283"
        let key = "same-api-key"
        let externalIdentity = UploadDestinationIdentity.make(
            serverURL: external, apiKey: key
        )
        // With the internal route selected, the configured external URL is
        // still the stable server/account identity, not the active endpoint.
        let identityWhileOnInternalRoute = UploadDestinationIdentity.make(
            serverURL: external, apiKey: key
        )
        XCTAssertNotNil(externalIdentity)
        XCTAssertEqual(identityWhileOnInternalRoute, externalIdentity)
        XCTAssertNotEqual(
            UploadDestinationIdentity.make(serverURL: internalURL, apiKey: key),
            externalIdentity
        )
        XCTAssertNotEqual(
            UploadDestinationIdentity.make(serverURL: external, apiKey: "different-account-key"),
            externalIdentity
        )
    }

    func testRawOnlyForegroundUploadMarksPrimaryComplete() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "foreground-raw-only", primaryHash: "raw-primary-hash",
            rawHash: nil, hasRAW: false
        )
        execute("""
            UPDATE hash_cache SET checked_at = 100, is_on_server = 0,
                raw_on_server = 0 WHERE asset_id = 'foreground-raw-only';
        """)

        uploadRepository.recordUploadedAsset(
            localIdentifier: "foreground-raw-only", resourceType: "raw",
            filename: "photo.dng", immichId: "remote-raw-only"
        )

        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'foreground-raw-only'
              AND sha1_hash = 'raw-primary-hash'
              AND raw_hash IS NULL AND has_raw = 0
              AND is_on_server = 1 AND raw_on_server = 0
              AND checked_at IS NOT NULL AND server_check_revision = 1;
        """), 1)
        let done = expectation(description: "RAW-only upload appears as uploaded")
        hashes.getAllSyncStatusAsync(
            uploadedResourceTypes: ["foreground-raw-only": ["raw"]],
            hasServerCache: true
        ) { statuses in
            XCTAssertEqual(statuses["foreground-raw-only"], .uploaded)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testBackgroundRAWUploadDistinguishesOnlyFromCompanion() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "background-raw-only", primaryHash: "raw-only-hash",
            rawHash: nil, hasRAW: false
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "background-pair", primaryHash: "jpeg-hash",
            rawHash: "companion-raw-hash", hasRAW: true
        )
        // Emulate extension discovery before the upload completes. Neither
        // repair nor the new-job marker may turn RAW-only into a companion.
        execute("""
            INSERT INTO upload_jobs
                (asset_id, resource_type, filename, status, created_at, updated_at)
            VALUES ('background-raw-only', 'raw', 'photo.dng', 'uploading', 100, 100);
        """)
        let backgroundDB = BackgroundUploadDatabase(testingDatabasePath: databaseURL.path)
        backgroundDB.markResourcePresent(
            assetId: "background-raw-only", resourceType: "raw"
        )
        backgroundDB.markResourcePresent(
            assetId: "background-pair", resourceType: "raw"
        )
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'background-raw-only' AND has_raw = 0
              AND raw_hash IS NULL;
        """), 1)
        backgroundDB.recordUploadedAsset(
            assetId: "background-raw-only", resourceType: "raw",
            filename: "photo.dng", immichId: "remote-raw-only",
            fileSize: 120, isDuplicate: false
        )
        backgroundDB.recordUploadedAsset(
            assetId: "background-pair", resourceType: "raw",
            filename: "paired.dng", immichId: "remote-raw-companion",
            fileSize: 130, isDuplicate: false
        )

        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'background-raw-only'
              AND is_on_server = 1 AND raw_on_server = 0
              AND has_raw = 0 AND server_check_revision = 1;
        """), 1)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'background-pair'
              AND is_on_server = 0 AND raw_on_server = 1
              AND has_raw = 1 AND server_check_revision = 1;
        """), 1)
    }

    func testLivePhotoJPEGAloneRemainsIncompleteUntilVideoUpload() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "live-photo", primaryHash: "live-jpeg-sha",
            rawHash: nil, hasRAW: false
        )
        uploadRepository.markLivePhotoVideoRequired(localIdentifier: "live-photo")
        uploadRepository.recordUploadedAsset(
            localIdentifier: "live-photo", resourceType: "jpeg",
            filename: "photo.jpg", immichId: "remote-live-jpeg"
        )
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'live-photo' AND is_on_server = 1
              AND checked_at IS NOT NULL;
        """), 1)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM live_photo_video_status
            WHERE asset_id = 'live-photo' AND video_on_server = 0;
        """), 1)
        let backgroundDB = BackgroundUploadDatabase(testingDatabasePath: databaseURL.path)
        XCTAssertFalse(backgroundDB.getAllAssetsOnServer().contains("live-photo"))
        XCTAssertTrue(backgroundDB.getPartialServerCopyAssets().primaryConfirmed.contains("live-photo"))
        XCTAssertFalse(backgroundDB.getPartialServerCopyAssets().videoConfirmed.contains("live-photo"))

        let pending = expectation(description: "Live video remains eligible")
        hashes.getAssetsNotFullyUploadedAsync(allIdentifiers: ["live-photo"]) { candidates in
            XCTAssertEqual(candidates, ["live-photo"])
            pending.fulfill()
        }
        wait(for: [pending], timeout: 5)

        let before = expectation(description: "Only JPEG is uploaded")
        hashes.getAllSyncStatusAsync(
            uploadedResourceTypes: ["live-photo": ["jpeg"]],
            hasServerCache: true
        ) { statuses in
            XCTAssertEqual(statuses["live-photo"], .notUploaded)
            before.fulfill()
        }
        wait(for: [before], timeout: 5)

        uploadRepository.recordUploadedAsset(
            localIdentifier: "live-photo", resourceType: "video",
            filename: "photo.mov", immichId: "remote-live-video"
        )
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM live_photo_video_status
            WHERE asset_id = 'live-photo' AND video_on_server = 1;
        """), 1)
        XCTAssertTrue(backgroundDB.getAllAssetsOnServer().contains("live-photo"))
        let after = expectation(description: "Live Photo now fully uploaded")
        hashes.getAllSyncStatusAsync(
            uploadedResourceTypes: ["live-photo": ["jpeg", "video"]],
            hasServerCache: true
        ) { statuses in
            XCTAssertEqual(statuses["live-photo"], .uploaded)
            after.fulfill()
        }
        wait(for: [after], timeout: 5)
    }

    func testICloudShortcutQueuesMissingLivePhotoVideo() {
        let hashes = HashCacheRepository(connection: connection)
        uploadRepository.markLivePhotoVideoRequired(localIdentifier: "cloud-live")
        XCTAssertTrue(repository.saveServerAssets([
            ServerAssetRecord(
                immichId: "server-live-jpeg",
                checksum: "original-jpeg",
                iCloudId: "cloud-live-identifier",
                ownerId: "owner-1"
            )
        ]))
        XCTAssertTrue(hashes.saveCurrentICloudIDMatch(
            localIdentifier: "cloud-live",
            iCloudId: "cloud-live-identifier",
            expectedChecksum: "original-jpeg",
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'cloud-live' AND sha1_hash = 'original-jpeg'
              AND is_on_server = 1 AND checked_at IS NOT NULL;
        """), 1)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM live_photo_video_status
            WHERE asset_id = 'cloud-live' AND video_on_server = 0;
        """), 1)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM background_upload_queue
            WHERE asset_id = 'cloud-live';
        """), 1)
        let db = BackgroundUploadDatabase(testingDatabasePath: databaseURL.path)
        XCTAssertFalse(db.getAllAssetsOnServer().contains("cloud-live"))
    }

    func testLivePhotoVideoFirstDoesNotConfirmMissingJPEG() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "video-first", primaryHash: "missing-jpeg-sha1",
            rawHash: nil, hasRAW: false
        )
        uploadRepository.markLivePhotoVideoRequired(localIdentifier: "video-first")
        uploadRepository.recordUploadedAsset(
            localIdentifier: "video-first", resourceType: "video",
            filename: "live.mov", immichId: "immich-live-video"
        )
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'video-first' AND is_on_server = 0
              AND checked_at IS NOT NULL;
        """), 1)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM live_photo_video_status
            WHERE asset_id = 'video-first' AND video_on_server = 1;
        """), 1)

        let fallback = expectation(description: "Video-only does not complete JPEG")
        hashes.getAllSyncStatusAsync(
            uploadedResourceTypes: ["video-first": ["video"]],
            hasServerCache: false
        ) { statuses in
            XCTAssertEqual(statuses["video-first"], .notUploaded)
            fallback.fulfill()
        }
        wait(for: [fallback], timeout: 5)

        XCTAssertTrue(repository.saveServerAssets([
            ServerAssetRecord(
                immichId: "immich-live-video", checksum: "video-checksum",
                ownerId: "owner-1"
            )
        ]))
        XCTAssertTrue(repository.finalizeFullServerSnapshot())
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'video-first' AND is_on_server = 0;
        """), 1)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM live_photo_video_status
            WHERE asset_id = 'video-first' AND video_on_server = 1;
        """), 1)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM background_upload_queue
            WHERE asset_id = 'video-first';
        """), 1)
    }

    func testLivePhotoRequirementIsRegisteredFromMetadataWithoutRehash() {
        let hashes = HashCacheRepository(connection: connection)
        let modDate = Date(timeIntervalSince1970: 1_700_000_000)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "metadata-live-photo",
            primaryHash: "persisted-sha1", rawHash: nil, hasRAW: false,
            modificationDate: modDate
        )
        execute("""
            UPDATE hash_cache SET is_on_server = 1, checked_at = 100
            WHERE asset_id = 'metadata-live-photo';
        """)
        hashes.resetCacheForModifiedAssets(snapshots: [
            PhotoAssetSnapshot(
                localIdentifier: "metadata-live-photo",
                modificationDate: modDate, hasVideoCompanion: true
            )
        ])
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM live_photo_video_status
            WHERE asset_id = 'metadata-live-photo' AND video_on_server = 0;
        """), 1)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'metadata-live-photo'
              AND sha1_hash = 'persisted-sha1' AND checked_at IS NOT NULL;
        """), 1)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM background_upload_queue
            WHERE asset_id = 'metadata-live-photo';
        """), 1)
        let done = expectation(description: "Still requires video, not new SHA1")
        hashes.getAssetsNeedingHashAsync(allIdentifiers: ["metadata-live-photo"]) { ids in
            XCTAssertTrue(ids.isEmpty)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testServerVideoDeletionReopensOnlyLivePhotoCompanion() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "remote-live-photo", primaryHash: "photo-checksum",
            rawHash: nil, hasRAW: false
        )
        uploadRepository.markLivePhotoVideoRequired(localIdentifier: "remote-live-photo")
        uploadRepository.recordUploadedAsset(
            localIdentifier: "remote-live-photo", resourceType: "jpeg",
            filename: "photo.jpg", immichId: "server-photo"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "remote-live-photo", resourceType: "video",
            filename: "photo.mov", immichId: "server-video"
        )
        XCTAssertTrue(repository.saveServerAssets([
            ServerAssetRecord(immichId: "server-photo", checksum: "photo-checksum", ownerId: "owner-1"),
            ServerAssetRecord(immichId: "server-video", checksum: "video-checksum", ownerId: "owner-1")
        ]))
        XCTAssertTrue(repository.finalizeFullServerSnapshot())
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM live_photo_video_status
            WHERE asset_id = 'remote-live-photo' AND video_on_server = 1;
        """), 1)
        XCTAssertTrue(repository.deleteServerAssets(["server-video"]))
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM live_photo_video_status
            WHERE asset_id = 'remote-live-photo' AND video_on_server = 0;
        """), 1)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'remote-live-photo' AND sha1_hash = 'photo-checksum';
        """), 1)
    }

    func testSQLitePrefilterSkipsOnlyConfirmedFullyUploadedAssets() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "uploaded", primaryHash: "sum-uploaded",
            rawHash: nil, hasRAW: false
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "missing", primaryHash: "sum-missing",
            rawHash: nil, hasRAW: false
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "paired-complete", primaryHash: "jpeg-complete",
            rawHash: "raw-complete", hasRAW: true
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "paired-partial", primaryHash: "jpeg-partial",
            rawHash: "raw-missing", hasRAW: true
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "unchecked", primaryHash: "sum-unknown",
            rawHash: nil, hasRAW: false
        )
        execute("""
            UPDATE hash_cache
            SET checked_at = 100, is_on_server = 1,
                raw_on_server = CASE WHEN asset_id = 'paired-complete' THEN 1 ELSE 0 END
            WHERE asset_id != 'unchecked';
        """)
        execute("UPDATE hash_cache SET is_on_server = 0 WHERE asset_id = 'missing';")
        // A stale positive flag without checked_at is NOT a completed verdict.
        execute("UPDATE hash_cache SET is_on_server = 1 WHERE asset_id = 'unchecked';")

        let done = expectation(description: "SQLite upload prefilter")
        let ids = [
            "uploaded", "missing", "paired-complete",
            "paired-partial", "unchecked", "no-hash"
        ]
        hashes.getAssetsNotFullyUploadedAsync(allIdentifiers: ids) { candidates in
            XCTAssertEqual(candidates, [
                "missing", "paired-partial", "unchecked", "no-hash"
            ])
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testHashFailureBackoffDoesNotBlockMetadataMatchingCandidates() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.recordHashFailure(
            localIdentifier: "backed-off-photo",
            errorMessage: "PhotoKit original unavailable",
            modificationDate: nil
        )
        let ids = ["backed-off-photo", "fresh-photo"]
        let metadata = expectation(description: "Metadata matching is not rate limited")
        hashes.getAssetsNeedingHashAsync(allIdentifiers: ids) { candidates in
            XCTAssertEqual(candidates, ids)
            metadata.fulfill()
        }
        wait(for: [metadata], timeout: 5)

        let hashing = expectation(description: "Expensive hashing observes retry backoff")
        hashes.getAssetsEligibleForHashRetryAsync(allIdentifiers: ids) { candidates in
            XCTAssertEqual(candidates, ["fresh-photo"])
            hashing.fulfill()
        }
        wait(for: [hashing], timeout: 5)

        execute("UPDATE hash_failures SET retry_after = 0 WHERE asset_id = 'backed-off-photo';")
        let retry = expectation(description: "Hashing allowed after backoff expires")
        hashes.getAssetsEligibleForHashRetryAsync(allIdentifiers: ids) { candidates in
            XCTAssertEqual(candidates, ids)
            retry.fulfill()
        }
        wait(for: [retry], timeout: 5)
    }

    func testCachedMissingHashesAreNotRecomputedUntilPhotoChanges() {
        let hashes = HashCacheRepository(connection: connection)
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "cached-missing",
            primaryHash: "missing-primary",
            rawHash: nil,
            hasRAW: false,
            modificationDate: originalDate
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "cached-raw-pair",
            primaryHash: "missing-jpeg",
            rawHash: "missing-raw",
            hasRAW: true,
            modificationDate: originalDate
        )
        // Both assets have confirmed negative server verdicts. That does not
        // invalidate their persisted SHA1 values or require another download.
        execute("UPDATE hash_cache SET checked_at = 100, is_on_server = 0, raw_on_server = 0;")

        let ids = ["cached-missing", "cached-raw-pair", "new-photo"]
        func assertHashCandidates(_ expected: [String], description: String) {
            let done = expectation(description: description)
            hashes.getAssetsNeedingHashAsync(allIdentifiers: ids) { needingHash in
                XCTAssertEqual(needingHash, expected)
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
        }

        // Re-running the pipeline (including after relaunch) reuses both
        // negative-verdict hashes; only a genuinely new asset needs hashing.
        assertHashCandidates(["new-photo"], description: "Initial hash lookup")
        assertHashCandidates(["new-photo"], description: "Repeated hash lookup")

        hashes.resetCacheForModifiedAssets(snapshots: [
            PhotoAssetSnapshot(localIdentifier: "cached-missing", modificationDate: originalDate),
            PhotoAssetSnapshot(
                localIdentifier: "cached-raw-pair",
                modificationDate: originalDate.addingTimeInterval(5)
            )
        ])
        // Changing a JPEG+RAW asset invalidates both hashes. An unchanged
        // missing-on-server asset still skips the expensive PhotoKit read.
        assertHashCandidates(
            ["cached-raw-pair", "new-photo"],
            description: "Only modified and new photos need hashing"
        )
        XCTAssertEqual(
            count("SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'cached-missing';"),
            1
        )
    }

    func testSQLitePrefilterReincludesAssetsAfterServerDeltaInvalidation() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "uploaded", primaryHash: "server-sum",
            rawHash: nil, hasRAW: false
        )
        execute("UPDATE hash_cache SET checked_at = 100, is_on_server = 1;")
        let first = expectation(description: "Already uploaded skipped")
        hashes.getAssetsNotFullyUploadedAsync(allIdentifiers: ["uploaded"]) { candidates in
            XCTAssertTrue(candidates.isEmpty)
            first.fulfill()
        }
        wait(for: [first], timeout: 5)

        XCTAssertTrue(repository.saveServerAssets([
            record(checksum: "server-sum", iCloudId: nil)
        ], syncType: "delta"))
        let second = expectation(description: "Server delta reopens candidate")
        hashes.getAssetsNotFullyUploadedAsync(allIdentifiers: ["uploaded"]) { candidates in
            XCTAssertEqual(candidates, ["uploaded"])
            second.fulfill()
        }
        wait(for: [second], timeout: 5)
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

    func testDeletingServerAssetClearsMatchingUnknownUploadHistory() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "unresolved-primary", primaryHash: "gone-checksum",
            rawHash: nil, hasRAW: false
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "paired-resource", primaryHash: "surviving-jpeg",
            rawHash: "gone-raw", hasRAW: true
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "unresolved-primary", resourceType: "jpeg",
            filename: "gone.jpg", immichId: "unknown"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "paired-resource", resourceType: "jpeg",
            filename: "pair.jpg", immichId: "still-on-server"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "paired-resource", resourceType: "raw",
            filename: "pair.dng", immichId: "unknown"
        )
        XCTAssertTrue(repository.saveServerAssets([
            ServerAssetRecord(immichId: "deleted", checksum: "gone-checksum", ownerId: "owner-1"),
            ServerAssetRecord(immichId: "deleted-raw", checksum: "gone-raw", ownerId: "owner-1")
        ]))
        XCTAssertTrue(repository.deleteServerAssets(["deleted", "deleted-raw"]))
        XCTAssertEqual(count("SELECT COUNT(*) FROM uploaded_assets WHERE immich_id = 'unknown';"), 0)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM uploaded_assets
            WHERE asset_id = 'paired-resource' AND resource_type = 'jpeg';
        """), 1)
        // Server disappearance invalidates presence only, not the local hashes.
        XCTAssertEqual(count("SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'paired-resource' AND raw_hash = 'gone-raw';"), 1)
        XCTAssertEqual(count("SELECT COUNT(*) FROM hash_cache WHERE checked_at IS NULL;"), 2)
    }

    func testDeletingRAWOnlyServerAssetClearsUnknownRAWHistoryWithoutRehash() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "deleted-raw-only",
            primaryHash: "original-raw-sha1", rawHash: nil, hasRAW: false
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "unrelated-raw-only",
            primaryHash: "unrelated-raw-sha1", rawHash: nil, hasRAW: false
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "unrelated-pair",
            primaryHash: "unrelated-jpeg-sha1",
            rawHash: "unrelated-companion-sha1", hasRAW: true
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "deleted-raw-only", resourceType: "raw",
            filename: "deleted.dng", immichId: "unknown"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "unrelated-raw-only", resourceType: "raw",
            filename: "other.dng", immichId: "unknown"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "unrelated-pair", resourceType: "raw",
            filename: "pair.dng", immichId: "unknown"
        )
        execute("UPDATE hash_cache SET checked_at = 100, is_on_server = 1;")
        // A rewritten server checksum must use the original source checksum
        // to identify the missing RAW-only upload record.
        XCTAssertTrue(repository.saveServerAssets([
            ServerAssetRecord(
                immichId: "deleted-raw-id",
                checksum: "transcoded-raw-sha1",
                sourceChecksum: "original-raw-sha1",
                ownerId: "owner-1"
            )
        ]))
        XCTAssertTrue(repository.deleteServerAssets(["deleted-raw-id"]))

        XCTAssertFalse(uploadRepository.isAssetUploaded(
            localIdentifier: "deleted-raw-only", resourceType: "raw"
        ))
        XCTAssertTrue(uploadRepository.isAssetUploaded(
            localIdentifier: "unrelated-raw-only", resourceType: "raw"
        ))
        XCTAssertTrue(uploadRepository.isAssetUploaded(
            localIdentifier: "unrelated-pair", resourceType: "raw"
        ))
        // Deletion invalidates the verdict, not the computed PhotoKit SHA1.
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'deleted-raw-only'
              AND sha1_hash = 'original-raw-sha1'
              AND raw_hash IS NULL AND has_raw = 0
              AND checked_at IS NULL AND is_on_server = 0;
        """), 1)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id IN ('unrelated-raw-only', 'unrelated-pair')
              AND checked_at IS NOT NULL;
        """), 2)
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

    func testFullSnapshotStillOffersOwnedMissingICloudIDBackfill() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "owned-missing", primaryHash: "source-owned",
            rawHash: nil, hasRAW: false
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "already-backfilled", primaryHash: "known-hash",
            rawHash: nil, hasRAW: false
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "partner", primaryHash: "partner-hash",
            rawHash: nil, hasRAW: false
        )
        XCTAssertTrue(repository.saveServerAssets([
            ServerAssetRecord(
                immichId: "owned-remote", checksum: "transcoded",
                sourceChecksum: "source-owned", ownerId: "owner-1"
            ),
            ServerAssetRecord(
                immichId: "known-remote", checksum: "known-hash",
                iCloudId: "cloud-already", ownerId: "owner-1"
            ),
            ServerAssetRecord(
                immichId: "partner-remote", checksum: "partner-hash",
                ownerId: "owner-2"
            )
        ]))
        XCTAssertTrue(repository.saveSyncMetadata(
            lastSyncTime: Date(), syncType: "full",
            userId: "owner-1", serverURL: "https://immich.example",
            totalAssets: 3, lastAck: "checkpoint"
        ))
        XCTAssertTrue(repository.finalizeFullServerSnapshot())
        XCTAssertEqual(pendingCheckCount(), 0)

        let done = expectation(description: "Backfill still selectable after checked verdict")
        hashes.getMissingICloudIDBackfillCandidatesAsync { candidates in
            XCTAssertEqual(candidates.count, 1)
            XCTAssertEqual(candidates.first?.localIdentifier, "owned-missing")
            XCTAssertEqual(candidates.first?.immichId, "owned-remote")
            XCTAssertEqual(candidates.first?.sourceChecksum, "source-owned")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testICloudMetadataBackfillIncludesOwnedRAWCompanion() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "paired-backfill", primaryHash: "local-jpeg",
            rawHash: "local-raw", hasRAW: true
        )
        XCTAssertTrue(repository.saveServerAssets([
            ServerAssetRecord(
                immichId: "server-jpeg", checksum: "transcoded-jpeg",
                sourceChecksum: "local-jpeg", ownerId: "owner-1"
            ),
            ServerAssetRecord(
                immichId: "server-raw", checksum: "local-raw",
                ownerId: "owner-1"
            ),
            ServerAssetRecord(
                immichId: "other-owner-raw", checksum: "other-hash",
                ownerId: "owner-2"
            )
        ]))
        XCTAssertTrue(repository.saveSyncMetadata(
            lastSyncTime: Date(), syncType: "full", userId: "owner-1",
            serverURL: "https://immich.example", totalAssets: 3,
            lastAck: "checkpoint"
        ))
        XCTAssertTrue(repository.finalizeFullServerSnapshot())
        let done = expectation(description: "Owned primary and RAW metadata backfill")
        hashes.getMissingICloudIDBackfillCandidatesAsync { candidates in
            XCTAssertEqual(Set(candidates.map { $0.immichId }), ["server-jpeg", "server-raw"])
            XCTAssertEqual(Set(candidates.map { $0.localIdentifier }), ["paired-backfill"])
            XCTAssertEqual(
                candidates.first(where: { $0.immichId == "server-jpeg" })?.sourceChecksum,
                "local-jpeg"
            )
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testICloudMetadataBackfillIncludesRAWOnlyPartialPresence() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "raw-on-server-only",
            primaryHash: "missing-jpeg-checksum",
            rawHash: "present-raw-checksum", hasRAW: true
        )
        XCTAssertTrue(repository.saveServerAssets([
            ServerAssetRecord(
                immichId: "raw-existing", checksum: "present-raw-checksum",
                ownerId: "owner-1"
            )
        ]))
        XCTAssertTrue(repository.saveSyncMetadata(
            lastSyncTime: Date(), syncType: "full",
            userId: "owner-1", serverURL: "https://immich.example",
            totalAssets: 1, lastAck: "checkpoint"
        ))
        XCTAssertTrue(repository.finalizeFullServerSnapshot())
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'raw-on-server-only'
              AND checked_at IS NOT NULL
              AND is_on_server = 0 AND raw_on_server = 1;
        """), 1)
        let done = expectation(description: "Partial RAW still eligible for metadata backfill")
        hashes.getMissingICloudIDBackfillCandidatesAsync { candidates in
            XCTAssertEqual(candidates.map { $0.immichId }, ["raw-existing"])
            XCTAssertEqual(candidates.first?.localIdentifier, "raw-on-server-only")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testPersistentLivePhotoEditInvalidatesOldVideoConfirmation() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "modified-live-photo",
            primaryHash: "original-jpeg", rawHash: nil, hasRAW: false
        )
        uploadRepository.markLivePhotoVideoRequired(localIdentifier: "modified-live-photo")
        uploadRepository.recordUploadedAsset(
            localIdentifier: "modified-live-photo", resourceType: "jpeg",
            filename: "before.jpg", immichId: "server-old-jpeg"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "modified-live-photo", resourceType: "video",
            filename: "before.mov", immichId: "server-old-video"
        )
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM live_photo_video_status
            WHERE asset_id = 'modified-live-photo' AND video_on_server = 1;
        """), 1)
        let backgroundDB = BackgroundUploadDatabase(testingDatabasePath: databaseURL.path)
        XCTAssertTrue(backgroundDB.commitPersistentChange(
            insertedAssetIds: [], updatedAssetIds: ["modified-live-photo"],
            deletedAssetIds: [], tokenData: Data([2, 3, 4])
        ))
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM live_photo_video_status
            WHERE asset_id = 'modified-live-photo';
        """), 0)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM uploaded_assets
            WHERE asset_id = 'modified-live-photo';
        """), 0)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'modified-live-photo';
        """), 0)
        backgroundDB.markLivePhotoVideoRequired(assetId: "modified-live-photo")
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM live_photo_video_status
            WHERE asset_id = 'modified-live-photo' AND video_on_server = 0;
        """), 1)
        XCTAssertFalse(backgroundDB.isLivePhotoVideoConfirmed(assetId: "modified-live-photo"))
    }

    func testPhotoKitDeletionRemovesCachedHashBeforeFullSnapshot() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "deleted-locally", primaryHash: "orphan-sum",
            rawHash: nil, hasRAW: false
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "still-local", primaryHash: "live-sum",
            rawHash: nil, hasRAW: false
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "deleted-locally", resourceType: "jpeg",
            filename: "orphan.jpg", immichId: "old-server-id"
        )
        execute("""
            INSERT INTO background_upload_queue (asset_id, enqueued_at)
            VALUES ('deleted-locally', 100);
        """)

        let backgroundDB = BackgroundUploadDatabase(testingDatabasePath: databaseURL.path)
        XCTAssertTrue(backgroundDB.commitPersistentChange(
            insertedAssetIds: [], updatedAssetIds: [],
            deletedAssetIds: ["deleted-locally"],
            tokenData: Data([1, 2, 3])
        ))
        XCTAssertEqual(count("SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'deleted-locally';"), 0)
        XCTAssertEqual(count("SELECT COUNT(*) FROM uploaded_assets WHERE asset_id = 'deleted-locally';"), 0)
        XCTAssertEqual(count("SELECT COUNT(*) FROM background_upload_queue WHERE asset_id = 'deleted-locally';"), 0)

        XCTAssertTrue(repository.finalizeFullServerSnapshot())
        XCTAssertEqual(count("SELECT COUNT(*) FROM background_upload_queue WHERE asset_id = 'deleted-locally';"), 0)
        XCTAssertEqual(count("SELECT COUNT(*) FROM background_upload_queue WHERE asset_id = 'still-local';"), 1)
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

    func testFullSnapshotPreservesUploadsCompletedAfterCapture() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "early", primaryHash: "early-hash",
            rawHash: nil, hasRAW: false
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "late", primaryHash: "late-hash",
            rawHash: nil, hasRAW: false
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "paired-late-raw", primaryHash: "missing-jpeg",
            rawHash: "late-raw-hash", hasRAW: true
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "early", resourceType: "jpeg",
            filename: "early.jpg", immichId: "early-server"
        )
        // The former upload predates the server capture and is not in its
        // catalog; it must be invalidated.
        execute("UPDATE uploaded_assets SET uploaded_at = 100 WHERE asset_id = 'early';")
        uploadRepository.recordUploadedAsset(
            localIdentifier: "late", resourceType: "jpeg",
            filename: "late.jpg", immichId: "late-server",
            destinationIdentity: "same-destination"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "paired-late-raw", resourceType: "raw",
            filename: "late.dng", immichId: "raw-server",
            destinationIdentity: "same-destination"
        )

        XCTAssertTrue(repository.finalizeFullServerSnapshot(
            snapshotStartedAt: Date(timeIntervalSince1970: 200),
            destinationIdentity: "same-destination"
        ))
        XCTAssertEqual(count("SELECT COUNT(*) FROM uploaded_assets WHERE asset_id = 'early';"), 0)
        XCTAssertEqual(count("SELECT COUNT(*) FROM uploaded_assets WHERE asset_id = 'late';"), 1)
        XCTAssertEqual(count("SELECT COUNT(*) FROM uploaded_assets WHERE asset_id = 'paired-late-raw';"), 1)
        XCTAssertEqual(count("SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'late' AND is_on_server = 1;"), 1)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'paired-late-raw'
              AND is_on_server = 0 AND raw_on_server = 1;
        """), 1)
        XCTAssertEqual(count("SELECT COUNT(*) FROM hash_cache WHERE asset_id = 'early' AND is_on_server = 0;"), 1)
        XCTAssertEqual(count("SELECT COUNT(*) FROM background_upload_queue WHERE asset_id = 'late';"), 0)
        XCTAssertEqual(count("SELECT COUNT(*) FROM background_upload_queue WHERE asset_id = 'early';"), 1)
    }

    func testSnapshotCaptureBoundaryPreservesPreCheckpointUploadWithoutHash() {
        let hashes = HashCacheRepository(connection: connection)
        uploadRepository.recordUploadedAsset(
            localIdentifier: "captured-late", resourceType: "jpeg",
            filename: "late.jpg", immichId: "late-server-id",
            destinationIdentity: "active-destination"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "captured-early", resourceType: "jpeg",
            filename: "early.jpg", immichId: "deleted-server-id",
            destinationIdentity: "active-destination"
        )
        // The photo was uploaded after snapshot capture at 100, but before
        // the final sync acknowledgement/checkpoint time at 200.
        execute("""
            UPDATE uploaded_assets
            SET uploaded_at = CASE WHEN asset_id = 'captured-late' THEN 150 ELSE 50 END;
        """)
        XCTAssertTrue(repository.finalizeFullServerSnapshot(
            snapshotStartedAt: Date(timeIntervalSince1970: 100),
            destinationIdentity: "active-destination"
        ))
        XCTAssertTrue(repository.saveSyncMetadata(
            lastSyncTime: Date(timeIntervalSince1970: 200),
            syncType: "full", userId: "owner-1",
            serverURL: "https://immich.example", totalAssets: 0,
            lastAck: "checkpoint"
        ))
        hashes.saveMultiResourceHashCache(
            localIdentifier: "captured-late", primaryHash: "hash-after-upload",
            rawHash: nil, hasRAW: false
        )
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'captured-late' AND sha1_hash = 'hash-after-upload'
              AND is_on_server = 1 AND checked_at IS NOT NULL;
        """), 1)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM sync_snapshot_boundaries
            WHERE id = 1 AND snapshot_started_at = 100
              AND destination_identity = 'active-destination';
        """), 1)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM uploaded_assets WHERE asset_id = 'captured-early';
        """), 0)
        // The hash is calculated once and then reused on the next sync.
        let done = expectation(description: "Captured late hash is still persisted")
        hashes.getAssetsNeedingHashAsync(allIdentifiers: ["captured-late"]) { candidates in
            XCTAssertTrue(candidates.isEmpty)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testSwitchingDestinationPreservesNewAccountUploadBeforeExtensionReset() throws {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "new-account-upload", primaryHash: "source-sha",
            rawHash: nil, hasRAW: false
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "previous-account-upload", primaryHash: "old-sha",
            rawHash: nil, hasRAW: false
        )
        let bg = BackgroundUploadDatabase(testingDatabasePath: databaseURL.path)
        try bg.ensureDestinationIdentity("destination-A")
        uploadRepository.recordUploadedAsset(
            localIdentifier: "previous-account-upload",
            resourceType: "jpeg", filename: "old.jpg",
            immichId: "old-remote", destinationIdentity: "destination-A"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "new-account-upload", resourceType: "jpeg",
            filename: "new.jpg", immichId: "new-remote",
            destinationIdentity: "destination-B"
        )
        // The stale background identity rejects the immediate positive
        // foreground verdict, but the properly tagged upload is durable.
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'new-account-upload' AND is_on_server = 0;
        """), 1)
        XCTAssertTrue(try bg.ensureDestinationIdentity("destination-B"))
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM uploaded_assets
            WHERE asset_id = 'new-account-upload'
              AND destination_identity = 'destination-B';
        """), 1)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM uploaded_assets
            WHERE asset_id = 'previous-account-upload';
        """), 0)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'new-account-upload' AND is_on_server = 1
              AND checked_at IS NOT NULL AND sha1_hash = 'source-sha';
        """), 1)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'previous-account-upload' AND is_on_server = 0
              AND checked_at IS NULL AND sha1_hash = 'old-sha';
        """), 1)
    }

    func testFullSnapshotRejectsLateUploadsFromOldDestination() {
        let hashes = HashCacheRepository(connection: connection)
        for id in ["current-late", "previous-late", "legacy-late"] {
            hashes.saveMultiResourceHashCache(
                localIdentifier: id, primaryHash: "hash-\(id)",
                rawHash: nil, hasRAW: false
            )
        }
        for (id, destination) in [
            ("current-late", "destination-B"),
            ("previous-late", "destination-A"),
            ("legacy-late", "")
        ] {
            uploadRepository.recordUploadedAsset(
                localIdentifier: id, resourceType: "jpeg",
                filename: "\(id).jpg", immichId: "immich-\(id)",
                destinationIdentity: destination.isEmpty ? nil : destination
            )
        }
        XCTAssertTrue(repository.finalizeFullServerSnapshot(
            snapshotStartedAt: Date(timeIntervalSince1970: 200),
            destinationIdentity: "destination-B"
        ))
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM uploaded_assets
            WHERE asset_id = 'current-late' AND destination_identity = 'destination-B';
        """), 1)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'current-late' AND is_on_server = 1;
        """), 1)
        for id in ["previous-late", "legacy-late"] {
            XCTAssertEqual(count("SELECT COUNT(*) FROM uploaded_assets WHERE asset_id = '\(id)';"), 0)
            XCTAssertEqual(count("""
                SELECT COUNT(*) FROM hash_cache
                WHERE asset_id = '\(id)' AND is_on_server = 0;
            """), 1)
        }
    }

    func testFullSnapshotHonorsRetainedUploadIDsForTranscodedResources() {
        let hashes = HashCacheRepository(connection: connection)
        hashes.saveMultiResourceHashCache(
            localIdentifier: "legacy-primary", primaryHash: "original-primary",
            rawHash: nil, hasRAW: false
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "legacy-pair", primaryHash: "original-jpeg",
            rawHash: "original-raw", hasRAW: true
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "old-gone", primaryHash: "no-longer-on-server",
            rawHash: nil, hasRAW: false
        )
        hashes.saveMultiResourceHashCache(
            localIdentifier: "legacy-raw-only", primaryHash: "original-raw-only",
            rawHash: nil, hasRAW: false
        )
        // Immich rewrote the payloads; neither server checksum matches a
        // local SHA1, but these exact Immich IDs still exist in the snapshot.
        XCTAssertTrue(repository.saveServerAssets([
            ServerAssetRecord(
                immichId: "server-primary", checksum: "rewritten-primary",
                ownerId: "owner-1"
            ),
            ServerAssetRecord(
                immichId: "server-jpeg", checksum: "rewritten-jpeg",
                ownerId: "owner-1"
            ),
            ServerAssetRecord(
                immichId: "server-raw", checksum: "rewritten-raw",
                ownerId: "owner-1"
            ),
            ServerAssetRecord(
                immichId: "server-raw-only", checksum: "rewritten-raw-only",
                ownerId: "owner-1"
            )
        ], syncType: "full"))
        uploadRepository.recordUploadedAsset(
            localIdentifier: "legacy-primary", resourceType: "jpeg",
            filename: "old.jpg", immichId: "server-primary"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "legacy-pair", resourceType: "jpeg",
            filename: "pair.jpg", immichId: "server-jpeg"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "legacy-pair", resourceType: "raw",
            filename: "pair.dng", immichId: "server-raw"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "old-gone", resourceType: "jpeg",
            filename: "deleted.jpg", immichId: "deleted-server-id"
        )
        uploadRepository.recordUploadedAsset(
            localIdentifier: "legacy-raw-only", resourceType: "raw",
            filename: "raw-only.dng", immichId: "server-raw-only"
        )
        // Make every upload predate the snapshot boundary.
        execute("UPDATE uploaded_assets SET uploaded_at = 100;")

        XCTAssertTrue(repository.finalizeFullServerSnapshot(
            snapshotStartedAt: Date(timeIntervalSince1970: 200)
        ))
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'legacy-primary' AND is_on_server = 1
              AND checked_at IS NOT NULL AND sha1_hash = 'original-primary';
        """), 1)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'legacy-pair'
              AND is_on_server = 1 AND raw_on_server = 1
              AND raw_hash = 'original-raw';
        """), 1)
        XCTAssertEqual(count("SELECT COUNT(*) FROM uploaded_assets WHERE asset_id = 'legacy-pair';"), 2)
        XCTAssertEqual(count("SELECT COUNT(*) FROM background_upload_queue WHERE asset_id = 'legacy-pair';"), 0)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'legacy-raw-only' AND has_raw = 0
              AND is_on_server = 1 AND raw_on_server = 0
              AND sha1_hash = 'original-raw-only';
        """), 1)
        XCTAssertEqual(count("SELECT COUNT(*) FROM background_upload_queue WHERE asset_id = 'legacy-raw-only';"), 0)
        // An older upload absent from this same snapshot is still stale.
        XCTAssertEqual(count("SELECT COUNT(*) FROM uploaded_assets WHERE asset_id = 'old-gone';"), 0)
        XCTAssertEqual(count("""
            SELECT COUNT(*) FROM hash_cache
            WHERE asset_id = 'old-gone' AND is_on_server = 0;
        """), 1)
        XCTAssertEqual(count("SELECT COUNT(*) FROM background_upload_queue WHERE asset_id = 'old-gone';"), 1)
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
