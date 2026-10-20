import Foundation
import Photos
import SQLite3


struct CloudMetadataCandidate {
    let assetId: String
    let immichId: String
    let serverICloudId: String?
    let sourceChecksum: String?
}

final class HashCacheRepository {
    private let connection: SQLiteConnection
    
    init(connection: SQLiteConnection = .shared) {
        self.connection = connection
    }
    
    // MARK: - Save Methods
    
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

            if sqlite3_step(statement) != SQLITE_DONE {
                logError(
                    "Hash cache write failed: asset=\(localIdentifier), error=\(String(cString: sqlite3_errmsg(connection.db)))",
                    category: .database
                )
            }
        } else {
            logError(
                "Hash cache insert preparation failed: asset=\(localIdentifier), error=\(String(cString: sqlite3_errmsg(connection.db)))",
                category: .database
            )
        }

        sqlite3_finalize(statement)
    }
    
    /// Immich SQLite imports have hashes but no trusted PhotoKit version.
    /// Never replace an existing (possibly JPEG+RAW) hash with import data:
    /// doing so would erase version, RAW and upload-state information.
    @discardableResult
    func batchSaveHashCache(items: [(localIdentifier: String, sha1Hash: String, fileSize: Int64, syncStatus: String)]) -> Bool {
        guard !items.isEmpty else { return true }
        connection.ensureInitialized()
        return connection.dbQueue.sync { [weak self] () -> Bool in
            guard let self else { return false }
            let db = self.connection.db
            guard self.connection.beginTransaction() else {
                logError("Could not begin hash import transaction", category: .database)
                return false
            }
            var committed = false
            defer { if !committed { self.connection.rollbackTransaction() } }

            let insertSQL = """
                INSERT OR IGNORE INTO hash_cache
                (asset_id, sha1_hash, is_on_server, calculated_at,
                 raw_hash, raw_on_server, has_raw, asset_modification_date)
                VALUES (?, ?, 0, ?, NULL, 0, 0, NULL);
                """
            // A remote receipt inferred from imported SQLite is applicable
            // only when the *current* cached checksum is the same.
            let serverSQL = """
                UPDATE hash_cache SET is_on_server = 1, checked_at = ?
                WHERE asset_id = ? AND sha1_hash = ?;
                """
            var insert: OpaquePointer?
            var server: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &insert, nil) == SQLITE_OK,
                  sqlite3_prepare_v2(db, serverSQL, -1, &server, nil) == SQLITE_OK else {
                sqlite3_finalize(insert)
                sqlite3_finalize(server)
                logError("Could not prepare hash import statements: \(String(cString: sqlite3_errmsg(db)))", category: .database)
                return false
            }
            defer {
                sqlite3_finalize(insert)
                sqlite3_finalize(server)
            }

            let now = Date().timeIntervalSince1970
            for item in items {
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                guard sqlite3_bind_text(insert, 1, (item.localIdentifier as NSString).utf8String, -1, nil) == SQLITE_OK,
                      sqlite3_bind_text(insert, 2, (item.sha1Hash as NSString).utf8String, -1, nil) == SQLITE_OK,
                      sqlite3_bind_double(insert, 3, now) == SQLITE_OK,
                      sqlite3_step(insert) == SQLITE_DONE else {
                    logError("Hash import insert failed: \(String(cString: sqlite3_errmsg(db)))", category: .database)
                    return false
                }

                if item.syncStatus == "checked" {
                    sqlite3_reset(server)
                    sqlite3_clear_bindings(server)
                    guard sqlite3_bind_double(server, 1, now) == SQLITE_OK,
                          sqlite3_bind_text(server, 2, (item.localIdentifier as NSString).utf8String, -1, nil) == SQLITE_OK,
                          sqlite3_bind_text(server, 3, (item.sha1Hash as NSString).utf8String, -1, nil) == SQLITE_OK,
                          sqlite3_step(server) == SQLITE_DONE else {
                        logError("Hash import server status update failed: \(String(cString: sqlite3_errmsg(db)))", category: .database)
                        return false
                    }
                    // The imported primary may match while a preserved RAW
                    // companion is still absent. Schedule that incomplete
                    // asset using the same queue rule as regular server checks.
                    guard self.enqueueIfMissingOnServerInternal(
                        localIdentifier: item.localIdentifier
                    ) else { return false }
                }
            }
            guard self.connection.commitTransaction() else {
                logError("Could not commit hash import transaction", category: .database)
                return false
            }
            committed = true
            return true
        }
    }
    
    /// Import/legacy caches can hold a valid hash but no PhotoKit version.
    /// Return only unknown-version rows; no original media is requested.
    func unversionedHashCacheRows() -> [(localIdentifier: String, sha1Hash: String)] {
        connection.ensureInitialized()
        return connection.dbQueue.sync { [weak self] in
            guard let self else { return [] }
            var statement: OpaquePointer?
            let sql = """
                SELECT asset_id, sha1_hash
                FROM hash_cache
                WHERE asset_modification_date IS NULL;
                """
            guard sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                logError("Could not prepare unknown hash-version lookup", category: .database)
                return []
            }
            defer { sqlite3_finalize(statement) }
            var rows: [(localIdentifier: String, sha1Hash: String)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let identifier = sqlite3_column_text(statement, 0),
                      let checksum = sqlite3_column_text(statement, 1) else { continue }
                rows.append((
                    localIdentifier: String(cString: identifier),
                    sha1Hash: String(cString: checksum)
                ))
            }
            return rows
        }
    }

    /// One-time baseline for pre-versioned hashes. This records PhotoKit's
    /// current modification date, NOT proof that imported bytes equal current
    /// media. The caller must knowingly accept that historical limitation.
    /// Only fill still-NULL rows with the same checksum seen at snapshot time,
    /// so concurrent hashing cannot be overwritten.
    @discardableResult
    func backfillUnversionedHashDates(
        _ updates: [(localIdentifier: String, sha1Hash: String, modificationDate: Date)]
    ) -> Int {
        guard !updates.isEmpty else { return 0 }
        connection.ensureInitialized()
        return connection.dbQueue.sync { [weak self] in
            guard let self else { return 0 }
            guard self.connection.beginTransaction() else {
                logError("Could not begin unknown hash-version backfill", category: .database)
                return 0
            }
            var committed = false
            defer { if !committed { self.connection.rollbackTransaction() } }
            var statement: OpaquePointer?
            let sql = """
                UPDATE hash_cache
                SET asset_modification_date = ?
                WHERE asset_id = ? AND sha1_hash = ?
                  AND asset_modification_date IS NULL;
                """
            guard sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                logError("Could not prepare unknown hash-version backfill", category: .database)
                return 0
            }
            defer { sqlite3_finalize(statement) }
            var written = 0
            for update in updates {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                guard sqlite3_bind_double(statement, 1, update.modificationDate.timeIntervalSince1970) == SQLITE_OK,
                      sqlite3_bind_text(statement, 2, (update.localIdentifier as NSString).utf8String, -1, nil) == SQLITE_OK,
                      sqlite3_bind_text(statement, 3, (update.sha1Hash as NSString).utf8String, -1, nil) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE else {
                    logError("Unknown hash-version backfill failed", category: .database)
                    return 0
                }
                written += Int(sqlite3_changes(self.connection.db))
            }
            guard self.connection.commitTransaction() else {
                logError("Could not commit unknown hash-version backfill", category: .database)
                return 0
            }
            committed = true
            return written
        }
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
    
    /// A bounded, batched cache-presence lookup for upload diagnostics.
    /// It avoids one synchronous database dispatch and one log per asset.
    func cachedHashIdentifiers(for identifiers: [String]) -> Set<String>? {
        guard !identifiers.isEmpty else { return [] }
        connection.ensureInitialized()
        return connection.dbQueue.sync { [weak self] () -> Set<String>? in
            guard let self else { return nil }
            let db = self.connection.db
            let uniqueIdentifiers = Array(Set(identifiers))
            var cached = Set<String>()
            // Stay below SQLite's older 999-parameter limit.
            for start in stride(from: 0, to: uniqueIdentifiers.count, by: 400) {
                let end = min(start + 400, uniqueIdentifiers.count)
                let batch = Array(uniqueIdentifiers[start..<end])
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let sql = "SELECT asset_id FROM hash_cache WHERE asset_id IN (\(placeholders));"
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                    sqlite3_finalize(statement)
                    logError("Could not prepare hash cache preflight query", category: .database)
                    return nil
                }
                var valid = true
                for (index, identifier) in batch.enumerated() {
                    if sqlite3_bind_text(
                        statement, Int32(index + 1), (identifier as NSString).utf8String,
                        -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    ) != SQLITE_OK {
                        valid = false
                        break
                    }
                }
                if valid {
                    while true {
                        let result = sqlite3_step(statement)
                        if result == SQLITE_ROW {
                            if let id = sqlite3_column_text(statement, 0) {
                                cached.insert(String(cString: id))
                            }
                        } else if result == SQLITE_DONE {
                            break
                        } else {
                            valid = false
                            break
                        }
                    }
                }
                sqlite3_finalize(statement)
                guard valid else {
                    logError("Hash cache preflight query failed", category: .database)
                    return nil
                }
            }
            return cached
        }
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

    @discardableResult
    private func enqueueIfMissingOnServerInternal(localIdentifier: String) -> Bool {
        let sql = """
        INSERT OR IGNORE INTO background_upload_queue (asset_id, enqueued_at)
        SELECT asset_id, ?
        FROM hash_cache
        WHERE asset_id = ?
          AND checked_at IS NOT NULL
          AND (is_on_server = 0 OR (has_raw = 1 AND raw_on_server = 0));
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            logError("Could not prepare missing-resource upload queue insert", category: .database)
            return false
        }
        defer { sqlite3_finalize(statement) }
        let success =
            sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970) == SQLITE_OK &&
            sqlite3_bind_text(
                statement, 2, (localIdentifier as NSString).utf8String,
                -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            ) == SQLITE_OK &&
            sqlite3_step(statement) == SQLITE_DONE
        if !success {
            logError("Could not queue asset with missing resources: \(localIdentifier)", category: .database)
        }
        return success
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
    

    /// Verify a bounded set of currently accessible PhotoKit IDs using indexed
    /// SQLite membership checks. One transaction and two set-based writes
    /// replace one transaction and several queries per individual asset.
    ///
    /// The caller holds ServerAssetVerificationGate, preventing a server delta
    /// from changing the cached checksum set during this verification.
    /// A failed transaction leaves checked_at NULL so a later run can retry.
    func verifyHashCacheBatch(
        identifiers: [String],
        ownerId: String?
    ) -> [CloudMetadataCandidate]? {
        guard !identifiers.isEmpty else { return [] }
        connection.ensureInitialized()
        return connection.dbQueue.sync { [weak self] in
            guard let self else { return nil }
            guard self.connection.beginTransaction() else { return nil }
            let placeholders = Array(repeating: "?", count: identifiers.count).joined(separator: ",")
            let now = Date().timeIntervalSince1970
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

            func bindIds(_ statement: OpaquePointer?, startingAt first: Int32) -> Bool {
                for (offset, identifier) in identifiers.enumerated() {
                    let status = sqlite3_bind_text(
                        statement, first + Int32(offset),
                        (identifier as NSString).utf8String, -1, transient
                    )
                    if status != SQLITE_OK { return false }
                }
                return true
            }

            func execute(_ sql: String) -> Bool {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
                    sqlite3_finalize(statement)
                    return false
                }
                defer { sqlite3_finalize(statement) }
                return sqlite3_bind_double(statement, 1, now) == SQLITE_OK
                    && bindIds(statement, startingAt: 2)
                    && sqlite3_step(statement) == SQLITE_DONE
            }

            // A verified upload receipt takes priority; otherwise match the
            // original SHA1 against source_checksum or checksum for assets
            // without a source_checksum. The same predicate applies to RAW.
            let verifySQL = """
                UPDATE hash_cache AS h SET
                  is_on_server = CASE WHEN
                    EXISTS (SELECT 1 FROM uploaded_assets u
                            WHERE u.asset_id = h.asset_id
                              AND u.resource_type IN ('primary', 'photo'))
                    OR (h.has_raw = 0 AND EXISTS (
                          SELECT 1 FROM uploaded_assets u WHERE u.asset_id = h.asset_id
                            AND u.resource_type = 'raw'))
                    OR EXISTS (SELECT 1 FROM server_assets_cache s
                               WHERE s.source_checksum = h.sha1_hash)
                    OR EXISTS (SELECT 1 FROM server_assets_cache s
                               WHERE s.checksum = h.sha1_hash AND s.source_checksum IS NULL)
                    THEN 1 ELSE 0 END,
                  raw_on_server = CASE WHEN h.has_raw = 1 AND (
                    EXISTS (SELECT 1 FROM uploaded_assets u
                            WHERE u.asset_id = h.asset_id AND u.resource_type = 'raw')
                    OR EXISTS (SELECT 1 FROM server_assets_cache s
                               WHERE s.source_checksum = h.raw_hash)
                    OR EXISTS (SELECT 1 FROM server_assets_cache s
                               WHERE s.checksum = h.raw_hash AND s.source_checksum IS NULL)
                    ) THEN 1 ELSE 0 END,
                  checked_at = ?
                WHERE h.checked_at IS NULL AND h.asset_id IN (\(placeholders));
                """
            let queueSQL = """
                INSERT OR IGNORE INTO background_upload_queue (asset_id, enqueued_at)
                SELECT h.asset_id, ? FROM hash_cache h
                WHERE h.asset_id IN (\(placeholders))
                  AND h.checked_at IS NOT NULL
                  AND (h.is_on_server = 0 OR (h.has_raw = 1 AND h.raw_on_server = 0));
                """
            guard execute(verifySQL), execute(queueSQL) else {
                self.connection.rollbackTransaction()
                logError("Batch checksum verification failed: \(self.connection.lastErrorMessage)", category: .database)
                return nil
            }

            // Resolve remote asset metadata with indexed joins rather than
            // looking it up individually for every checked asset. Receipt
            // matches override checksum matches, preserving upload ownership.
            var matches: [String: CloudMetadataCandidate] = [:]
            if let ownerId {
                func collect(_ sql: String) -> Bool {
                    var statement: OpaquePointer?
                    guard sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
                        sqlite3_finalize(statement)
                        return false
                    }
                    defer { sqlite3_finalize(statement) }
                    guard bindIds(statement, startingAt: 1),
                          sqlite3_bind_text(
                              statement, Int32(identifiers.count + 1),
                              (ownerId as NSString).utf8String, -1, transient
                          ) == SQLITE_OK else { return false }
                    while true {
                        let status = sqlite3_step(statement)
                        if status == SQLITE_DONE { return true }
                        guard status == SQLITE_ROW,
                              let id = sqlite3_column_text(statement, 0),
                              let remoteId = sqlite3_column_text(statement, 1)
                        else { return false }
                        let assetId = String(cString: id)
                        matches[assetId] = CloudMetadataCandidate(
                            assetId: assetId,
                            immichId: String(cString: remoteId),
                            serverICloudId: sqlite3_column_text(statement, 2).map { String(cString: $0) },
                            sourceChecksum: sqlite3_column_text(statement, 3).map { String(cString: $0) }
                        )
                    }
                }

                // Split source-checksum and fallback-checksum branches to
                // keep their respective SQLite indexes usable. CROSS JOIN
                // preserves the bounded identifier lookup as the outer loop.
                let sourceMatches = """
                    SELECT h.asset_id, s.immich_id, s.icloud_id, s.source_checksum
                    FROM hash_cache h
                    CROSS JOIN server_assets_cache s INDEXED BY idx_server_cache_source_checksum
                    WHERE h.asset_id IN (\(placeholders))
                      AND s.source_checksum = h.sha1_hash AND s.owner_id = ?;
                    """
                let checksumMatches = """
                    SELECT h.asset_id, s.immich_id, s.icloud_id, s.source_checksum
                    FROM hash_cache h
                    CROSS JOIN server_assets_cache s INDEXED BY idx_server_cache_checksum
                    WHERE h.asset_id IN (\(placeholders))
                      AND s.checksum = h.sha1_hash AND s.source_checksum IS NULL
                      AND s.owner_id = ?;
                    """
                let receiptMatches = """
                    SELECT h.asset_id, s.immich_id, s.icloud_id, s.source_checksum
                    FROM hash_cache h
                    JOIN uploaded_assets u ON u.asset_id = h.asset_id
                      AND u.resource_type IN ('primary', 'photo', 'jpeg', 'video', 'raw')
                    JOIN server_assets_cache s ON s.immich_id = u.immich_id
                    WHERE h.asset_id IN (\(placeholders))
                      AND h.is_on_server = 1 AND s.owner_id = ?
                    ORDER BY CASE WHEN u.resource_type = 'raw' THEN 0 ELSE 1 END;
                    """
                guard collect(sourceMatches), collect(checksumMatches), collect(receiptMatches) else {
                    self.connection.rollbackTransaction()
                    logError("Batch metadata lookup failed: \(self.connection.lastErrorMessage)", category: .database)
                    return nil
                }
            }
            guard self.connection.commitTransaction() else {
                self.connection.rollbackTransaction()
                return nil
            }
            return Array(matches.values)
        }
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
    
    func getAllSyncStatusAsync(uploadedResourceTypes: [String: Set<String>], hasServerCache: Bool, completion: @escaping ([String: PhotoSyncStatus]) -> Void) {
        connection.dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([:]) }
                return
            }
            
            var statusMap: [String: PhotoSyncStatus] = [:]
            var statement: OpaquePointer?
            
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
                        let hasUploadedNonRAW = !uploadedTypes.isEmpty && uploadedTypes.contains(where: { $0 != "raw" })
                        let hasUploadedRAW = uploadedTypes.contains("raw")
                        
                        var isFullyUploaded = false
                        
                        if hasRAW {
                            let primaryComplete = hasUploadedNonRAW || primaryOnServer
                            let rawComplete = hasUploadedRAW || rawOnServer
                            isFullyUploaded = primaryComplete && rawComplete
                        } else {
                            let hasUploadedPrimary = hasUploadedNonRAW || hasUploadedRAW
                            isFullyUploaded = hasUploadedPrimary || primaryOnServer
                        }
                        
                        if !hasBeenChecked && hasServerCache {
                            statusMap[identifier] = .pending
                        } else if isFullyUploaded {
                            statusMap[identifier] = .uploaded
                        } else if hasBeenChecked {
                            // Already checked - show as not uploaded
                            statusMap[identifier] = .notUploaded
                        } else if hasServerCache {
                            // Has server cache but not checked yet - show as pending
                            statusMap[identifier] = .pending
                        } else {
                            // No server cache - assume not uploaded
                            statusMap[identifier] = .notUploaded
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
    
    func getAssetsNeedingHashAsync(allIdentifiers: [String], completion: @escaping ([String]) -> Void) {
        guard !allIdentifiers.isEmpty else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        connection.dbQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            // Delta launches usually supply 0–10 identifiers. Avoid selecting
            // every cached hash just to check a few (or zero) PhotoKit assets.
            // Keep a full-table branch for one-time bootstrap's large batches.
            var needingHash: [String] = []
            if allIdentifiers.count > 2_000 {
                var statement: OpaquePointer?
                var known: Set<String> = []
                guard sqlite3_prepare_v2(
                    self.connection.db, "SELECT asset_id FROM hash_cache;",
                    -1, &statement, nil
                ) == SQLITE_OK else {
                    sqlite3_finalize(statement)
                    DispatchQueue.main.async { completion(allIdentifiers) }
                    return
                }
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let id = sqlite3_column_text(statement, 0) {
                        known.insert(String(cString: id))
                    }
                }
                sqlite3_finalize(statement)
                needingHash = allIdentifiers.filter { !known.contains($0) }
            } else {
                let sql = "SELECT 1 FROM hash_cache WHERE asset_id = ? LIMIT 1;"
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
                    sqlite3_finalize(statement)
                    DispatchQueue.main.async { completion(allIdentifiers) }
                    return
                }
                for identifier in allIdentifiers {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    sqlite3_bind_text(statement, 1, (identifier as NSString).utf8String, -1, nil)
                    if sqlite3_step(statement) != SQLITE_ROW {
                        needingHash.append(identifier)
                    }
                }
                sqlite3_finalize(statement)
            }
            DispatchQueue.main.async { completion(needingHash) }
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
    
    /// Invalidate only checks affected by a remote delta. Run before changing the
    /// server cache/ACK so a crash cannot strand a stale negative result.
    /// Full sync invalidates every check but keeps the computed hashes.
    @discardableResult
    func invalidateHashChecksForServerChanges(checksums: [String], fullReset: Bool) -> Bool {
        connection.ensureInitialized()
        return connection.dbQueue.sync { [weak self] in
            guard let self else { return false }
            let unique = Array(Set(checksums))
            guard fullReset || !unique.isEmpty else { return true }
            guard self.connection.beginTransaction() else { return false }
            var invalidatedCount = 0

            let batches: [[String]] = fullReset ? [[]] : stride(from: 0, to: unique.count, by: 200).map {
                Array(unique[$0..<min($0 + 200, unique.count)])
            }
            for batch in batches {
                let sql: String
                if fullReset {
                    sql = "UPDATE hash_cache SET checked_at = NULL WHERE checked_at IS NOT NULL;"
                } else {
                    let args = Array(repeating: "?", count: batch.count).joined(separator: ",")
                    sql = """
                        UPDATE hash_cache SET checked_at = NULL
                        WHERE checked_at IS NOT NULL
                          AND (sha1_hash IN (\(args)) OR raw_hash IN (\(args)));
                        """
                }
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
                    sqlite3_finalize(statement)
                    self.connection.rollbackTransaction()
                    return false
                }
                if !fullReset {
                    for (index, checksum) in batch.enumerated() {
                        sqlite3_bind_text(statement, Int32(index + 1), (checksum as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(statement, Int32(index + 1 + batch.count), (checksum as NSString).utf8String, -1, nil)
                    }
                }
                let success = sqlite3_step(statement) == SQLITE_DONE
                if success { invalidatedCount += Int(sqlite3_changes(self.connection.db)) }
                sqlite3_finalize(statement)
                guard success else {
                    self.connection.rollbackTransaction()
                    return false
                }
            }
            guard self.connection.commitTransaction() else {
                self.connection.rollbackTransaction()
                return false
            }
            logInfo(
                "Hash verification invalidation: fullReset=\(fullReset), checksums=\(unique.count), invalidated=\(invalidatedCount)",
                category: .hash
            )
            return true
        }
    }

    /// Restore unchecked verification for metadata work that could not be
    /// delivered. Batched updates keep one transaction and leave unrelated
    /// asset statuses intact; the next normal pipeline can rediscover these IDs.
    @discardableResult
    func invalidateHashChecksForLocalIdentifiers(_ identifiers: [String]) -> Bool {
        guard !identifiers.isEmpty else { return true }
        connection.ensureInitialized()
        return connection.dbQueue.sync { [weak self] in
            guard let self, self.connection.beginTransaction() else { return false }
            let unique = Array(Set(identifiers))
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for start in stride(from: 0, to: unique.count, by: 300) {
                let batch = unique[start..<min(start + 300, unique.count)]
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let sql = """
                    UPDATE hash_cache SET checked_at = NULL
                    WHERE checked_at IS NOT NULL AND asset_id IN (\(placeholders));
                    """
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
                    sqlite3_finalize(statement)
                    self.connection.rollbackTransaction()
                    return false
                }
                var didBind = true
                for (index, identifier) in batch.enumerated() {
                    if sqlite3_bind_text(
                        statement, Int32(index + 1),
                        (identifier as NSString).utf8String, -1, transient
                    ) != SQLITE_OK {
                        didBind = false
                        break
                    }
                }
                let success = didBind && sqlite3_step(statement) == SQLITE_DONE
                sqlite3_finalize(statement)
                guard success else {
                    logError("Failed to invalidate metadata retry IDs: \(self.connection.lastErrorMessage)", category: .database)
                    self.connection.rollbackTransaction()
                    return false
                }
            }
            guard self.connection.commitTransaction() else {
                self.connection.rollbackTransaction()
                return false
            }
            logInfo("Hash checks requeued for undelivered metadata: assets=\(unique.count)", category: .hash)
            return true
        }
    }

    func getMultiResourceHashesNotFullyOnServerAsync(completion: @escaping ([MultiResourceHashRecord]) -> Void) {
        connection.dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            
            let sql = """
                SELECT asset_id, sha1_hash, raw_hash, has_raw, is_on_server, raw_on_server
                FROM hash_cache
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
                        
                        records.append(MultiResourceHashRecord(
                            assetId: assetId,
                            primaryHash: primaryHash,
                            rawHash: rawHash,
                            hasRAW: hasRAW,
                            primaryOnServer: primaryOnServer,
                            rawOnServer: rawOnServer
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
    
    // MARK: - Foreground PhotoKit Persistent Changes

    /// Deliberately separate from the background extension's `change_tokens`.
    /// Neither consumer may advance the other's cursor.
    func loadForegroundPhotoToken() -> Data? {
        connection.ensureInitialized()
        return connection.dbQueue.sync { [weak self] in
            guard let self else { return nil }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(
                self.connection.db,
                "SELECT token_data FROM foreground_photo_change_state WHERE id = 1;",
                -1, &statement, nil
            ) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        }
    }

    /// Atomically store the cursor and the work it represents. The first pass
    /// records an entire hidden-inclusive snapshot; later calls apply only
    /// PhotoKit's changed IDs. A crash can replay work but cannot skip it.
    @discardableResult
    func applyForegroundPhotoChanges(
        snapshots: [PhotoAssetSnapshot],
        pendingIdentifiers: Set<String>,
        deletedIdentifiers: Set<String>,
        tokenData: Data,
        bootstrap: Bool
    ) -> Bool {
        connection.ensureInitialized()
        return connection.dbQueue.sync { [weak self] in
            guard let self else { return false }
            let db = self.connection.db
            guard self.connection.beginTransaction() else { return false }
            var committed = false
            defer { if !committed { self.connection.rollbackTransaction() } }

            func execute(_ sql: String) -> Bool {
                sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
            }

            func runIDs(_ sql: String, _ ids: Set<String>) -> Bool {
                guard !ids.isEmpty else { return true }
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                    sqlite3_finalize(statement)
                    return false
                }
                defer { sqlite3_finalize(statement) }
                for id in ids {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    guard sqlite3_bind_text(statement, 1, (id as NSString).utf8String, -1, nil) == SQLITE_OK,
                          sqlite3_step(statement) == SQLITE_DONE else { return false }
                }
                return true
            }

            // Diagnostic counters are emitted only after the change transaction commits.
            var unchangedCachedCount = 0
            var missingCacheCount = 0
            var missingStoredDateCount = 0
            var changedDateCount = 0
            var missingCurrentDateCount = 0
            var cacheDetails: [String] = []
            func recordCacheDetail(_ message: String) {
                if cacheDetails.count < 10 { cacheDetails.append(message) }
            }

            // Bootstrap reconciles old hashes/receipts/queue entries using the
            // authoritative full-library snapshot (including hidden assets).
            // The token is sampled BEFORE enumerating, so later changes replay.
            if bootstrap {
                guard execute("""
                    CREATE TEMP TABLE IF NOT EXISTS foreground_snapshot (
                        asset_id TEXT PRIMARY KEY, is_hidden INTEGER, modified_at REAL
                    );
                    """),
                      execute("DELETE FROM foreground_snapshot;") else { return false }

                var insert: OpaquePointer?
                guard sqlite3_prepare_v2(db,
                    "INSERT INTO foreground_snapshot(asset_id, is_hidden, modified_at) VALUES (?, ?, ?);",
                    -1, &insert, nil
                ) == SQLITE_OK else {
                    sqlite3_finalize(insert)
                    return false
                }
                var insertOK = true
                for snapshot in snapshots {
                    sqlite3_reset(insert)
                    sqlite3_clear_bindings(insert)
                    sqlite3_bind_text(insert, 1, (snapshot.localIdentifier as NSString).utf8String, -1, nil)
                    sqlite3_bind_int(insert, 2, snapshot.isHidden ? 1 : 0)
                    if let date = snapshot.modificationDate {
                        sqlite3_bind_double(insert, 3, date.timeIntervalSince1970)
                    } else {
                        sqlite3_bind_null(insert, 3)
                    }
                    if sqlite3_step(insert) != SQLITE_DONE {
                        insertOK = false
                        break
                    }
                }
                sqlite3_finalize(insert)
                guard insertOK else { return false }

                // Compare modificationDate only on visible assets. Hidden items
                // are retained (not rehashed) until they become visible.
                let modifiedQuery = """
                    SELECT h.asset_id FROM hash_cache h
                    JOIN foreground_snapshot s ON s.asset_id = h.asset_id
                    WHERE s.is_hidden = 0 AND s.modified_at IS NOT NULL
                      AND h.asset_modification_date IS NOT NULL
                      AND s.modified_at != h.asset_modification_date;
                    """
                var query: OpaquePointer?
                guard sqlite3_prepare_v2(db, modifiedQuery, -1, &query, nil) == SQLITE_OK else {
                    sqlite3_finalize(query)
                    return false
                }
                var modified = Set<String>()
                var queryOK = true
                while true {
                    let result = sqlite3_step(query)
                    if result == SQLITE_ROW {
                        if let ptr = sqlite3_column_text(query, 0) {
                            modified.insert(String(cString: ptr))
                        }
                    } else if result == SQLITE_DONE { break }
                    else { queryOK = false; break }
                }
                sqlite3_finalize(query)
                guard queryOK else { return false }
                // Unknown cached versions are legitimate (e.g. imported
                // checksums). A snapshot alone does not prove that those
                // hashes match its modification date; leave NULL untouched.
                guard runIDs("DELETE FROM hash_cache WHERE asset_id = ?;", modified),
                      runIDs("DELETE FROM uploaded_assets WHERE asset_id = ?;", modified) else {
                    return false
                }

                let missingFromSnapshot =
                    "asset_id NOT IN (SELECT asset_id FROM foreground_snapshot)"
                guard execute("DELETE FROM hash_cache WHERE \(missingFromSnapshot);"),
                      execute("DELETE FROM uploaded_assets WHERE \(missingFromSnapshot);"),
                      execute("DELETE FROM foreground_photo_pending_assets WHERE \(missingFromSnapshot);"),
                      execute("DELETE FROM background_upload_queue WHERE \(missingFromSnapshot);"),
                      execute("""
                        DELETE FROM upload_jobs WHERE \(missingFromSnapshot)
                        AND status IN ('pending', 'failed');
                        """),
                      execute("""
                        DELETE FROM foreground_photo_pending_assets
                        WHERE asset_id IN
                          (SELECT asset_id FROM foreground_snapshot WHERE is_hidden = 1);
                        """),
                      execute("""
                        INSERT OR IGNORE INTO foreground_photo_pending_assets(asset_id)
                        SELECT asset_id FROM foreground_snapshot WHERE is_hidden = 0;
                        """) else { return false }

            } else {
                // PhotoKit inserts/updates are not necessarily content edits:
                // invalidate hashes only when their stored modification date
                // changed. An updated hidden asset does not enter hashing.
                var modified = Set<String>()
                let checkSQL = "SELECT asset_modification_date FROM hash_cache WHERE asset_id = ?;"
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, checkSQL, -1, &statement, nil) == SQLITE_OK else {
                    sqlite3_finalize(statement)
                    return false
                }
                var checkOK = true
                for snapshot in snapshots where !snapshot.isHidden {
                    guard let date = snapshot.modificationDate else {
                        missingCurrentDateCount += 1
                        recordCacheDetail("Foreground PhotoKit missing current modification date: asset=\(snapshot.localIdentifier)")
                        continue
                    }
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    sqlite3_bind_text(statement, 1, (snapshot.localIdentifier as NSString).utf8String, -1, nil)
                    let step = sqlite3_step(statement)
                    if step == SQLITE_ROW {
                        if sqlite3_column_type(statement, 0) == SQLITE_NULL {
                            missingStoredDateCount += 1
                            modified.insert(snapshot.localIdentifier)
                            recordCacheDetail(
                                "Foreground hash cache invalidated: asset=\(snapshot.localIdentifier), reason=missing_stored_date, current=\(date.timeIntervalSince1970)"
                            )
                        } else {
                            let stored = sqlite3_column_double(statement, 0)
                            if date.timeIntervalSince1970 != stored {
                                changedDateCount += 1
                                modified.insert(snapshot.localIdentifier)
                                recordCacheDetail(
                                    "Foreground hash cache invalidated: asset=\(snapshot.localIdentifier), reason=modification_date_changed, stored=\(stored), current=\(date.timeIntervalSince1970)"
                                )
                            } else {
                                unchangedCachedCount += 1
                            }
                        }
                    } else if step == SQLITE_DONE {
                        missingCacheCount += 1
                        recordCacheDetail("Foreground PhotoKit asset has no prior hash cache: asset=\(snapshot.localIdentifier)")
                    } else {
                        checkOK = false
                        break
                    }
                }
                sqlite3_finalize(statement)
                guard checkOK,
                      runIDs("DELETE FROM hash_cache WHERE asset_id = ?;", modified),
                      runIDs("DELETE FROM uploaded_assets WHERE asset_id = ?;", modified) else {
                    return false
                }
                let hiddenIDs = Set(snapshots.filter(\.isHidden).map(\.localIdentifier))
                guard runIDs(
                    "DELETE FROM foreground_photo_pending_assets WHERE asset_id = ?;",
                    hiddenIDs
                ) else { return false }
                let toEnqueue = pendingIdentifiers.subtracting(hiddenIDs).subtracting(deletedIdentifiers)
                guard runIDs(
                    "INSERT OR IGNORE INTO foreground_photo_pending_assets(asset_id) VALUES (?);",
                    toEnqueue
                ) else { return false }

                // Only explicit persistent deletions are authoritative here,
                // never a temporarily unresolvable PHAsset fetch result.
                guard runIDs("DELETE FROM hash_cache WHERE asset_id = ?;", deletedIdentifiers),
                      runIDs("DELETE FROM uploaded_assets WHERE asset_id = ?;", deletedIdentifiers),
                      runIDs("DELETE FROM foreground_photo_pending_assets WHERE asset_id = ?;", deletedIdentifiers),
                      runIDs("DELETE FROM background_upload_queue WHERE asset_id = ?;", deletedIdentifiers),
                      runIDs("""
                        DELETE FROM upload_jobs WHERE asset_id = ?
                        AND status IN ('pending', 'failed');
                        """, deletedIdentifiers) else { return false }
            }

            // The extension's cursor is untouched, even though the SQLite
            // database and durable upload queue are shared through App Group.
            var tokenStatement: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "INSERT OR REPLACE INTO foreground_photo_change_state(id, token_data) VALUES (1, ?);",
                -1, &tokenStatement, nil
            ) == SQLITE_OK else {
                sqlite3_finalize(tokenStatement)
                return false
            }
            let bindResult = tokenData.withUnsafeBytes { bytes in
                sqlite3_bind_blob(tokenStatement, 1, bytes.baseAddress, Int32(bytes.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            let tokenOK = bindResult == SQLITE_OK && sqlite3_step(tokenStatement) == SQLITE_DONE
            sqlite3_finalize(tokenStatement)
            guard tokenOK, self.connection.commitTransaction() else { return false }
            committed = true
            if !bootstrap && !snapshots.isEmpty {
                logInfo(
                    "Foreground PhotoKit cache reconciliation: snapshots=\(snapshots.count), cachedUnchanged=\(unchangedCachedCount), noCache=\(missingCacheCount), invalidatedMissingDate=\(missingStoredDateCount), invalidatedChangedDate=\(changedDateCount), currentDateUnknown=\(missingCurrentDateCount)",
                    category: .hash
                )
                for detail in cacheDetails {
                    logDebug(detail, category: .hash)
                }
            }
            return true
        }
    }

    /// Drain completed work but keep unfinished identifiers durable across
    /// app termination, hash cancellations, network failures, and launch races.
    func getPendingForegroundPhotoIdentifiers() -> [String] {
        connection.ensureInitialized()
        return connection.dbQueue.sync { [weak self] in
            guard let self else { return [] }
            let db = self.connection.db
            let completed = """
                DELETE FROM foreground_photo_pending_assets
                WHERE EXISTS (
                    SELECT 1 FROM hash_cache
                    WHERE hash_cache.asset_id = foreground_photo_pending_assets.asset_id
                );
                """
            guard sqlite3_exec(db, completed, nil, nil, nil) == SQLITE_OK else { return [] }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(
                db, "SELECT asset_id FROM foreground_photo_pending_assets;", -1, &statement, nil
            ) == SQLITE_OK else { return [] }
            var identifiers: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let id = sqlite3_column_text(statement, 0) {
                    identifiers.append(String(cString: id))
                }
            }
            return identifiers
        }
    }

    /// Hidden assets should not be hashed by the visible-library pipeline.
    /// Only explicit hidden PHAssets are acknowledged; temporarily absent
    /// local identifiers remain pending until PhotoKit can resolve them.
    func discardForegroundPendingIdentifiers(_ identifiers: Set<String>) {
        guard !identifiers.isEmpty else { return }
        connection.ensureInitialized()
        connection.dbQueue.sync { [weak self] in
            guard let self else { return }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                self.connection.db,
                "DELETE FROM foreground_photo_pending_assets WHERE asset_id = ?;",
                -1, &statement, nil
            ) == SQLITE_OK else {
                sqlite3_finalize(statement)
                return
            }
            defer { sqlite3_finalize(statement) }
            for id in identifiers {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, (id as NSString).utf8String, -1, nil)
                if sqlite3_step(statement) != SQLITE_DONE {
                    logError("Failed to discard hidden foreground PhotoKit ID", category: .database)
                    break
                }
            }
        }
    }

    // MARK: - Modified Asset Invalidation

    /// Deletes hashes with changed versions. A visible unknown-version hash
    /// also requires re-verification on fallback snapshots (e.g. Limited Photos).
    func resetCacheForModifiedAssets(snapshots: [PhotoAssetSnapshot], pruneOrphans: Bool = false) {
        guard !snapshots.isEmpty || pruneOrphans else { return }

        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            self.resetCacheForModifiedAssetsInternal(snapshots: snapshots, pruneOrphans: pruneOrphans)
        }
    }

    private func resetCacheForModifiedAssetsInternal(snapshots: [PhotoAssetSnapshot], pruneOrphans: Bool) {
        // Fetch all stored modification dates in one query; NULL means not yet recorded
        let sql = "SELECT asset_id, asset_modification_date FROM hash_cache;"
        var statement: OpaquePointer?
        var storedDates: [String: Double] = [:]      // asset_id -> stored timestamp
        var cachedIds: Set<String> = []

        if sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let idCString = sqlite3_column_text(statement, 0) {
                    let assetId = String(cString: idCString)
                    cachedIds.insert(assetId)
                    if sqlite3_column_type(statement, 1) != SQLITE_NULL {
                        storedDates[assetId] = sqlite3_column_double(statement, 1)
                    }
                }
            }
        }
        sqlite3_finalize(statement)

        // Do not assign current PhotoKit dates to legacy or imported hashes
        // without verifying the bytes represented by their checksum.

        // Only complete, hidden-inclusive snapshots may authorize deletion.
        // Query queue-only/receipt-only IDs too: a photo removed before hashing
        // must not leave a permanently retrying durable upload queue entry.
        var missingIds: Set<String> = []
        if pruneOrphans {
            var persistedIds = cachedIds
            for sql in [
                "SELECT asset_id FROM background_upload_queue;",
                "SELECT DISTINCT asset_id FROM uploaded_assets;"
            ] {
                var query: OpaquePointer?
                guard sqlite3_prepare_v2(connection.db, sql, -1, &query, nil) == SQLITE_OK else {
                    sqlite3_finalize(query)
                    logError("Could not enumerate cached PhotoKit identifiers", category: .database)
                    return
                }
                var failed = false
                while true {
                    let result = sqlite3_step(query)
                    if result == SQLITE_ROW {
                        if let id = sqlite3_column_text(query, 0) {
                            persistedIds.insert(String(cString: id))
                        }
                    } else if result == SQLITE_DONE {
                        break
                    } else {
                        failed = true
                        break
                    }
                }
                sqlite3_finalize(query)
                if failed {
                    logError("Could not finish cached PhotoKit identifier query", category: .database)
                    return
                }
            }
            missingIds = persistedIds.subtracting(Set(snapshots.map(\.localIdentifier)))
        }

        var modifiedIds = Set<String>()
        for snapshot in snapshots {
            // Hidden assets appear here solely for deletion safety. Preserve
            // their previous hashes until they return to the visible pipeline.
            guard !snapshot.isHidden else { continue }
            guard cachedIds.contains(snapshot.localIdentifier) else { continue }
            guard let stored = storedDates[snapshot.localIdentifier],
                  let date = snapshot.modificationDate else {
                // Existing cache with no trusted comparable version:
                // require local hashing rather than silently reusing it.
                modifiedIds.insert(snapshot.localIdentifier)
                continue
            }
            if date.timeIntervalSince1970 != stored {
                modifiedIds.insert(snapshot.localIdentifier)
            }
        }

        // A modified asset is re-enqueued by PhotoKit change tracking; deleting
        // its queue row here would lose that work. Only truly missing IDs can
        // have their durable queue and pending/failed jobs removed.
        let invalidatedIds = missingIds.union(modifiedIds)
        guard !invalidatedIds.isEmpty else { return }

        guard connection.beginTransaction() else {
            logError("Could not begin PhotoKit orphan reconciliation transaction", category: .database)
            return
        }
        let mutations: [(String, Set<String>)] = [
            ("DELETE FROM hash_cache WHERE asset_id = ?;", invalidatedIds),
            ("DELETE FROM uploaded_assets WHERE asset_id = ?;", invalidatedIds),
            ("DELETE FROM background_upload_queue WHERE asset_id = ?;", missingIds),
            ("DELETE FROM upload_jobs WHERE asset_id = ? AND status IN ('pending', 'failed');", missingIds)
        ]
        for (sql, ids) in mutations where !ids.isEmpty {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                connection.rollbackTransaction()
                logError("Could not prepare PhotoKit orphan cleanup statement", category: .database)
                return
            }
            var failed = false
            for id in ids {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, (id as NSString).utf8String, -1, nil)
                if sqlite3_step(statement) != SQLITE_DONE {
                    failed = true
                    break
                }
            }
            sqlite3_finalize(statement)
            if failed {
                connection.rollbackTransaction()
                logError("PhotoKit orphan reconciliation rolled back after SQLite failure", category: .database)
                return
            }
        }
        guard connection.commitTransaction() else {
            connection.rollbackTransaction()
            logError("PhotoKit orphan reconciliation commit failed", category: .database)
            return
        }
        logInfo("Pruned \(missingIds.count) absent PhotoKit assets and invalidated \(modifiedIds.count) modified assets", category: .hash)
    }

    // MARK: - Clear
    
    func clearHashCache() {
        connection.ensureInitialized()
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            self.connection.executeStatement("DELETE FROM hash_cache;")
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
