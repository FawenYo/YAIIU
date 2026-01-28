import Foundation
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
            self.saveHashCacheInternal(localIdentifier: localIdentifier, sha1Hash: sha1Hash, rawHash: nil, hasRAW: false)
        }
    }
    
    func saveMultiResourceHashCache(
        localIdentifier: String,
        primaryHash: String,
        rawHash: String?,
        hasRAW: Bool
    ) {
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            self.saveHashCacheInternal(
                localIdentifier: localIdentifier,
                sha1Hash: primaryHash,
                rawHash: rawHash,
                hasRAW: hasRAW
            )
        }
    }
    
    private func saveHashCacheInternal(localIdentifier: String, sha1Hash: String, rawHash: String?, hasRAW: Bool) {
        let sql = """
        INSERT OR REPLACE INTO hash_cache
        (asset_id, sha1_hash, is_on_server, calculated_at, raw_hash, raw_on_server, has_raw)
        VALUES (?, ?, 0, ?, ?, 0, ?);
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
                    hasRAW: false
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
            self.updateHashCacheServerStatusInternal(localIdentifier: localIdentifier, isOnServer: isOnServer)
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
    }
    
    func updateMultiResourceHashCacheServerStatus(
        localIdentifier: String,
        primaryOnServer: Bool,
        rawOnServer: Bool
    ) {
        connection.ensureInitialized()
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            self.updateMultiResourceHashCacheServerStatusInternal(
                localIdentifier: localIdentifier,
                primaryOnServer: primaryOnServer,
                rawOnServer: rawOnServer
            )
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
                        let hasUploadedPrimary = !uploadedTypes.isEmpty && uploadedTypes.contains(where: { $0 != "raw" })
                        let hasUploadedRAW = uploadedTypes.contains("raw")
                        
                        var isFullyUploaded = false
                        
                        if hasRAW {
                            let primaryComplete = hasUploadedPrimary || primaryOnServer
                            let rawComplete = hasUploadedRAW || rawOnServer
                            isFullyUploaded = primaryComplete && rawComplete
                        } else {
                            isFullyUploaded = hasUploadedPrimary || primaryOnServer
                        }
                        
                        if isFullyUploaded {
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
            
            let needingHash = allIdentifiers.filter { !existingIds.contains($0) }
            
            DispatchQueue.main.async {
                completion(needingHash)
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
                SELECT asset_id, sha1_hash, raw_hash, has_raw, is_on_server, raw_on_server
                FROM hash_cache
                WHERE is_on_server = 0 OR (has_raw = 1 AND raw_on_server = 0);
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
