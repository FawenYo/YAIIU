import Foundation
import Photos
import SQLite3

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

            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)
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
          AND (is_on_server = 0 OR (has_raw = 1 AND raw_on_server = 0));
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, (localIdentifier as NSString).utf8String, -1, nil)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
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
                      AND ABS(s.modified_at - h.asset_modification_date) > 1.0;
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
                    guard let date = snapshot.modificationDate else { continue }
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    sqlite3_bind_text(statement, 1, (snapshot.localIdentifier as NSString).utf8String, -1, nil)
                    let step = sqlite3_step(statement)
                    if step == SQLITE_ROW,
                       sqlite3_column_type(statement, 0) != SQLITE_NULL,
                       abs(date.timeIntervalSince1970 - sqlite3_column_double(statement, 0)) > 1 {
                        modified.insert(snapshot.localIdentifier)
                    } else if step != SQLITE_ROW && step != SQLITE_DONE {
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

    // MARK: - Modified Asset Invalidation

    /// Deletes hash_cache and uploaded_assets rows for assets whose modificationDate
    /// has changed since the date was last stored. Assets with NULL stored dates are skipped.
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
        var nullDateIds: Set<String> = []             // asset_id with no stored date yet
        var cachedIds: Set<String> = []

        if sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let idCString = sqlite3_column_text(statement, 0) {
                    let assetId = String(cString: idCString)
                    cachedIds.insert(assetId)
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
            guard let stored = storedDates[snapshot.localIdentifier],
                  let date = snapshot.modificationDate else { continue }
            if abs(date.timeIntervalSince1970 - stored) > 1.0 {
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
