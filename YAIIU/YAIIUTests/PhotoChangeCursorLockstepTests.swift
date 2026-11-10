import SQLite3
import XCTest
@testable import YAIIU

/// Both processes share one SQLite file: the app through `HashCacheRepository`,
/// the extension through `BackgroundUploadDatabase`.
final class PhotoChangeCursorLockstepTests: XCTestCase {
    private var databaseURL: URL!
    private var connection: SQLiteConnection!
    private var hashRepository: HashCacheRepository!
    private var background: BackgroundUploadDatabase!

    private let start = Data([0xA0])
    private let next = Data([0xA1])

    override func setUp() {
        super.setUp()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaiiu-lockstep-\(UUID().uuidString).sqlite")
        connection = SQLiteConnection.testing(databasePath: databaseURL.path)
        connection.ensureInitialized()
        hashRepository = HashCacheRepository(connection: connection)
        background = BackgroundUploadDatabase(testingDatabasePath: databaseURL.path)
    }

    override func tearDown() {
        background = nil
        hashRepository = nil
        connection = nil
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
        }
        databaseURL = nil
        super.tearDown()
    }

    // MARK: - Extension commits

    func testExtensionCommitInLockstepAppliesForegroundEffectsAndAdvancesBothCursors() {
        establishInventory(["kept", "becomes-hidden", "gone"], token: start)
        background.saveChangeToken(start)
        execute("""
            INSERT INTO upload_jobs (asset_id, resource_type, filename, status, created_at, updated_at)
            VALUES ('gone', 'jpeg', 'gone.jpg', 'pending', 0, 0);
            """)
        execute("DELETE FROM foreground_photo_pending_assets;")

        let result = background.commitPersistentChange(
            insertedAssetIds: ["new"],
            updatedAssetIds: ["becomes-hidden"],
            deletedAssetIds: ["gone"],
            assetStates: [
                "new": state("new"),
                "becomes-hidden": state("becomes-hidden", hidden: true),
            ],
            expectedTokenData: start,
            tokenData: next,
            allowsForegroundLockstep: true
        )

        XCTAssertEqual(result.summary?.advancedForegroundCursor, true)
        XCTAssertEqual(background.loadChangeToken(), next)
        XCTAssertEqual(hashRepository.loadForegroundPhotoToken(), next)
        XCTAssertEqual(ids("SELECT asset_id FROM local_photo_assets ORDER BY asset_id;"),
                       ["becomes-hidden", "kept", "new"])
        XCTAssertEqual(ids("SELECT asset_id FROM local_photo_assets WHERE is_hidden = 1;"), ["becomes-hidden"])
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), ["new"])
        XCTAssertEqual(count("SELECT COUNT(*) FROM upload_jobs WHERE asset_id = 'gone';"), 0)
        XCTAssertEqual(ids("SELECT asset_id FROM background_upload_queue ORDER BY asset_id;"),
                       ["becomes-hidden", "new"])
    }

    func testExtensionCommitOutOfLockstepLeavesForegroundStateUntouched() {
        establishInventory(["kept"], token: start)
        let backgroundToken = Data([0xB0])
        background.saveChangeToken(backgroundToken)

        let result = background.commitPersistentChange(
            insertedAssetIds: ["new"], updatedAssetIds: [], deletedAssetIds: [],
            assetStates: ["new": state("new")],
            expectedTokenData: backgroundToken, tokenData: next,
            allowsForegroundLockstep: true
        )

        XCTAssertEqual(result.summary?.advancedForegroundCursor, false)
        XCTAssertEqual(background.loadChangeToken(), next)
        XCTAssertEqual(hashRepository.loadForegroundPhotoToken(), start)
        XCTAssertEqual(ids("SELECT asset_id FROM local_photo_assets;"), ["kept"])
    }

    func testExtensionCommitDoesNotAdvanceForegroundWhileInventoryIsNotReady() {
        establishInventory(["kept"], token: start)
        background.saveChangeToken(start)
        XCTAssertTrue(hashRepository.invalidateLocalPhotoInventory())

        let result = background.commitPersistentChange(
            insertedAssetIds: ["new"], updatedAssetIds: [], deletedAssetIds: [],
            assetStates: ["new": state("new")],
            expectedTokenData: start, tokenData: next,
            allowsForegroundLockstep: true
        )

        XCTAssertEqual(result.summary?.advancedForegroundCursor, false)
        XCTAssertEqual(hashRepository.loadForegroundPhotoToken(), start)
    }

    func testExtensionCommitReportsMovedCursorWithoutWriting() {
        establishInventory(["kept"], token: start)
        background.saveChangeToken(next)

        let result = background.commitPersistentChange(
            insertedAssetIds: ["new"], updatedAssetIds: [], deletedAssetIds: [],
            assetStates: ["new": state("new")],
            expectedTokenData: start, tokenData: Data([0xA2]),
            allowsForegroundLockstep: true
        )

        guard case .cursorMoved = result else { return XCTFail("Expected cursorMoved, got \(result)") }
        XCTAssertEqual(background.loadChangeToken(), next)
        XCTAssertEqual(count("SELECT COUNT(*) FROM background_upload_queue;"), 0)
    }

    func testExtensionCommitWithoutForegroundTablesStillAdvancesItsOwnCursor() {
        background.saveChangeToken(start)
        execute("DROP TABLE foreground_photo_change_state;")
        execute("DROP TABLE local_photo_inventory_state;")

        let result = background.commitPersistentChange(
            insertedAssetIds: ["new"], updatedAssetIds: [], deletedAssetIds: [],
            assetStates: ["new": state("new")],
            expectedTokenData: start, tokenData: next,
            allowsForegroundLockstep: true
        )

        XCTAssertEqual(result.summary?.advancedForegroundCursor, false)
        XCTAssertEqual(background.loadChangeToken(), next)
    }

    func testExtensionCommitUnderLimitedAccessDoesNotAdvanceForegroundCursor() {
        establishInventory(["kept"], token: start)
        background.saveChangeToken(start)

        let result = background.commitPersistentChange(
            insertedAssetIds: [], updatedAssetIds: [], deletedAssetIds: ["kept"],
            assetStates: [:],
            expectedTokenData: start, tokenData: next,
            allowsForegroundLockstep: false
        )

        XCTAssertEqual(result.summary?.advancedForegroundCursor, false)
        XCTAssertEqual(hashRepository.loadForegroundPhotoToken(), start)
        XCTAssertEqual(ids("SELECT asset_id FROM local_photo_assets;"), ["kept"])
    }

    // MARK: - Foreground windows

    func testForegroundWindowFallsBackToOwnCursorWhenExtensionEffectsFail() {
        establishInventory([], token: start)
        background.saveChangeToken(start)
        execute("""
            CREATE TRIGGER reject_queue_insert BEFORE INSERT ON background_upload_queue
            BEGIN SELECT RAISE(ABORT, 'forced failure'); END;
            """)
        let snapshots = [PhotoAssetSnapshot(localIdentifier: "new", modificationDate: nil, adjustmentVersion: "adj:none")]
        var window = ForegroundPhotoChangeBatch()
        window.append(affected: ["new"], deleted: [], tokenData: next)

        let result = hashRepository.commitForegroundPhotoJournalWindow(
            range: window.journalRange(snapshots: snapshots),
            snapshots: snapshots, expectedTokenData: start, tokenData: next
        )

        XCTAssertEqual(result, .committed(advancedBackgroundCursor: false))
        XCTAssertEqual(background.loadChangeToken(), start)
        XCTAssertEqual(hashRepository.loadForegroundPhotoToken(), next)
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers(), ["new"])
        XCTAssertEqual(ids("SELECT asset_id FROM local_photo_assets;"), ["new"])
    }

    func testForegroundWindowInLockstepAppliesExtensionEffectsAndAdvancesBothCursors() {
        establishInventory(["edited"], token: start)
        background.saveChangeToken(start)
        hashRepository.saveMultiResourceHashCache(
            localIdentifier: "edited", primaryHash: "sha-old", rawHash: nil, hasRAW: false,
            modificationDate: Date(timeIntervalSince1970: 100), adjustmentVersion: "adj:1"
        )
        let snapshots = [
            PhotoAssetSnapshot(localIdentifier: "new", modificationDate: nil, adjustmentVersion: "adj:none"),
            PhotoAssetSnapshot(
                localIdentifier: "edited", modificationDate: Date(timeIntervalSince1970: 200),
                adjustmentVersion: "adj:2"
            ),
        ]
        var window = ForegroundPhotoChangeBatch()
        window.append(affected: ["new", "edited"], updated: ["edited"], deleted: [], tokenData: next)

        let result = hashRepository.commitForegroundPhotoJournalWindow(
            range: window.journalRange(snapshots: snapshots),
            snapshots: snapshots, expectedTokenData: start, tokenData: next
        )

        XCTAssertEqual(result, .committed(advancedBackgroundCursor: true))
        XCTAssertEqual(background.loadChangeToken(), next)
        XCTAssertEqual(hashRepository.loadForegroundPhotoToken(), next)
        XCTAssertEqual(ids("SELECT asset_id FROM background_upload_queue ORDER BY asset_id;"), ["edited", "new"])
        XCTAssertNil(hashRepository.getHashCache(localIdentifier: "edited"))
        XCTAssertEqual(hashRepository.getPendingForegroundPhotoIdentifiers().sorted(), ["edited", "new"])
    }

    func testForegroundWindowWithUnresolvedUpdateAdvancesOnlyForegroundCursor() {
        establishInventory(["unresolved"], token: start)
        background.saveChangeToken(start)
        var window = ForegroundPhotoChangeBatch()
        window.append(affected: ["unresolved"], updated: ["unresolved"], deleted: [], tokenData: next)

        let result = hashRepository.commitForegroundPhotoJournalWindow(
            range: window.journalRange(snapshots: []),
            snapshots: [], expectedTokenData: start, tokenData: next
        )

        XCTAssertEqual(result, .committed(advancedBackgroundCursor: false))
        XCTAssertEqual(background.loadChangeToken(), start)
        XCTAssertEqual(hashRepository.loadForegroundPhotoToken(), next)
        XCTAssertEqual(count("SELECT COUNT(*) FROM background_upload_queue;"), 0)
    }

    func testForegroundWindowReportsMovedCursorWithoutWriting() {
        establishInventory([], token: next)
        execute("DELETE FROM foreground_photo_pending_assets;")
        var window = ForegroundPhotoChangeBatch()
        window.append(affected: ["new"], deleted: [], tokenData: Data([0xA2]))

        let result = hashRepository.commitForegroundPhotoJournalWindow(
            range: window.journalRange(snapshots: []),
            snapshots: [], expectedTokenData: start, tokenData: Data([0xA2])
        )

        XCTAssertEqual(result, .cursorMoved)
        XCTAssertEqual(hashRepository.loadForegroundPhotoToken(), next)
        XCTAssertTrue(hashRepository.getPendingForegroundPhotoIdentifiers().isEmpty)
    }

    func testWindowRangeSplitsInsertedFromUpdated() {
        var window = ForegroundPhotoChangeBatch()
        window.append(affected: ["inserted", "updated"], updated: ["updated"], deleted: [], tokenData: start)
        window.append(affected: [], deleted: ["deleted"], tokenData: next)

        let range = window.journalRange(snapshots: [])

        XCTAssertEqual(range.insertedIdentifiers, ["inserted"])
        XCTAssertEqual(range.updatedIdentifiers, ["updated"])
        XCTAssertEqual(range.deletedIdentifiers, ["deleted"])
    }

    // MARK: - Realignment

    func testRealignAdoptsExtensionCursorSoTheNextExtensionCommitIsInLockstep() {
        establishInventory(["kept"], token: start)
        let backgroundToken = Data([0xB0])
        background.saveChangeToken(backgroundToken)

        let realigned = hashRepository.realignForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(localIdentifier: "kept", modificationDate: nil)],
            pendingIdentifiers: ["kept"],
            backgroundTokenData: backgroundToken
        )
        XCTAssertEqual(realigned, .committed(advancedBackgroundCursor: false))
        XCTAssertEqual(hashRepository.loadForegroundPhotoToken(), backgroundToken)

        let result = background.commitPersistentChange(
            insertedAssetIds: ["new"], updatedAssetIds: [], deletedAssetIds: [],
            assetStates: ["new": state("new")],
            expectedTokenData: backgroundToken, tokenData: next,
            allowsForegroundLockstep: true
        )
        XCTAssertEqual(result.summary?.advancedForegroundCursor, true)
        XCTAssertEqual(hashRepository.loadForegroundPhotoToken(), next)
    }

    func testRealignIsRejectedWhenExtensionCursorMoved() {
        establishInventory(["kept"], token: start)
        background.saveChangeToken(next)

        let result = hashRepository.realignForegroundPhotoChanges(
            snapshots: [PhotoAssetSnapshot(localIdentifier: "kept", modificationDate: nil)],
            pendingIdentifiers: ["kept"],
            backgroundTokenData: Data([0xB0])
        )

        XCTAssertEqual(result, .cursorMoved)
        XCTAssertEqual(hashRepository.loadForegroundPhotoToken(), start)
    }

    // MARK: - Helpers

    private func establishInventory(_ identifiers: [String], token: Data) {
        XCTAssertTrue(hashRepository.applyForegroundPhotoChanges(
            snapshots: identifiers.map { PhotoAssetSnapshot(localIdentifier: $0, modificationDate: nil) },
            pendingIdentifiers: Set(identifiers),
            deletedIdentifiers: [],
            tokenData: token,
            bootstrap: true
        ))
    }

    private func state(_ id: String, hidden: Bool = false) -> PhotoAssetChangeState {
        PhotoAssetChangeState(
            localIdentifier: id, isHidden: hidden,
            modificationDate: Date(timeIntervalSince1970: 300), adjustmentVersion: "adj:none"
        )
    }

    private func ids(_ sql: String) -> [String] {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        return result
    }

    private func count(_ sql: String) -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            XCTFail("Could not run count query")
            return -1
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func execute(_ sql: String) {
        XCTAssertEqual(sqlite3_exec(connection.db, sql, nil, nil, nil), SQLITE_OK)
    }
}
