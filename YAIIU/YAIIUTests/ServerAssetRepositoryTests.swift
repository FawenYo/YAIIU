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
