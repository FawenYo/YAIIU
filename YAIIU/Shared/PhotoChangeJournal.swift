import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// PhotoKit state of one changed asset, read after its journal event.
struct PhotoAssetChangeState: Equatable, Sendable {
    let localIdentifier: String
    let isHidden: Bool
    let modificationDate: Date?
    let adjustmentVersion: String?
}

/// A contiguous range of PhotoKit persistent changes. The foreground coalesces
/// many journal events into one range; the extension commits one event at a time.
struct PhotoChangeJournalRange {
    var insertedIdentifiers: Set<String>
    var updatedIdentifiers: Set<String>
    var deletedIdentifiers: Set<String>
    /// Only assets PhotoKit could resolve; unresolved identifiers are absent.
    var states: [String: PhotoAssetChangeState]

    var affectedIdentifiers: Set<String> {
        insertedIdentifiers.union(updatedIdentifiers).subtracting(deletedIdentifiers)
    }

    /// The background cursor never advances past an update it cannot version.
    var hasVersionEvidenceForEveryUpdate: Bool {
        updatedIdentifiers.subtracting(deletedIdentifiers).allSatisfy {
            states[$0]?.adjustmentVersion != nil
        }
    }
}

enum PhotoAssetChangeCommitResult {
    case committed(PhotoAssetChangeCommitSummary)
    /// The other process advanced this cursor first; restart from the stored token.
    case cursorMoved
    case failed

    var summary: PhotoAssetChangeCommitSummary? {
        if case .committed(let summary) = self { return summary }
        return nil
    }
}

struct ForegroundPhotoEffectCounters {
    var unchangedCached = 0
    var missingCache = 0
    var invalidatedAdjustmentVersion = 0
    var missingAdjustmentVersion = 0
    var unknownAdjustmentVersion = 0
    var missingCurrentDate = 0
    private(set) var cacheDetails: [String] = []

    static let cacheDetailLimit = 10

    mutating func recordCacheDetail(_ message: String) {
        if cacheDetails.count < Self.cacheDetailLimit { cacheDetails.append(message) }
    }
}

/// SQL shared by the app and the upload extension for applying PhotoKit
/// persistent-change history. Both processes keep their own cursor
/// (`change_tokens` for the extension, `foreground_photo_change_state` for the
/// app). While both rows hold identical token bytes and the local inventory is
/// ready, the cursors are in lockstep: whichever process commits the next range
/// applies both effect sets and advances both rows, so the other process never
/// walks that range again. Every commit compares the caller's own row with the
/// token it started from, so concurrent walkers cannot regress a cursor.
/// See docs/photo-change-cursor-lockstep.md.
enum PhotoChangeJournal {
    struct Cursors {
        let background: Data?
        let foreground: Data?
        let inventoryReady: Bool

        func inLockstep(at token: Data?) -> Bool {
            guard let token, inventoryReady else { return false }
            return background == token && foreground == token
        }
    }

    /// Call inside an IMMEDIATE transaction so the comparison and the write that
    /// follows cannot interleave with the other process.
    static func readCursors(db: OpaquePointer) -> Cursors? {
        guard let background = readBlob(db: db, sql: "SELECT token_data FROM change_tokens WHERE id = 1"),
              let foregroundTablesExist = readInt(db: db, sql: """
                SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'
                AND name IN ('foreground_photo_change_state', 'local_photo_inventory_state')
                """)
        else { return nil }
        // The extension can run before the app has created its foreground
        // tables. That is "not in lockstep", not an error.
        guard foregroundTablesExist == 2 else {
            return Cursors(background: background, foreground: nil, inventoryReady: false)
        }
        guard let foreground = readBlob(
                db: db, sql: "SELECT token_data FROM foreground_photo_change_state WHERE id = 1"
              ),
              let ready = readInt(db: db, sql: "SELECT is_ready FROM local_photo_inventory_state WHERE id = 1")
        else { return nil }
        return Cursors(background: background, foreground: foreground, inventoryReady: ready == 1)
    }

    static func writeBackgroundCursor(db: OpaquePointer, tokenData: Data) -> Bool {
        let sql = "INSERT OR REPLACE INTO change_tokens (id, token_data, updated_at) VALUES (1, ?, ?)"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              bind(tokenData, to: statement, index: 1),
              sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970) == SQLITE_OK
        else { return false }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    static func writeForegroundCursor(db: OpaquePointer, tokenData: Data) -> Bool {
        let sql = "INSERT OR REPLACE INTO foreground_photo_change_state(id, token_data) VALUES (1, ?)"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              bind(tokenData, to: statement, index: 1)
        else { return false }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    // MARK: - Background effects

    /// Durable upload queue, version-checked cache invalidation and foreground
    /// pending candidates. Requires `hasVersionEvidenceForEveryUpdate`.
    static func applyBackgroundEffects(
        db: OpaquePointer,
        range: PhotoChangeJournalRange
    ) -> PhotoAssetChangeCommitSummary? {
        let insertedAssetIds = range.insertedIdentifiers
        let updatedAssetIds = range.updatedIdentifiers
        let deletedAssetIds = range.deletedIdentifiers
        guard range.hasVersionEvidenceForEveryUpdate else { return nil }

        let now = Date().timeIntervalSince1970
        guard run(
            db: db,
            sql: "INSERT OR IGNORE INTO background_upload_queue (asset_id, enqueued_at) VALUES (?, ?)",
            ids: insertedAssetIds.union(updatedAssetIds).subtracting(deletedAssetIds),
            extra: { sqlite3_bind_double($0, 2, now) == SQLITE_OK }
        ) else { return nil }

        // PhotoKit marks metadata/iCloud availability updates as "updated" too.
        // Compare adjustment versions inside same transaction as cache
        // invalidation and cursor advancement. Legacy rows invalidate when the
        // modification date no longer matches.
        var invalidatedUpdatedIds = deletedAssetIds
        // A receipt can exist without any foreground hash cache row.
        // These assets still need foreground reconciliation even if the
        // uploaded receipt's adjustment version already matches.
        var updatedWithoutHashIds = Set<String>()
        if !updatedAssetIds.isEmpty {
            let sql = "SELECT asset_adjustment_version, asset_modification_date FROM hash_cache WHERE asset_id = ? LIMIT 1"
            var versionStmt: OpaquePointer?
            // An older host database may not have the adjustment version
            // column yet. Do not advance token across that schema gap.
            guard sqlite3_prepare_v2(db, sql, -1, &versionStmt, nil) == SQLITE_OK else {
                sqlite3_finalize(versionStmt)
                return nil
            }
            defer { sqlite3_finalize(versionStmt) }

            for assetId in updatedAssetIds {
                sqlite3_reset(versionStmt)
                sqlite3_clear_bindings(versionStmt)
                guard sqlite3_bind_text(versionStmt, 1, assetId, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
                    return nil
                }
                let currentModificationDate = range.states[assetId]?.modificationDate
                let result = sqlite3_step(versionStmt)
                if result == SQLITE_ROW {
                    let storedAdjustmentVersion: String? = {
                        guard let pointer = sqlite3_column_text(versionStmt, 0) else { return nil }
                        return String(cString: pointer)
                    }()
                    guard let currentAdjustmentVersion = range.states[assetId]?.adjustmentVersion else {
                        continue
                    }
                    if let storedAdjustmentVersion, storedAdjustmentVersion != currentAdjustmentVersion {
                        invalidatedUpdatedIds.insert(assetId)
                    } else if storedAdjustmentVersion == nil {
                        let oldDate: TimeInterval? =
                            sqlite3_column_type(versionStmt, 1) == SQLITE_NULL
                            ? nil : sqlite3_column_double(versionStmt, 1)
                        if PhotoAssetVersionPolicy.canReuseCachedHash(
                            storedModificationTime: oldDate,
                            currentModificationDate: currentModificationDate
                        ) {
                            guard updateAdjustmentVersion(
                                db: db, assetId: assetId,
                                modificationDate: currentModificationDate,
                                adjustmentVersion: currentAdjustmentVersion
                            ) else { return nil }
                        } else {
                            // A PhotoKit update on a versionless
                            // legacy asset requires a fresh checksum.
                            invalidatedUpdatedIds.insert(assetId)
                        }
                    } else {
                        guard updateAdjustmentVersion(
                            db: db, assetId: assetId,
                            modificationDate: currentModificationDate,
                            adjustmentVersion: currentAdjustmentVersion
                        ) else { return nil }
                    }
                } else if result == SQLITE_DONE {
                    updatedWithoutHashIds.insert(assetId)
                    // A background upload can finish after foreground
                    // invalidation and create a current receipt before
                    // the hash cache is rebuilt. Preserve only receipts
                    // carrying the current adjustment version.
                    if let currentAdjustmentVersion = range.states[assetId]?.adjustmentVersion,
                       !uploadedReceiptMatchesCurrentAdjustmentVersion(
                           db: db, assetId: assetId, adjustmentVersion: currentAdjustmentVersion
                       ) {
                        invalidatedUpdatedIds.insert(assetId)
                    }
                } else {
                    return nil
                }
            }
        }

        // Only real/unknown version changes invalidate hashes, upload receipts,
        // and completed jobs. Active jobs are still handled by PhotoKit.
        for sql in [
            "DELETE FROM uploaded_assets WHERE asset_id = ?",
            "DELETE FROM hash_cache WHERE asset_id = ?",
            "DELETE FROM upload_jobs WHERE asset_id = ? AND status = 'completed'",
        ] {
            guard run(db: db, sql: sql, ids: invalidatedUpdatedIds) else { return nil }
        }

        // The foreground may have invalidated an old upload receipt,
        // rehashed the changed asset, and saved a matching current version
        // before this extension processes its PhotoKit token. A completed
        // job without its resource receipt is stale even when hash dates now
        // match: remove it so createOrUpdateJob can track its replacement.
        guard run(db: db, sql: """
            DELETE FROM upload_jobs
            WHERE asset_id = ? AND status = 'completed'
              AND NOT EXISTS (
                  SELECT 1 FROM uploaded_assets AS receipt
                  WHERE receipt.asset_id = upload_jobs.asset_id
                    AND receipt.resource_type = upload_jobs.resource_type
              )
            """, ids: updatedAssetIds) else { return nil }

        // Only enqueue new assets, genuinely changed/unknown resource
        // versions, or updates without foreground hash evidence. Unchanged
        // cached hashes were already verified above; queuing those updates
        // forces thousands of redundant foreground reads.
        //
        // Never DELETE previously queued IDs here. Foreground may have
        // queued newer work while the extension was checking an older event.
        let foregroundCandidates = insertedAssetIds
            .union(invalidatedUpdatedIds)
            .union(updatedWithoutHashIds)
            .subtracting(deletedAssetIds)
        let foregroundVerifiedSkipped = updatedAssetIds
            .subtracting(deletedAssetIds)
            .subtracting(foregroundCandidates)
        guard run(
            db: db,
            sql: "INSERT OR IGNORE INTO foreground_photo_pending_assets(asset_id) VALUES (?)",
            ids: foregroundCandidates
        ),
        run(db: db, sql: "DELETE FROM foreground_photo_pending_assets WHERE asset_id = ?", ids: deletedAssetIds),
        run(db: db, sql: "DELETE FROM background_upload_queue WHERE asset_id = ?", ids: deletedAssetIds)
        else { return nil }

        return PhotoAssetChangeCommitSummary(
            retainedVersions: updatedAssetIds.count - invalidatedUpdatedIds.count,
            invalidatedVersions: invalidatedUpdatedIds.count,
            foregroundCandidatesQueued: foregroundCandidates.count,
            foregroundVerifiedSkipped: foregroundVerifiedSkipped.count
        )
    }

    // MARK: - Foreground effects

    /// Hash cache reconciliation, foreground pending work, deletion cleanup and
    /// the local inventory (membership + hidden state). `states` must be in a
    /// stable order: `visitVisibleState` reports the stored modification date of
    /// each visible state in that order for diagnostics.
    static func applyForegroundEffects(
        db: OpaquePointer,
        states: [PhotoAssetChangeState],
        pendingIdentifiers: Set<String>,
        deletedIdentifiers: Set<String>,
        visitVisibleState: ((Int, Date?) -> Void)? = nil
    ) -> ForegroundPhotoEffectCounters? {
        var counters = ForegroundPhotoEffectCounters()
        var resolvedPendingIdentifiers = Set<String>()

        // PhotoKit inserts/updates are not necessarily content edits:
        // modificationDate is a PhotoKit record timestamp, not a byte
        // version. Compare adjustment versions instead.
        var modified = Set<String>()
        var statement: OpaquePointer?
        var updateStatement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
            sqlite3_finalize(updateStatement)
        }
        guard sqlite3_prepare_v2(
            db,
            "SELECT asset_modification_date, asset_adjustment_version FROM hash_cache WHERE asset_id = ?;",
            -1, &statement, nil
        ) == SQLITE_OK,
        sqlite3_prepare_v2(
            db,
            "UPDATE hash_cache SET asset_modification_date = ?, asset_adjustment_version = ? WHERE asset_id = ?;",
            -1, &updateStatement, nil
        ) == SQLITE_OK else { return nil }

        func refreshCachedVersion(_ state: PhotoAssetChangeState, version: String) -> Bool {
            sqlite3_reset(updateStatement)
            sqlite3_clear_bindings(updateStatement)
            if let date = state.modificationDate {
                sqlite3_bind_double(updateStatement, 1, date.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(updateStatement, 1)
            }
            sqlite3_bind_text(updateStatement, 2, version, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(updateStatement, 3, state.localIdentifier, -1, SQLITE_TRANSIENT)
            return sqlite3_step(updateStatement) == SQLITE_DONE
        }

        for (index, state) in states.enumerated() where !state.isHidden {
            var storedDate: Date?
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, state.localIdentifier, -1, SQLITE_TRANSIENT)
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                if sqlite3_column_type(statement, 0) != SQLITE_NULL {
                    storedDate = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
                }
                let storedAdjustmentVersion: String? = {
                    guard let pointer = sqlite3_column_text(statement, 1) else { return nil }
                    return String(cString: pointer)
                }()

                if let currentAdjustmentVersion = state.adjustmentVersion {
                    if let storedAdjustmentVersion {
                        if currentAdjustmentVersion != storedAdjustmentVersion {
                            counters.invalidatedAdjustmentVersion += 1
                            counters.recordCacheDetail(
                                "Foreground hash cache invalidated: asset=\(state.localIdentifier), reason=adjustment_version_changed"
                            )
                            modified.insert(state.localIdentifier)
                        } else {
                            counters.unchangedCached += 1
                            resolvedPendingIdentifiers.insert(state.localIdentifier)
                            guard refreshCachedVersion(state, version: currentAdjustmentVersion) else { return nil }
                        }
                    } else if let storedDate, let currentDate = state.modificationDate,
                              storedDate == currentDate {
                        counters.unchangedCached += 1
                        resolvedPendingIdentifiers.insert(state.localIdentifier)
                        guard refreshCachedVersion(state, version: currentAdjustmentVersion) else { return nil }
                    } else {
                        // No historical date or a different date cannot
                        // establish byte-equivalent legacy data.
                        counters.missingAdjustmentVersion += 1
                        modified.insert(state.localIdentifier)
                    }
                } else {
                    // No current version (not requested or not resolvable).
                    // Absence of evidence never discards a valid hash.
                    counters.unknownAdjustmentVersion += 1
                    counters.unchangedCached += 1
                    counters.recordCacheDetail(
                        "Foreground hash cache retained: asset=\(state.localIdentifier), reason=adjustment_version_unavailable"
                    )
                }
            } else if step == SQLITE_DONE {
                counters.missingCache += 1
                counters.recordCacheDetail(
                    "Foreground PhotoKit asset has no prior hash cache: asset=\(state.localIdentifier)"
                )
            } else {
                return nil
            }
            if state.modificationDate == nil {
                counters.missingCurrentDate += 1
            }
            visitVisibleState?(index, storedDate)
        }

        let hiddenIDs = Set(states.filter(\.isHidden).map(\.localIdentifier))
        guard run(db: db, sql: "DELETE FROM hash_cache WHERE asset_id = ?;", ids: modified),
              run(db: db, sql: "DELETE FROM uploaded_assets WHERE asset_id = ?;", ids: modified),
              run(db: db, sql: "DELETE FROM foreground_photo_pending_assets WHERE asset_id = ?;", ids: hiddenIDs),
              run(
                db: db,
                sql: "INSERT OR IGNORE INTO foreground_photo_pending_assets(asset_id) VALUES (?);",
                ids: pendingIdentifiers.subtracting(hiddenIDs).subtracting(deletedIdentifiers)
              ),
              run(
                db: db,
                sql: "DELETE FROM foreground_photo_pending_assets WHERE asset_id = ?;",
                ids: resolvedPendingIdentifiers.subtracting(modified)
              )
        else { return nil }

        // Only explicit persistent deletions are authoritative here,
        // never a temporarily unresolvable PHAsset fetch result.
        for sql in [
            "DELETE FROM hash_cache WHERE asset_id = ?;",
            "DELETE FROM uploaded_assets WHERE asset_id = ?;",
            "DELETE FROM foreground_photo_pending_assets WHERE asset_id = ?;",
            "DELETE FROM background_upload_queue WHERE asset_id = ?;",
            "DELETE FROM upload_jobs WHERE asset_id = ? AND status IN ('pending', 'failed');",
        ] {
            guard run(db: db, sql: sql, ids: deletedIdentifiers) else { return nil }
        }

        // Keep inaccessible assets until an explicit deletion event.
        // Hidden changes and additions update the persistent inventory.
        var inventoryUpsert: OpaquePointer?
        defer { sqlite3_finalize(inventoryUpsert) }
        guard sqlite3_prepare_v2(
            db,
            "INSERT OR REPLACE INTO local_photo_assets(asset_id, is_hidden) VALUES (?, ?);",
            -1, &inventoryUpsert, nil
        ) == SQLITE_OK else { return nil }
        for state in states where !deletedIdentifiers.contains(state.localIdentifier) {
            sqlite3_reset(inventoryUpsert)
            sqlite3_clear_bindings(inventoryUpsert)
            guard sqlite3_bind_text(inventoryUpsert, 1, state.localIdentifier, -1, SQLITE_TRANSIENT) == SQLITE_OK,
                  sqlite3_bind_int(inventoryUpsert, 2, state.isHidden ? 1 : 0) == SQLITE_OK,
                  sqlite3_step(inventoryUpsert) == SQLITE_DONE
            else { return nil }
        }
        guard run(db: db, sql: "DELETE FROM local_photo_assets WHERE asset_id = ?;", ids: deletedIdentifiers)
        else { return nil }
        return counters
    }

    // MARK: - Helpers

    private static func run(
        db: OpaquePointer,
        sql: String,
        ids: Set<String>,
        extra: ((OpaquePointer?) -> Bool)? = nil
    ) -> Bool {
        guard !ids.isEmpty else { return true }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        for id in ids {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            guard sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT) == SQLITE_OK,
                  extra?(statement) ?? true,
                  sqlite3_step(statement) == SQLITE_DONE
            else { return false }
        }
        return true
    }

    private static func bind(_ data: Data, to statement: OpaquePointer?, index: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
        } == SQLITE_OK
    }

    /// `.some(nil)` means the row is absent; `nil` reports a SQL error.
    private static func readBlob(db: OpaquePointer, sql: String) -> Data?? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let blob = sqlite3_column_blob(statement, 0) else { return .some(nil) }
            return .some(Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0))))
        case SQLITE_DONE:
            return .some(nil)
        default:
            return nil
        }
    }

    private static func readInt(db: OpaquePointer, sql: String) -> Int?? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return .some(Int(sqlite3_column_int(statement, 0)))
        case SQLITE_DONE:
            return .some(nil)
        default:
            return nil
        }
    }

    private static func updateAdjustmentVersion(
        db: OpaquePointer,
        assetId: String,
        modificationDate: Date?,
        adjustmentVersion: String
    ) -> Bool {
        let sql = "UPDATE hash_cache SET asset_modification_date = ?, asset_adjustment_version = ? WHERE asset_id = ?"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        if let modificationDate {
            sqlite3_bind_double(statement, 1, modificationDate.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 1)
        }
        sqlite3_bind_text(statement, 2, adjustmentVersion, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, assetId, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private static func uploadedReceiptMatchesCurrentAdjustmentVersion(
        db: OpaquePointer,
        assetId: String,
        adjustmentVersion: String
    ) -> Bool {
        let sql = """
            SELECT COUNT(*),
                   SUM(CASE WHEN asset_adjustment_version = ? THEN 1 ELSE 0 END)
            FROM uploaded_assets
            WHERE asset_id = ?
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(statement, 1, adjustmentVersion, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, assetId, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        let receiptCount = Int(sqlite3_column_int(statement, 0))
        let matchingCount = Int(sqlite3_column_int(statement, 1))
        return receiptCount > 0 && matchingCount == receiptCount
    }
}
