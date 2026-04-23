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
    
    // MARK: - Modified Asset Invalidation

    /// Deletes hash_cache and uploaded_assets rows for assets whose modificationDate
    /// has changed since the date was last stored. Assets with NULL stored dates are skipped.
    func resetCacheForModifiedAssets(assets: [PHAsset]) {
        guard !assets.isEmpty else { return }

        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            self.resetCacheForModifiedAssetsInternal(assets: assets)
        }
    }

    private func resetCacheForModifiedAssetsInternal(assets: [PHAsset]) {
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
            backfillModificationDates(assets: assets, assetIds: nullDateIds)
        }

        guard !storedDates.isEmpty else { return }

        // Compare current modificationDate against stored date
        var invalidatedIds: [String] = []

        for asset in assets {
            let identifier = asset.localIdentifier
            guard let storedTimestamp = storedDates[identifier] else { continue }
            guard let currentDate = asset.modificationDate else { continue }

            let currentTimestamp = currentDate.timeIntervalSince1970
            // Use 1-second tolerance to avoid floating point noise
            if abs(currentTimestamp - storedTimestamp) > 1.0 {
                invalidatedIds.append(identifier)
            }
        }

        guard !invalidatedIds.isEmpty else { return }

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

    private func backfillModificationDates(assets: [PHAsset], assetIds: Set<String>) {
        let sql = "UPDATE hash_cache SET asset_modification_date = ? WHERE asset_id = ?;"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        connection.beginTransaction()
        var failed = false
        var count = 0
        for asset in assets {
            guard assetIds.contains(asset.localIdentifier),
                  let modDate = asset.modificationDate else { continue }

            sqlite3_bind_double(statement, 1, modDate.timeIntervalSince1970)
            sqlite3_bind_text(statement, 2, (asset.localIdentifier as NSString).utf8String, -1, nil)
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
