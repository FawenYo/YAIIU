import Foundation
import Photos
import SQLite3

enum HashFailureRetryPolicy {
    static let delays: [TimeInterval] = [
        15 * 60,
        60 * 60,
        6 * 60 * 60,
        24 * 60 * 60,
        3 * 24 * 60 * 60,
        7 * 24 * 60 * 60
    ]

    static func delay(afterFailureCount count: Int) -> TimeInterval {
        let index = min(max(count - 1, 0), delays.count - 1)
        return delays[index]
    }
}

final class HashCacheRepository {
    private let connection: SQLiteConnection
    
    init(connection: SQLiteConnection = .shared) {
        self.connection = connection
    }
    
    // MARK: - Save Methods
    
    /// Atomically verify the current server catalog and record a single-
    /// resource iCloud match. A concurrent deletion/update cannot slip
    /// between the checksum lookup and the cache write. Existing hash rows
    /// (possibly holding RAW metadata) are never replaced.
    @discardableResult
    func saveCurrentICloudIDMatch(
        localIdentifier: String,
        iCloudId: String,
        expectedChecksum: String,
        modificationDate: Date?
    ) -> Bool {
        connection.ensureInitialized()
        return connection.dbQueue.sync { [weak self] in
            guard let self else { return false }
            let sql = """
                INSERT INTO hash_cache
                    (asset_id, sha1_hash, is_on_server, calculated_at, checked_at,
                     raw_hash, raw_on_server, has_raw, asset_modification_date)
                SELECT ?, COALESCE(s.source_checksum, s.checksum), 1, ?, ?,
                       NULL, 0, 0, ?
                FROM server_assets_cache AS s
                WHERE s.icloud_id = ?
                  AND COALESCE(s.source_checksum, s.checksum) = ?
                  AND NOT EXISTS (
                      SELECT 1 FROM hash_cache AS h WHERE h.asset_id = ?
                  )
                LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(self.connection.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                return false
            }
            defer { sqlite3_finalize(stmt) }
            let timestamp = Date().timeIntervalSince1970
            sqlite3_bind_text(stmt, 1, (localIdentifier as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, timestamp)
            sqlite3_bind_double(stmt, 3, timestamp)
            if let modificationDate {
                sqlite3_bind_double(stmt, 4, modificationDate.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_text(stmt, 5, (iCloudId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 6, (expectedChecksum as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 7, (localIdentifier as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            let inserted = sqlite3_changes(self.connection.db) == 1
            if inserted {
                // iCloud ID is sufficient to confirm the primary, but a
                // separately required Live Photo video may still be missing.
                // Unlike the normal hash writer, this shortcut has checked_at
                // set immediately and will not enter the per-asset server check.
                self.enqueueIfMissingOnServerInternal(localIdentifier: localIdentifier)
            }
            return inserted
        }
    }

    func saveHashCache(localIdentifier: String, sha1Hash: String) {
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            self.saveHashCacheInternal(localIdentifier: localIdentifier, sha1Hash: sha1Hash, rawHash: nil, hasRAW: false, modificationDate: nil)
        }
    }

    func saveMultiResourceHashCache(
        localIdentifier: String,
        primaryHash: String,
        rawHash: String?,
        hasRAW: Bool,
        modificationDate: Date? = nil
    ) {
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            self.saveHashCacheInternal(
                localIdentifier: localIdentifier,
                sha1Hash: primaryHash,
                rawHash: rawHash,
                hasRAW: hasRAW,
                modificationDate: modificationDate
            )
        }
    }

    private func saveHashCacheInternal(
        localIdentifier: String,
        sha1Hash: String,
        rawHash: String?,
        hasRAW: Bool,
        modificationDate: Date?
    ) {
        let sql = """
        INSERT OR REPLACE INTO hash_cache
        (asset_id, sha1_hash, is_on_server, calculated_at, raw_hash, raw_on_server, has_raw, asset_modification_date)
        VALUES (?, ?, 0, ?, ?, 0, ?, ?);
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (localIdentifier as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (sha1Hash as NSString).utf8String, -1, nil)
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)

            if let rawHash = rawHash {
                sqlite3_bind_text(statement, 4, (rawHash as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(statement, 4)
            }

            sqlite3_bind_int(statement, 5, hasRAW ? 1 : 0)

            if let modDate = modificationDate {
                sqlite3_bind_double(statement, 6, modDate.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 6)
            }

            if sqlite3_step(statement) == SQLITE_DONE {
                clearHashFailureInternal(localIdentifier: localIdentifier)
                reconcileRecentUploadsForNewHashInternal(
                    localIdentifier: localIdentifier, hasRAW: hasRAW
                )
            }
        }

        sqlite3_finalize(statement)
    }

    /// A resource may upload before PhotoKit SHA1 was available. Retain its
    /// locally confirmed upload in uploaded_assets, then restore that evidence
    /// when its hash is first persisted. Only current-destination, post-sync
    /// upload records count; older history is not authoritative.
    private func reconcileRecentUploadsForNewHashInternal(
        localIdentifier: String, hasRAW: Bool
    ) {
        let sql = """
            SELECT resource_type FROM uploaded_assets
            WHERE asset_id = ?
              AND destination_identity IS NOT NULL
              AND uploaded_at > COALESCE(
                  (SELECT b.snapshot_started_at FROM sync_snapshot_boundaries b
                   WHERE b.id = 1
                     AND b.destination_identity = uploaded_assets.destination_identity),
                  (SELECT last_sync_time FROM sync_metadata WHERE id = 1), 0
              )
              AND (
                  NOT EXISTS (SELECT 1 FROM background_upload_state WHERE id = 1)
                  OR destination_identity = (
                      SELECT destination_identity FROM background_upload_state WHERE id = 1
                  )
              );
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection.db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return
        }
        sqlite3_bind_text(stmt, 1, (localIdentifier as NSString).utf8String, -1, nil)
        var primaryPresent = false
        var rawPresent = false
        let hasLiveVideo = hasLivePhotoVideoRequirementInternal(localIdentifier: localIdentifier)
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let p = sqlite3_column_text(stmt, 0) else { continue }
            let resourceType = String(cString: p)
            if resourceType == "raw" && hasRAW {
                rawPresent = true
            } else if resourceType != "video" || !hasLiveVideo {
                primaryPresent = true
            }
        }
        sqlite3_finalize(stmt)
        guard primaryPresent || rawPresent else { return }

        let updateSQL = """
            UPDATE hash_cache
            SET is_on_server = ?,
                raw_on_server = ?,
                checked_at = ?,
                server_check_revision = server_check_revision + 1
            WHERE asset_id = ?;
        """
        guard sqlite3_prepare_v2(connection.db, updateSQL, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return
        }
        sqlite3_bind_int(stmt, 1, primaryPresent ? 1 : 0)
        sqlite3_bind_int(stmt, 2, rawPresent ? 1 : 0)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 4, (localIdentifier as NSString).utf8String, -1, nil)
        let updated = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        if updated {
            enqueueIfMissingOnServerInternal(localIdentifier: localIdentifier)
        }
    }
    
    func batchSaveHashCache(items: [(localIdentifier: String, sha1Hash: String, fileSize: Int64, syncStatus: String)]) {
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            self.connection.beginTransaction()
            
            for item in items {
                self.saveHashCacheInternal(
                    localIdentifier: item.localIdentifier,
                    sha1Hash: item.sha1Hash,
                    rawHash: nil,
                    hasRAW: false,
                    modificationDate: nil
                )
            }
            
            self.connection.commitTransaction()
        }
    }
    
    // MARK: - Hash Failure Backoff

    func recordHashFailure(
        localIdentifier: String,
        errorMessage: String,
        modificationDate: Date?
    ) {
        connection.dbQueue.sync { [weak self] in
            guard let self else { return }

            var retryCount = 0
            var countStatement: OpaquePointer?
            let countSql = "SELECT retry_count FROM hash_failures WHERE asset_id = ?;"
            if sqlite3_prepare_v2(self.connection.db, countSql, -1, &countStatement, nil) == SQLITE_OK {
                sqlite3_bind_text(countStatement, 1, (localIdentifier as NSString).utf8String, -1, nil)
                if sqlite3_step(countStatement) == SQLITE_ROW {
                    retryCount = Int(sqlite3_column_int(countStatement, 0))
                }
            }
            sqlite3_finalize(countStatement)

            let nextRetryCount = retryCount + 1
            let now = Date().timeIntervalSince1970
            let retryAfter = now + HashFailureRetryPolicy.delay(
                afterFailureCount: nextRetryCount
            )

            let sql = """
                INSERT INTO hash_failures
                    (asset_id, failed_at, retry_after, retry_count, error_message, asset_modification_date)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET
                    failed_at = excluded.failed_at,
                    retry_after = excluded.retry_after,
                    retry_count = excluded.retry_count,
                    error_message = excluded.error_message,
                    asset_modification_date = excluded.asset_modification_date;
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                return
            }

            sqlite3_bind_text(statement, 1, (localIdentifier as NSString).utf8String, -1, nil)
            sqlite3_bind_double(statement, 2, now)
            sqlite3_bind_double(statement, 3, retryAfter)
            sqlite3_bind_int(statement, 4, Int32(nextRetryCount))
            sqlite3_bind_text(statement, 5, (errorMessage as NSString).utf8String, -1, nil)
            if let modificationDate {
                sqlite3_bind_double(statement, 6, modificationDate.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 6)
            }

            if sqlite3_step(statement) != SQLITE_DONE {
                logError(
                    "Failed to persist hash failure backoff for \(localIdentifier)",
                    category: .database
                )
            }
            sqlite3_finalize(statement)
        }
    }

    private func clearHashFailureInternal(localIdentifier: String) {
        let sql = "DELETE FROM hash_failures WHERE asset_id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return
        }
        sqlite3_bind_text(statement, 1, (localIdentifier as NSString).utf8String, -1, nil)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    // MARK: - Query Methods
    
    func getHashCache(localIdentifier: String) -> HashCacheRecord? {
        connection.ensureInitialized()
        var record: HashCacheRecord?
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            record = self.getHashCacheInternal(localIdentifier: localIdentifier)
        }
        
        return record
    }
    
    private func getHashCacheInternal(localIdentifier: String) -> HashCacheRecord? {
        let sql = "SELECT * FROM hash_cache WHERE asset_id = ?;"
        var statement: OpaquePointer?
        var record: HashCacheRecord?
        
        if sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (localIdentifier as NSString).utf8String, -1, nil)
            
            if sqlite3_step(statement) == SQLITE_ROW {
                let calculatedAt = sqlite3_column_double(statement, 4)
                let checkedAt = sqlite3_column_type(statement, 5) != SQLITE_NULL ? sqlite3_column_double(statement, 5) : 0
                
                record = HashCacheRecord(
                    id: Int(sqlite3_column_int(statement, 0)),
                    localIdentifier: String(cString: sqlite3_column_text(statement, 1)),
                    sha1Hash: String(cString: sqlite3_column_text(statement, 2)),
                    fileSize: 0,
                    syncStatus: sqlite3_column_int(statement, 3) == 1 ? "checked" : "pending",
                    isOnServer: sqlite3_column_int(statement, 3) == 1,
                    calculatedAt: String(format: "%.0f", calculatedAt),
                    checkedAt: checkedAt > 0 ? String(format: "%.0f", checkedAt) : nil
                )
            }
        }
        
        sqlite3_finalize(statement)
        return record
    }
    
    // MARK: - Update Methods
    
    func updateHashCacheServerStatus(localIdentifier: String, isOnServer: Bool) {
        connection.ensureInitialized()
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            guard self.connection.beginTransaction() else { return }
            self.updateHashCacheServerStatusInternal(localIdentifier: localIdentifier, isOnServer: isOnServer)
            if self.connection.commitTransaction() == false {
                self.connection.rollbackTransaction()
            }
        }
    }
    
    private func updateHashCacheServerStatusInternal(localIdentifier: String, isOnServer: Bool) {
        let sql = """
        UPDATE hash_cache
        SET is_on_server = ?, checked_at = ?
        WHERE asset_id = ?;
        """
        
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, isOnServer ? 1 : 0)
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            sqlite3_bind_text(statement, 3, (localIdentifier as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        
        sqlite3_finalize(statement)
        enqueueIfMissingOnServerInternal(localIdentifier: localIdentifier)
    }

    private func enqueueIfMissingOnServerInternal(localIdentifier: String) {
        let sql = """
        INSERT OR IGNORE INTO background_upload_queue (asset_id, enqueued_at)
        SELECT asset_id, ?
        FROM hash_cache
        WHERE asset_id = ?
          AND checked_at IS NOT NULL
          AND (is_on_server = 0 OR (has_raw = 1 AND raw_on_server = 0)
               OR EXISTS (
                   SELECT 1 FROM live_photo_video_status v
                   WHERE v.asset_id = hash_cache.asset_id AND v.video_on_server = 0
               ));
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, (localIdentifier as NSString).utf8String, -1, nil)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }
    
    private func hasLivePhotoVideoRequirementInternal(localIdentifier: String) -> Bool {
        let sql = "SELECT 1 FROM live_photo_video_status WHERE asset_id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(connection.db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        sqlite3_bind_text(stmt, 1, (localIdentifier as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Do not overwrite a server delta with a verdict computed against an
    /// earlier catalog revision.
    @discardableResult
    func updateMultiResourceHashCacheServerStatusIfCurrent(
        localIdentifier: String,
        primaryOnServer: Bool,
        rawOnServer: Bool,
        expectedRevision: Int64
    ) -> Bool {
        connection.ensureInitialized()
        return connection.dbQueue.sync { [weak self] in
            guard let self, self.connection.beginTransaction() else { return false }
            let sql = """
                UPDATE hash_cache
                SET is_on_server = ?, raw_on_server = ?, checked_at = ?
                WHERE asset_id = ? AND checked_at IS NULL
                  AND server_check_revision = ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                self.connection.rollbackTransaction()
                return false
            }
            sqlite3_bind_int(statement, 1, primaryOnServer ? 1 : 0)
            sqlite3_bind_int(statement, 2, rawOnServer ? 1 : 0)
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
            sqlite3_bind_text(statement, 4, (localIdentifier as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(statement, 5, expectedRevision)
            let updated = sqlite3_step(statement) == SQLITE_DONE
                && sqlite3_changes(self.connection.db) == 1
            sqlite3_finalize(statement)
            if updated {
                self.enqueueIfMissingOnServerInternal(localIdentifier: localIdentifier)
            }
            guard self.connection.commitTransaction() else {
                self.connection.rollbackTransaction()
                return false
            }
            return updated
        }
    }

    func updateMultiResourceHashCacheServerStatus(
        localIdentifier: String,
        primaryOnServer: Bool,
        rawOnServer: Bool
    ) {
        connection.ensureInitialized()
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            guard self.connection.beginTransaction() else { return }
            self.updateMultiResourceHashCacheServerStatusInternal(
                localIdentifier: localIdentifier,
                primaryOnServer: primaryOnServer,
                rawOnServer: rawOnServer
            )
            if self.connection.commitTransaction() == false {
                self.connection.rollbackTransaction()
            }
        }
    }
    
    private func updateMultiResourceHashCacheServerStatusInternal(
        localIdentifier: String,
        primaryOnServer: Bool,
        rawOnServer: Bool
    ) {
        let sql = """
        UPDATE hash_cache
        SET is_on_server = ?, raw_on_server = ?, checked_at = ?
        WHERE asset_id = ?;
        """
        
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, primaryOnServer ? 1 : 0)
            sqlite3_bind_int(statement, 2, rawOnServer ? 1 : 0)
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
            sqlite3_bind_text(statement, 4, (localIdentifier as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        
        sqlite3_finalize(statement)
        enqueueIfMissingOnServerInternal(localIdentifier: localIdentifier)
    }
    
    func batchUpdateHashCacheServerStatus(results: [(String, Bool)]) {
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            self.connection.beginTransaction()
            
            for (localIdentifier, isOnServer) in results {
                self.updateHashCacheServerStatusInternal(localIdentifier: localIdentifier, isOnServer: isOnServer)
            }
            
            self.connection.commitTransaction()
        }
    }
    
    // MARK: - Async Query Methods
    
    func getAssetsOnServerAsync(completion: @escaping (Set<String>) -> Void) {
        connection.dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            
            let sql = "SELECT asset_id FROM hash_cache WHERE is_on_server = 1;"
            var statement: OpaquePointer?
            var ids: Set<String> = []
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let cString = sqlite3_column_text(statement, 0) {
                        let identifier = String(cString: cString)
                        if !identifier.isEmpty {
                            ids.insert(identifier)
                        }
                    }
                }
            }
            
            sqlite3_finalize(statement)
            
            DispatchQueue.main.async {
                completion(ids)
            }
        }
    }
    
    /// Metadata backfill is independent of the hash/server-presence check.
    /// A complete server snapshot can mark hashes checked without losing
    /// iCloud-ID backfill for owned primary and RAW companion assets that still
    /// have missing metadata.
    func getMissingICloudIDBackfillCandidatesAsync(
        completion: @escaping ([(localIdentifier: String, immichId: String, sourceChecksum: String?)]) -> Void
    ) {
        connection.dbQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let sql = """
                SELECT h.asset_id, s.immich_id, s.source_checksum
                FROM hash_cache AS h
                JOIN server_assets_cache AS s
                  ON (h.is_on_server = 1 AND (
                      s.source_checksum = h.sha1_hash
                      OR (s.source_checksum IS NULL AND s.checksum = h.sha1_hash)
                  ))
                  OR (h.has_raw = 1 AND h.raw_on_server = 1
                      AND h.raw_hash IS NOT NULL AND (
                          s.source_checksum = h.raw_hash
                          OR (s.source_checksum IS NULL AND s.checksum = h.raw_hash)
                      ))
                JOIN sync_metadata AS m
                  ON m.id = 1 AND s.owner_id = m.user_id
                WHERE h.checked_at IS NOT NULL
                  AND (s.icloud_id IS NULL OR s.icloud_id = '');
            """
            var statement: OpaquePointer?
            var candidates: [(localIdentifier: String, immichId: String, sourceChecksum: String?)] = []
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let localPtr = sqlite3_column_text(statement, 0),
                          let remotePtr = sqlite3_column_text(statement, 1) else { continue }
                    candidates.append((
                        localIdentifier: String(cString: localPtr),
                        immichId: String(cString: remotePtr),
                        sourceChecksum: sqlite3_column_text(statement, 2).map { String(cString: $0) }
                    ))
                }
            }
            sqlite3_finalize(statement)
            DispatchQueue.main.async { completion(candidates) }
        }
    }

    func getAllSyncStatusAsync(uploadedResourceTypes: [String: Set<String>], hasServerCache: Bool, completion: @escaping ([String: PhotoSyncStatus]) -> Void) {
        connection.dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([:]) }
                return
            }
            
            var statusMap: [String: PhotoSyncStatus] = [:]
            var statement: OpaquePointer?
            
            var livePhotoIds: Set<String> = []
            var missingLiveVideos: Set<String> = []
            if sqlite3_prepare_v2(
                self.connection.db,
                "SELECT asset_id, video_on_server FROM live_photo_video_status;",
                -1, &statement, nil
            ) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let ptr = sqlite3_column_text(statement, 0) {
                        let id = String(cString: ptr)
                        livePhotoIds.insert(id)
                        if sqlite3_column_int(statement, 1) == 0 {
                            missingLiveVideos.insert(id)
                        }
                    }
                }
            }
            sqlite3_finalize(statement)
            statement = nil

            let hashSql = "SELECT asset_id, is_on_server, checked_at, raw_hash, raw_on_server, has_raw FROM hash_cache;"
            if sqlite3_prepare_v2(self.connection.db, hashSql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let cString = sqlite3_column_text(statement, 0) {
                        let identifier = String(cString: cString)
                        let primaryOnServer = sqlite3_column_int(statement, 1) == 1
                        let hasBeenChecked = sqlite3_column_type(statement, 2) != SQLITE_NULL
                        let hasRAW = sqlite3_column_int(statement, 5) == 1
                        let rawOnServer = sqlite3_column_int(statement, 4) == 1
                        
                        let uploadedTypes = uploadedResourceTypes[identifier] ?? []
                        let isLivePhoto = livePhotoIds.contains(identifier)
                        let hasUploadedNonRAW = uploadedTypes.contains {
                            $0 != "raw" && (!isLivePhoto || $0 != "video")
                        }
                        let hasUploadedRAW = uploadedTypes.contains("raw")
                        
                        // A completed server-catalog lookup is the current
                        // upload verdict. Historical uploaded_assets rows are
                        // NOT proof of existence after a server-side deletion.
                        // checked_at controls rechecking, not the display label.
                        if hasBeenChecked && hasServerCache {
                            let fullyOnServer = primaryOnServer && (!hasRAW || rawOnServer)
                                && !missingLiveVideos.contains(identifier)
                            statusMap[identifier] = fullyOnServer ? .uploaded : .notUploaded
                        } else if hasServerCache {
                            // This photo is still awaiting a server verdict.
                            statusMap[identifier] = .pending
                        } else {
                            // Preserve the original offline/fallback behavior
                            // until an authoritative server snapshot exists.
                            let isFullyUploaded: Bool
                            if hasRAW {
                                isFullyUploaded = (hasUploadedNonRAW || primaryOnServer)
                                    && (hasUploadedRAW || rawOnServer)
                            } else {
                                isFullyUploaded = hasUploadedNonRAW
                                    || (!isLivePhoto && hasUploadedRAW) || primaryOnServer
                            }
                            statusMap[identifier] = (isFullyUploaded
                                && (!missingLiveVideos.contains(identifier) || uploadedTypes.contains("video")))
                                ? .uploaded : .notUploaded
                        }
                    }
                }
            }
            sqlite3_finalize(statement)

            let failureSql = "SELECT asset_id FROM hash_failures WHERE retry_after > ?;"
            if sqlite3_prepare_v2(self.connection.db, failureSql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let cString = sqlite3_column_text(statement, 0) {
                        let identifier = String(cString: cString)
                        if statusMap[identifier] == nil {
                            statusMap[identifier] = .error
                        }
                    }
                }
            }
            sqlite3_finalize(statement)
            
            DispatchQueue.main.async {
                completion(statusMap)
            }
        }
    }
    
    /// The FIRST stage of normal sync: use the durable SQLite server verdict
    /// to exclude assets that are already confirmed completely uploaded.
    /// A JPEG+RAW pair is complete only when both resource flags are true.
    /// Unknown/stale/unchecked records must remain eligible for verification.
    /// Keep the caller's Photos ordering and fail open if SQLite cannot read.
    func getAssetsNotFullyUploadedAsync(
        allIdentifiers: [String],
        completion: @escaping ([String]) -> Void
    ) {
        connection.dbQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(allIdentifiers) }
                return
            }
            let sql = """
                SELECT asset_id FROM hash_cache
                WHERE checked_at IS NOT NULL
                  AND is_on_server = 1
                  AND (has_raw = 0 OR raw_on_server = 1)
                  AND NOT EXISTS (
                      SELECT 1 FROM live_photo_video_status v
                      WHERE v.asset_id = hash_cache.asset_id AND v.video_on_server = 0
                  );
            """
            var statement: OpaquePointer?
            var completedIds: Set<String> = []
            guard sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                DispatchQueue.main.async { completion(allIdentifiers) }
                return
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 0) {
                    completedIds.insert(String(cString: text))
                }
            }
            sqlite3_finalize(statement)
            let candidates = allIdentifiers.filter { !completedIds.contains($0) }
            DispatchQueue.main.async { completion(candidates) }
        }
    }

    func getAssetsNeedingHashAsync(allIdentifiers: [String], completion: @escaping ([String]) -> Void) {
        connection.dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            
            let sql = "SELECT asset_id FROM hash_cache;"
            var statement: OpaquePointer?
            var existingIds: Set<String> = []
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let cString = sqlite3_column_text(statement, 0) {
                        existingIds.insert(String(cString: cString))
                    }
                }
            }
            sqlite3_finalize(statement)

            // Every uncached asset can still use the metadata-only iCloud ID
            // shortcut, even when a past requestData hashing failure is backed off.
            let needingHash = allIdentifiers.filter { !existingIds.contains($0) }
            
            DispatchQueue.main.async {
                completion(needingHash)
            }
        }
    }
    
    /// Apply expensive PhotoKit requestData retry backoff ONLY after iCloud
    /// matching has had a chance to resolve the asset without a download.
    func getAssetsEligibleForHashRetryAsync(
        allIdentifiers: [String], completion: @escaping ([String]) -> Void
    ) {
        connection.dbQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            var deferred: Set<String> = []
            var stmt: OpaquePointer?
            let sql = "SELECT asset_id FROM hash_failures WHERE retry_after > ?;"
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let ptr = sqlite3_column_text(stmt, 0) {
                        deferred.insert(String(cString: ptr))
                    }
                }
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async {
                completion(allIdentifiers.filter { !deferred.contains($0) })
            }
        }
    }

    func getHashesNeedingCheckAsync(completion: @escaping ([(String, String)]) -> Void) {
        connection.dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            
            let sql = "SELECT asset_id, sha1_hash FROM hash_cache WHERE is_on_server = 0;"
            var statement: OpaquePointer?
            var hashes: [(String, String)] = []
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let idCString = sqlite3_column_text(statement, 0),
                       let hashCString = sqlite3_column_text(statement, 1) {
                        let identifier = String(cString: idCString)
                        let hash = String(cString: hashCString)
                        hashes.append((identifier, hash))
                    }
                }
            }
            sqlite3_finalize(statement)
            
            DispatchQueue.main.async {
                completion(hashes)
            }
        }
    }
    
    func getHashesNotOnServerAsync(completion: @escaping ([(String, String)]) -> Void) {
        connection.dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            
            let sql = "SELECT asset_id, sha1_hash FROM hash_cache WHERE is_on_server = 0;"
            var statement: OpaquePointer?
            var hashes: [(String, String)] = []
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let idCString = sqlite3_column_text(statement, 0),
                       let hashCString = sqlite3_column_text(statement, 1) {
                        let identifier = String(cString: idCString)
                        let hash = String(cString: hashCString)
                        hashes.append((identifier, hash))
                    }
                }
            }
            sqlite3_finalize(statement)
            
            DispatchQueue.main.async {
                completion(hashes)
            }
        }
    }
    
    func getMultiResourceHashesNotFullyOnServerAsync(completion: @escaping ([MultiResourceHashRecord]) -> Void) {
        connection.dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            
            let sql = """
                SELECT asset_id, sha1_hash, raw_hash, has_raw, is_on_server, raw_on_server, server_check_revision
                FROM hash_cache
                -- Previously checked misses remain cached until relevant server
                -- checksum changes invalidate the server verdict.
                WHERE checked_at IS NULL;
            """
            var statement: OpaquePointer?
            var records: [MultiResourceHashRecord] = []
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let idCString = sqlite3_column_text(statement, 0),
                       let hashCString = sqlite3_column_text(statement, 1) {
                        let assetId = String(cString: idCString)
                        let primaryHash = String(cString: hashCString)
                        let rawHash = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                        let hasRAW = sqlite3_column_int(statement, 3) == 1
                        let primaryOnServer = sqlite3_column_int(statement, 4) == 1
                        let rawOnServer = sqlite3_column_int(statement, 5) == 1
                        let revision = sqlite3_column_int64(statement, 6)

                        records.append(MultiResourceHashRecord(
                            assetId: assetId,
                            primaryHash: primaryHash,
                            rawHash: rawHash,
                            hasRAW: hasRAW,
                            primaryOnServer: primaryOnServer,
                            rawOnServer: rawOnServer,
                            serverCheckRevision: revision
                        ))
                    }
                }
            }
            sqlite3_finalize(statement)
            
            DispatchQueue.main.async {
                completion(records)
            }
        }
    }
    
    // MARK: - Statistics
    
    func getHashCacheStatsAsync(completion: @escaping (Int, Int, Int) -> Void) {
        connection.dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(0, 0, 0) }
                return
            }
            
            var total = 0
            var checked = 0
            var onServer = 0
            var statement: OpaquePointer?
            
            let totalSql = "SELECT COUNT(*) FROM hash_cache;"
            if sqlite3_prepare_v2(self.connection.db, totalSql, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    total = Int(sqlite3_column_int(statement, 0))
                }
            }
            sqlite3_finalize(statement)
            
            let checkedSql = "SELECT COUNT(*) FROM hash_cache WHERE checked_at IS NOT NULL;"
            if sqlite3_prepare_v2(self.connection.db, checkedSql, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    checked = Int(sqlite3_column_int(statement, 0))
                }
            }
            sqlite3_finalize(statement)
            
            let onServerSql = "SELECT COUNT(*) FROM hash_cache WHERE is_on_server = 1;"
            if sqlite3_prepare_v2(self.connection.db, onServerSql, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    onServer = Int(sqlite3_column_int(statement, 0))
                }
            }
            sqlite3_finalize(statement)
            
            DispatchQueue.main.async {
                completion(total, checked, onServer)
            }
        }
    }
    
    // MARK: - Modified Asset Invalidation

    /// Deletes hash_cache and uploaded_assets rows for assets whose modificationDate
    /// has changed since the date was last stored. Assets with NULL stored dates are skipped.
    func resetCacheForModifiedAssets(snapshots: [PhotoAssetSnapshot]) {
        guard !snapshots.isEmpty else { return }

        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            self.resetCacheForModifiedAssetsInternal(snapshots: snapshots)
        }
    }

    /// Update only Live Photo companion presence using lightweight PhotoKit
    /// snapshots; do not request image/video bytes or recompute SHA1.
    private func syncLivePhotoVideoRequirementsInternal(snapshots: [PhotoAssetSnapshot]) {
        let known = Set(snapshots.map { $0.localIdentifier })
        let required = Set(snapshots.filter { $0.hasVideoCompanion }.map { $0.localIdentifier })
        var current: Set<String> = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(
            connection.db, "SELECT asset_id FROM live_photo_video_status;",
            -1, &stmt, nil
        ) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(stmt, 0) {
                    current.insert(String(cString: ptr))
                }
            }
        }
        sqlite3_finalize(stmt)
        let additions = required.subtracting(current)
        let removals = current.intersection(known).subtracting(required)
        guard !additions.isEmpty || !removals.isEmpty else { return }
        guard connection.beginTransaction() else { return }
        let insertSQL = """
            INSERT OR IGNORE INTO live_photo_video_status (asset_id, video_on_server)
            VALUES (?, CASE WHEN EXISTS (
                SELECT 1 FROM uploaded_assets AS u
                WHERE u.asset_id = ? AND u.resource_type = 'video'
                  AND (EXISTS (
                      SELECT 1 FROM server_assets_cache s WHERE s.immich_id = u.immich_id
                  ) OR (u.destination_identity IS NOT NULL
                        AND u.uploaded_at > COALESCE(
                            (SELECT last_sync_time FROM sync_metadata WHERE id = 1), 0
                        )))
            ) THEN 1 ELSE 0 END);
        """
        var insertStmt: OpaquePointer?
        var deleteStmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection.db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(
                  connection.db, "DELETE FROM live_photo_video_status WHERE asset_id = ?;",
                  -1, &deleteStmt, nil
              ) == SQLITE_OK else {
            sqlite3_finalize(insertStmt)
            sqlite3_finalize(deleteStmt)
            connection.rollbackTransaction()
            return
        }
        var failed = false
        for id in additions {
            sqlite3_bind_text(insertStmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStmt, 2, (id as NSString).utf8String, -1, nil)
            if sqlite3_step(insertStmt) != SQLITE_DONE { failed = true; break }
            sqlite3_reset(insertStmt)
            sqlite3_clear_bindings(insertStmt)
        }
        if !failed {
            for id in removals {
                sqlite3_bind_text(deleteStmt, 1, (id as NSString).utf8String, -1, nil)
                if sqlite3_step(deleteStmt) != SQLITE_DONE { failed = true; break }
                sqlite3_reset(deleteStmt)
                sqlite3_clear_bindings(deleteStmt)
            }
        }
        sqlite3_finalize(insertStmt)
        sqlite3_finalize(deleteStmt)
        if failed || !connection.commitTransaction() {
            connection.rollbackTransaction()
            return
        }
        for id in additions {
            enqueueIfMissingOnServerInternal(localIdentifier: id)
        }
    }

    private func resetCacheForModifiedAssetsInternal(snapshots: [PhotoAssetSnapshot]) {
        syncLivePhotoVideoRequirementsInternal(snapshots: snapshots)
        resetModifiedFailureRecords(snapshots: snapshots)

        // Fetch all stored modification dates in one query; NULL means not yet recorded
        let sql = "SELECT asset_id, asset_modification_date FROM hash_cache;"
        var statement: OpaquePointer?
        var storedDates: [String: Double] = [:]      // asset_id -> stored timestamp
        var nullDateIds: Set<String> = []             // asset_id with no stored date yet

        if sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let idCString = sqlite3_column_text(statement, 0) {
                    let assetId = String(cString: idCString)
                    if sqlite3_column_type(statement, 1) == SQLITE_NULL {
                        nullDateIds.insert(assetId)
                    } else {
                        storedDates[assetId] = sqlite3_column_double(statement, 1)
                    }
                }
            }
        }
        sqlite3_finalize(statement)

        // Backfill modificationDate for pre-migration rows that have no stored date.
        // Cannot be done at migration time because PHAsset is unavailable there.
        if !nullDateIds.isEmpty {
            backfillModificationDates(snapshots: snapshots, assetIds: nullDateIds)
        }

        guard !storedDates.isEmpty else { return }

        // Compare current modificationDate against stored date
        var invalidatedIds: [String] = []

        for snapshot in snapshots {
            let identifier = snapshot.localIdentifier
            guard let storedTimestamp = storedDates[identifier] else { continue }
            guard let currentDate = snapshot.modificationDate else { continue }

            let currentTimestamp = currentDate.timeIntervalSince1970
            // Use 1-second tolerance to avoid floating point noise
            if abs(currentTimestamp - storedTimestamp) > 1.0 {
                invalidatedIds.append(identifier)
            }
        }

        guard !invalidatedIds.isEmpty else { return }

        // A changed Live Photo video needs a new server confirmation too.
        for identifier in invalidatedIds {
            var videoStmt: OpaquePointer?
            if sqlite3_prepare_v2(
                connection.db,
                "UPDATE live_photo_video_status SET video_on_server = 0 WHERE asset_id = ?;",
                -1, &videoStmt, nil
            ) == SQLITE_OK {
                sqlite3_bind_text(videoStmt, 1, (identifier as NSString).utf8String, -1, nil)
                sqlite3_step(videoStmt)
            }
            sqlite3_finalize(videoStmt)
        }

        logInfo("Invalidating \(invalidatedIds.count) modified assets", category: .hash)

        // Delete both hash_cache and uploaded_assets for each invalidated asset
        connection.beginTransaction()

        let hashDeleteSql = "DELETE FROM hash_cache WHERE asset_id = ?;"
        let uploadDeleteSql = "DELETE FROM uploaded_assets WHERE asset_id = ?;"

        var hashStmt: OpaquePointer?
        var uploadStmt: OpaquePointer?

        guard sqlite3_prepare_v2(connection.db, hashDeleteSql, -1, &hashStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(connection.db, uploadDeleteSql, -1, &uploadStmt, nil) == SQLITE_OK else {
            sqlite3_finalize(hashStmt)
            sqlite3_finalize(uploadStmt)
            connection.rollbackTransaction()
            return
        }

        var failed = false

        for assetId in invalidatedIds {
            sqlite3_bind_text(hashStmt, 1, (assetId as NSString).utf8String, -1, nil)
            if sqlite3_step(hashStmt) != SQLITE_DONE {
                failed = true
                break
            }
            sqlite3_reset(hashStmt)

            sqlite3_bind_text(uploadStmt, 1, (assetId as NSString).utf8String, -1, nil)
            if sqlite3_step(uploadStmt) != SQLITE_DONE {
                failed = true
                break
            }
            sqlite3_reset(uploadStmt)
        }

        sqlite3_finalize(hashStmt)
        sqlite3_finalize(uploadStmt)

        if failed {
            connection.rollbackTransaction()
        } else {
            connection.commitTransaction()
        }

        logDebug("Invalidated assets: \(invalidatedIds.map { String($0.prefix(20)) })", category: .hash)
    }

    private func resetModifiedFailureRecords(snapshots: [PhotoAssetSnapshot]) {
        let sql = "SELECT asset_id, asset_modification_date FROM hash_failures;"
        var statement: OpaquePointer?
        var storedDates: [String: Double] = [:]
        var nullDateIds: Set<String> = []

        if sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idCString = sqlite3_column_text(statement, 0) else { continue }
                let assetId = String(cString: idCString)
                if sqlite3_column_type(statement, 1) == SQLITE_NULL {
                    nullDateIds.insert(assetId)
                } else {
                    storedDates[assetId] = sqlite3_column_double(statement, 1)
                }
            }
        }
        sqlite3_finalize(statement)

        guard !storedDates.isEmpty || !nullDateIds.isEmpty else { return }

        var toDelete: [String] = []
        for snapshot in snapshots {
            let identifier = snapshot.localIdentifier
            if nullDateIds.contains(identifier), snapshot.modificationDate != nil {
                toDelete.append(identifier)
                continue
            }
            guard let oldTimestamp = storedDates[identifier],
                  let currentDate = snapshot.modificationDate else {
                continue
            }
            if abs(currentDate.timeIntervalSince1970 - oldTimestamp) > 1.0 {
                toDelete.append(identifier)
            }
        }

        guard !toDelete.isEmpty else { return }

        let deleteSql = "DELETE FROM hash_failures WHERE asset_id = ?;"
        guard sqlite3_prepare_v2(connection.db, deleteSql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return
        }
        defer { sqlite3_finalize(statement) }

        for assetId in toDelete {
            sqlite3_bind_text(statement, 1, (assetId as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
    }

    private func backfillModificationDates(snapshots: [PhotoAssetSnapshot], assetIds: Set<String>) {
        let sql = "UPDATE hash_cache SET asset_modification_date = ? WHERE asset_id = ?;"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        connection.beginTransaction()
        var failed = false
        var count = 0
        for snapshot in snapshots {
            guard assetIds.contains(snapshot.localIdentifier),
                  let modDate = snapshot.modificationDate else { continue }

            sqlite3_bind_double(statement, 1, modDate.timeIntervalSince1970)
            sqlite3_bind_text(statement, 2, (snapshot.localIdentifier as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) != SQLITE_DONE {
                failed = true
                break
            }
            count += 1
            sqlite3_reset(statement)
        }

        if failed {
            connection.rollbackTransaction()
            logError("Failed to backfill modification dates, rolling back.", category: .hash)
        } else {
            connection.commitTransaction()
            logInfo("Backfilled modificationDate for \(count) pre-migration hash_cache entries", category: .hash)
        }
    }

    // MARK: - Clear
    
    func clearHashCache() {
        connection.ensureInitialized()
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            self.connection.executeStatement("DELETE FROM hash_cache;")
            self.connection.executeStatement("DELETE FROM hash_failures;")
        }
    }
    
    // MARK: - Orphan Record Cleanup
    
    func deleteHashCacheRecord(localIdentifier: String) {
        connection.dbQueue.async { [weak self] in
            guard let self = self else { return }
            
            let sql = "DELETE FROM hash_cache WHERE asset_id = ?;"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (localIdentifier as NSString).utf8String, -1, nil)
                if sqlite3_step(statement) != SQLITE_DONE {
                    logError("[HashCacheRepository] Error deleting hash cache record: \(String(cString: sqlite3_errmsg(self.connection.db)))")
                }
            } else {
                logError("[HashCacheRepository] Error preparing delete statement: \(String(cString: sqlite3_errmsg(self.connection.db)))")
            }
            sqlite3_finalize(statement)
        }
    }
    
    func batchDeleteHashCacheRecords(localIdentifiers: [String]) {
        guard !localIdentifiers.isEmpty else { return }
        
        connection.dbQueue.async { [weak self] in
            guard let self = self else { return }
            
            let placeholders = localIdentifiers.map { _ in "?" }.joined(separator: ",")
            let sql = "DELETE FROM hash_cache WHERE asset_id IN (\(placeholders));"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                for (index, identifier) in localIdentifiers.enumerated() {
                    sqlite3_bind_text(statement, Int32(index + 1), (identifier as NSString).utf8String, -1, nil)
                }
                if sqlite3_step(statement) != SQLITE_DONE {
                    logError("[HashCacheRepository] Error batch deleting hash cache records: \(String(cString: sqlite3_errmsg(self.connection.db)))")
                }
            } else {
                logError("[HashCacheRepository] Error preparing batch delete statement: \(String(cString: sqlite3_errmsg(self.connection.db)))")
            }
            sqlite3_finalize(statement)
        }
    }
}
