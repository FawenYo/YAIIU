import Foundation
import SQLite3

final class ServerAssetRepository {
    private let connection: SQLiteConnection
    
    init(connection: SQLiteConnection = .shared) {
        self.connection = connection
    }
    
    // MARK: - Save Methods
    
    @discardableResult
    func saveServerAssets(_ assets: [ServerAssetRecord], syncType: String = "full") -> Bool {
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return false }
            
            logInfo("Saving \(assets.count) server assets to cache (sync type: \(syncType))", category: .database)
            
            guard self.connection.beginTransaction() else {
                logError("Failed to begin server asset transaction: \(self.connection.lastErrorMessage)", category: .database)
                return false
            }
            var failed = false
            
            let sql = """
            INSERT INTO server_assets_cache
            (immich_id, checksum, source_checksum, original_filename, asset_type, updated_at, synced_at, icloud_id, owner_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(immich_id) DO UPDATE SET
                checksum = excluded.checksum,
                source_checksum = COALESCE(excluded.source_checksum, server_assets_cache.source_checksum),
                original_filename = excluded.original_filename,
                asset_type = excluded.asset_type,
                updated_at = excluded.updated_at,
                synced_at = excluded.synced_at,
                icloud_id = COALESCE(excluded.icloud_id, server_assets_cache.icloud_id),
                owner_id = COALESCE(excluded.owner_id, server_assets_cache.owner_id);
            """
            
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
                self.connection.rollbackTransaction()
                logError("Failed to prepare server asset upsert: \(self.connection.lastErrorMessage)", category: .database)
                return false
            }
            let syncTime = Date().timeIntervalSince1970

            for asset in assets {
                sqlite3_bind_text(statement, 1, (asset.immichId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 2, (asset.checksum as NSString).utf8String, -1, nil)

                if let sourceChecksum = asset.sourceChecksum {
                    sqlite3_bind_text(statement, 3, (sourceChecksum as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(statement, 3)
                }

                if let filename = asset.originalFilename {
                    sqlite3_bind_text(statement, 4, (filename as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(statement, 4)
                }

                if let type = asset.assetType {
                    sqlite3_bind_text(statement, 5, (type as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(statement, 5)
                }

                if let updatedAt = asset.updatedAt {
                    sqlite3_bind_text(statement, 6, (updatedAt as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(statement, 6)
                }

                sqlite3_bind_double(statement, 7, syncTime)

                if let iCloudId = asset.iCloudId {
                    sqlite3_bind_text(statement, 8, (iCloudId as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(statement, 8)
                }

                if let ownerId = asset.ownerId {
                    sqlite3_bind_text(statement, 9, (ownerId as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(statement, 9)
                }

                if sqlite3_step(statement) != SQLITE_DONE {
                    failed = true
                    logError("Failed to save server asset: \(self.connection.lastErrorMessage)", category: .database)
                    break
                }

                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            sqlite3_finalize(statement)

            if failed {
                self.connection.rollbackTransaction()
                return false
            }

            guard self.connection.commitTransaction() else {
                logError("Failed to commit server asset upserts: \(self.connection.lastErrorMessage)", category: .database)
                self.connection.rollbackTransaction()
                return false
            }
            logInfo("Server assets cache updated successfully", category: .database)
            return true
        }
    }
    
    @discardableResult
    func updateICloudIds(_ iCloudIdsByImmichId: [String: String]) -> Bool {
        guard !iCloudIdsByImmichId.isEmpty else { return true }

        return connection.dbQueue.sync { [weak self] in
            guard let self = self else { return false }

            guard self.connection.beginTransaction() else {
                logError("Failed to begin iCloud ID update transaction: \(self.connection.lastErrorMessage)", category: .database)
                return false
            }
            let sql = "UPDATE server_assets_cache SET icloud_id = ? WHERE immich_id = ?;"
            var statement: OpaquePointer?
            var failed = false

            guard sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
                self.connection.rollbackTransaction()
                logError("Failed to prepare iCloud ID updates: \(self.connection.lastErrorMessage)", category: .database)
                return false
            }

            for (immichId, iCloudId) in iCloudIdsByImmichId {
                sqlite3_bind_text(statement, 1, (iCloudId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 2, (immichId as NSString).utf8String, -1, nil)
                if sqlite3_step(statement) != SQLITE_DONE {
                    failed = true
                    logError("Failed to update iCloud ID: \(self.connection.lastErrorMessage)", category: .database)
                    break
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }

            sqlite3_finalize(statement)
            if failed {
                self.connection.rollbackTransaction()
                return false
            }

            guard self.connection.commitTransaction() else {
                logError("Failed to commit iCloud ID updates: \(self.connection.lastErrorMessage)", category: .database)
                self.connection.rollbackTransaction()
                return false
            }
            logInfo("Updated iCloud IDs for \(iCloudIdsByImmichId.count) cached assets", category: .database)
            return true
        }
    }

    @discardableResult
    func clearICloudIds(for immichIds: Set<String>) -> Bool {
        guard !immichIds.isEmpty else { return true }

        return connection.dbQueue.sync { [weak self] in
            guard let self = self else { return false }

            guard self.connection.beginTransaction() else {
                logError("Failed to begin iCloud ID delete transaction: \(self.connection.lastErrorMessage)", category: .database)
                return false
            }
            let sql = "UPDATE server_assets_cache SET icloud_id = NULL WHERE immich_id = ?;"
            var statement: OpaquePointer?
            var failed = false

            guard sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
                self.connection.rollbackTransaction()
                logError("Failed to prepare iCloud ID deletes: \(self.connection.lastErrorMessage)", category: .database)
                return false
            }

            for immichId in immichIds {
                sqlite3_bind_text(statement, 1, (immichId as NSString).utf8String, -1, nil)
                if sqlite3_step(statement) != SQLITE_DONE {
                    failed = true
                    logError("Failed to clear iCloud ID: \(self.connection.lastErrorMessage)", category: .database)
                    break
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }

            sqlite3_finalize(statement)
            if failed {
                self.connection.rollbackTransaction()
                return false
            }

            guard self.connection.commitTransaction() else {
                logError("Failed to commit iCloud ID deletes: \(self.connection.lastErrorMessage)", category: .database)
                self.connection.rollbackTransaction()
                return false
            }
            logInfo("Cleared iCloud IDs for \(immichIds.count) cached assets", category: .database)
            return true
        }
    }

    /// Attach source checksums delivered by AssetMetadataV1 events for rows
    /// already in the cache. Rows missing from the cache are skipped; their
    /// checksum arrives with the AssetV2 event instead.
    @discardableResult
    func updateSourceChecksums(_ sourceChecksumsByImmichId: [String: String]) -> Bool {
        guard !sourceChecksumsByImmichId.isEmpty else { return true }

        return connection.dbQueue.sync { [weak self] in
            guard let self = self else { return false }

            guard self.connection.beginTransaction() else {
                logError("Failed to begin source checksum update transaction: \(self.connection.lastErrorMessage)", category: .database)
                return false
            }
            let sql = "UPDATE server_assets_cache SET source_checksum = ? WHERE immich_id = ?;"
            var statement: OpaquePointer?
            var failed = false

            guard sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
                self.connection.rollbackTransaction()
                logError("Failed to prepare source checksum updates: \(self.connection.lastErrorMessage)", category: .database)
                return false
            }

            for (immichId, sourceChecksum) in sourceChecksumsByImmichId {
                sqlite3_bind_text(statement, 1, (sourceChecksum as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 2, (immichId as NSString).utf8String, -1, nil)
                if sqlite3_step(statement) != SQLITE_DONE {
                    failed = true
                    logError("Failed to update source checksum: \(self.connection.lastErrorMessage)", category: .database)
                    break
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }

            sqlite3_finalize(statement)
            if failed {
                self.connection.rollbackTransaction()
                return false
            }

            guard self.connection.commitTransaction() else {
                logError("Failed to commit source checksum updates: \(self.connection.lastErrorMessage)", category: .database)
                self.connection.rollbackTransaction()
                return false
            }
            logInfo("Updated source checksums for \(sourceChecksumsByImmichId.count) cached assets", category: .database)
            return true
        }
    }

    /// Returns source checksums held by the cache for the given assets.
    /// Missing rows and rows without a checksum are omitted.
    func sourceChecksums(for immichIds: [String]) -> [String: String] {
        guard !immichIds.isEmpty else { return [:] }
        connection.ensureInitialized()
        var result: [String: String] = [:]
        let chunkSize = 500
        for chunkStart in stride(from: 0, to: immichIds.count, by: chunkSize) {
            let chunk = Array(immichIds[chunkStart..<min(chunkStart + chunkSize, immichIds.count)])
            connection.dbQueue.sync { [weak self] in
                guard let self else { return }
                let values = Array(repeating: "(?)", count: chunk.count).joined(separator: ",")
                let sql = """
                SELECT immich_id, source_checksum
                FROM server_assets_cache
                WHERE immich_id IN (VALUES \(values)) AND source_checksum IS NOT NULL;
                """
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                guard sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
                    logError("Failed to prepare source checksum lookup: \(self.connection.lastErrorMessage)", category: .database)
                    return
                }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                for (index, immichId) in chunk.enumerated() {
                    _ = immichId.withCString { value in
                        sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
                    }
                }
                while sqlite3_step(statement) == SQLITE_ROW {
                    let immichId = String(cString: sqlite3_column_text(statement, 0))
                    if let checksum = sqlite3_column_text(statement, 1).map({ String(cString: $0) }) {
                        result[immichId] = checksum
                    }
                }
            }
        }
        return result
    }

    // MARK: - Delete Methods
    
    @discardableResult
    func deleteServerAssets(_ immichIds: [String]) -> Bool {
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return false }
            guard !immichIds.isEmpty else { return true }
            
            logInfo("Deleting \(immichIds.count) assets from server cache", category: .database)
            
            guard self.connection.beginTransaction() else {
                logError("Failed to begin server asset delete transaction: \(self.connection.lastErrorMessage)", category: .database)
                return false
            }
            
            let sql = "DELETE FROM server_assets_cache WHERE immich_id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
                self.connection.rollbackTransaction()
                logError("Failed to prepare server asset deletes: \(self.connection.lastErrorMessage)", category: .database)
                return false
            }

            var failed = false
            for immichId in immichIds {
                sqlite3_bind_text(statement, 1, (immichId as NSString).utf8String, -1, nil)
                if sqlite3_step(statement) != SQLITE_DONE {
                    failed = true
                    logError("Failed to delete server asset: \(self.connection.lastErrorMessage)", category: .database)
                    break
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            sqlite3_finalize(statement)

            if failed {
                self.connection.rollbackTransaction()
                return false
            }

            guard self.connection.commitTransaction() else {
                logError("Failed to commit server asset deletes: \(self.connection.lastErrorMessage)", category: .database)
                self.connection.rollbackTransaction()
                return false
            }
            return true
        }
    }
    
    // MARK: - Query Methods
    
    /// Rows are matched by source checksum first, then by server checksum for
    /// rows without one (equivalent to COALESCE(source_checksum, checksum) = ?
    /// while keeping both branches on their expression-free indexes).
    func isAssetOnServer(checksum: String) -> Bool {
        var exists = false
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            let sql = """
            SELECT 1 FROM server_assets_cache WHERE source_checksum = ?
            UNION ALL
            SELECT 1 FROM server_assets_cache WHERE checksum = ? AND source_checksum IS NULL
            LIMIT 1;
            """
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (checksum as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 2, (checksum as NSString).utf8String, -1, nil)
                
                exists = sqlite3_step(statement) == SQLITE_ROW
            }
            sqlite3_finalize(statement)
        }
        
        return exists
    }
    
    func getServerAssetByChecksum(_ checksum: String) -> ServerAssetRecord? {
        var asset: ServerAssetRecord?
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            let sql = """
            SELECT immich_id, checksum, source_checksum, original_filename, asset_type, updated_at, icloud_id, owner_id
            FROM server_assets_cache WHERE source_checksum = ?
            UNION ALL
            SELECT immich_id, checksum, source_checksum, original_filename, asset_type, updated_at, icloud_id, owner_id
            FROM server_assets_cache WHERE checksum = ? AND source_checksum IS NULL
            LIMIT 1;
            """
            var statement: OpaquePointer?

            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (checksum as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 2, (checksum as NSString).utf8String, -1, nil)

                if sqlite3_step(statement) == SQLITE_ROW {
                    asset = ServerAssetRecord(
                        immichId: String(cString: sqlite3_column_text(statement, 0)),
                        checksum: String(cString: sqlite3_column_text(statement, 1)),
                        sourceChecksum: sqlite3_column_text(statement, 2).map { String(cString: $0) },
                        originalFilename: sqlite3_column_text(statement, 3).map { String(cString: $0) },
                        assetType: sqlite3_column_text(statement, 4).map { String(cString: $0) },
                        updatedAt: sqlite3_column_text(statement, 5).map { String(cString: $0) },
                        iCloudId: sqlite3_column_text(statement, 6).map { String(cString: $0) },
                        ownerId: sqlite3_column_text(statement, 7).map { String(cString: $0) }
                    )
                }
            }
            sqlite3_finalize(statement)
        }
        
        return asset
    }
    func getServerAssetByImmichId(_ immichId: String) -> ServerAssetRecord? {
        var asset: ServerAssetRecord?

        connection.dbQueue.sync { [weak self] in
            guard let self else { return }

            let sql = "SELECT immich_id, checksum, source_checksum, original_filename, asset_type, updated_at, icloud_id, owner_id FROM server_assets_cache WHERE immich_id = ? LIMIT 1;"
            var statement: OpaquePointer?

            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (immichId as NSString).utf8String, -1, nil)

                if sqlite3_step(statement) == SQLITE_ROW {
                    asset = ServerAssetRecord(
                        immichId: String(cString: sqlite3_column_text(statement, 0)),
                        checksum: String(cString: sqlite3_column_text(statement, 1)),
                        sourceChecksum: sqlite3_column_text(statement, 2).map { String(cString: $0) },
                        originalFilename: sqlite3_column_text(statement, 3).map { String(cString: $0) },
                        assetType: sqlite3_column_text(statement, 4).map { String(cString: $0) },
                        updatedAt: sqlite3_column_text(statement, 5).map { String(cString: $0) },
                        iCloudId: sqlite3_column_text(statement, 6).map { String(cString: $0) },
                        ownerId: sqlite3_column_text(statement, 7).map { String(cString: $0) }
                    )
                }
            }
            sqlite3_finalize(statement)
        }

        return asset
    }

    
    /// Find a server asset by its iCloud ID.
    /// Used to check if another device has already uploaded a photo with the same iCloud ID.
    func getServerAssetByICloudId(_ iCloudId: String) -> ServerAssetRecord? {
        var asset: ServerAssetRecord?
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            let sql = "SELECT immich_id, checksum, source_checksum, original_filename, asset_type, updated_at, icloud_id, owner_id FROM server_assets_cache WHERE icloud_id = ? LIMIT 1;"
            var statement: OpaquePointer?

            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (iCloudId as NSString).utf8String, -1, nil)

                if sqlite3_step(statement) == SQLITE_ROW {
                    asset = ServerAssetRecord(
                        immichId: String(cString: sqlite3_column_text(statement, 0)),
                        checksum: String(cString: sqlite3_column_text(statement, 1)),
                        sourceChecksum: sqlite3_column_text(statement, 2).map { String(cString: $0) },
                        originalFilename: sqlite3_column_text(statement, 3).map { String(cString: $0) },
                        assetType: sqlite3_column_text(statement, 4).map { String(cString: $0) },
                        updatedAt: sqlite3_column_text(statement, 5).map { String(cString: $0) },
                        iCloudId: sqlite3_column_text(statement, 6).map { String(cString: $0) },
                        ownerId: sqlite3_column_text(statement, 7).map { String(cString: $0) }
                    )
                }
            }
            sqlite3_finalize(statement)
        }
        
        return asset
    }
    
    /// Check if an asset with the given iCloud ID exists on the server.
    /// Returns the checksum if found, nil otherwise.
    func getChecksumByICloudId(_ iCloudId: String) -> String? {
        var checksum: String?
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            let sql = "SELECT COALESCE(source_checksum, checksum) FROM server_assets_cache WHERE icloud_id = ? LIMIT 1;"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (iCloudId as NSString).utf8String, -1, nil)
                
                if sqlite3_step(statement) == SQLITE_ROW {
                    checksum = String(cString: sqlite3_column_text(statement, 0))
                }
            }
            sqlite3_finalize(statement)
        }
        
        return checksum
    }
    
    /// Batch lookup checksums by iCloud IDs.
    /// Returns a dictionary mapping iCloud IDs to their checksums.
    func getChecksumsByICloudIds(_ iCloudIds: [String]) -> [String: String] {
        var results: [String: String] = [:]
        
        guard !iCloudIds.isEmpty else { return results }
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            // Process in batches to avoid SQL parameter limits
            let batchSize = 500
            for batch in stride(from: 0, to: iCloudIds.count, by: batchSize) {
                let endIndex = min(batch + batchSize, iCloudIds.count)
                let currentBatch = Array(iCloudIds[batch..<endIndex])
                
                let placeholders = currentBatch.map { _ in "?" }.joined(separator: ",")
                let sql = "SELECT icloud_id, COALESCE(source_checksum, checksum) FROM server_assets_cache WHERE icloud_id IN (\(placeholders));"
                
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                    for (index, iCloudId) in currentBatch.enumerated() {
                        sqlite3_bind_text(statement, Int32(index + 1), (iCloudId as NSString).utf8String, -1, nil)
                    }
                    
                    while sqlite3_step(statement) == SQLITE_ROW {
                        if let iCloudIdPtr = sqlite3_column_text(statement, 0),
                           let checksumPtr = sqlite3_column_text(statement, 1) {
                            let iCloudId = String(cString: iCloudIdPtr)
                            let checksum = String(cString: checksumPtr)
                            results[iCloudId] = checksum
                        }
                    }
                }
                sqlite3_finalize(statement)
            }
        }
        
        return results
    }
    
    func getServerAssetsCacheCount() -> Int {
        var count = 0
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            let sql = "SELECT COUNT(*) FROM server_assets_cache;"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(statement, 0))
                }
            }
            sqlite3_finalize(statement)
        }
        
        return count
    }
    
    func hasServerCache() -> Bool {
        var hasCache = false
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            hasCache = self.hasServerCacheInternal()
        }
        
        return hasCache
    }
    
    /// Internal method for use when already on dbQueue
    func hasServerCacheInternal() -> Bool {
        let sql = "SELECT COUNT(*) FROM server_assets_cache LIMIT 1;"
        var statement: OpaquePointer?
        var hasCache = false
        
        if sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                hasCache = sqlite3_column_int(statement, 0) > 0
            }
        }
        sqlite3_finalize(statement)
        
        return hasCache
    }
    
    // MARK: - Clear Methods
    
    @discardableResult
    func clearServerAssetsCache() -> Bool {
        connection.dbQueue.sync { [weak self] in
            guard let self else { return false }
            logInfo("Clearing server assets cache", category: .database)
            guard self.connection.beginTransaction() else {
                logError("Failed to begin server cache clear: \(self.connection.lastErrorMessage)", category: .database)
                return false
            }

            let statements = ["DELETE FROM server_assets_cache;", "DELETE FROM sync_metadata;"]
            for sql in statements where sqlite3_exec(self.connection.db, sql, nil, nil, nil) != SQLITE_OK {
                logError("Failed to clear server cache: \(self.connection.lastErrorMessage)", category: .database)
                self.connection.rollbackTransaction()
                return false
            }

            guard self.connection.commitTransaction() else {
                logError("Failed to commit server cache clear: \(self.connection.lastErrorMessage)", category: .database)
                self.connection.rollbackTransaction()
                return false
            }
            return true
        }
    }
    
    // MARK: - Sync Metadata

    @discardableResult
    func saveSyncMetadata(
        lastSyncTime: Date,
        syncType: String,
        userId: String,
        serverURL: String,
        totalAssets: Int,
        lastAck: String? = nil
    ) -> Bool {
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return false }

            let sql = """
            INSERT OR REPLACE INTO sync_metadata
            (id, last_sync_time, last_sync_type, user_id, total_assets, last_ack, server_url)
            VALUES (1, ?, ?, ?, ?, ?, ?);
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
                logError("Failed to prepare sync metadata save: \(self.connection.lastErrorMessage)", category: .database)
                return false
            }

            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_double(statement, 1, lastSyncTime.timeIntervalSince1970)
            sqlite3_bind_text(statement, 2, (syncType as NSString).utf8String, -1, transient)
            sqlite3_bind_text(statement, 3, (userId as NSString).utf8String, -1, transient)
            sqlite3_bind_int(statement, 4, Int32(totalAssets))
            if let ack = lastAck {
                sqlite3_bind_text(statement, 5, (ack as NSString).utf8String, -1, transient)
            } else {
                sqlite3_bind_null(statement, 5)
            }
            sqlite3_bind_text(statement, 6, (serverURL as NSString).utf8String, -1, transient)

            if sqlite3_step(statement) != SQLITE_DONE {
                logError("Failed to save sync metadata: \(self.connection.lastErrorMessage)", category: .database)
                sqlite3_finalize(statement)
                return false
            }
            sqlite3_finalize(statement)
            return true
        }
    }

    func getSyncMetadata() -> SyncMetadata? {
        var metadata: SyncMetadata?

        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }

            let sql = "SELECT id, last_sync_time, last_sync_type, user_id, total_assets, last_ack, server_url FROM sync_metadata WHERE id = 1;"
            var statement: OpaquePointer?

            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    let lastSyncTime = sqlite3_column_type(statement, 1) != SQLITE_NULL
                        ? Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                        : nil
                    let lastSyncType = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                    let userId = sqlite3_column_text(statement, 3).map { String(cString: $0) }
                    let totalAssets = Int(sqlite3_column_int(statement, 4))
                    let lastAck = sqlite3_column_text(statement, 5).map { String(cString: $0) }
                    let serverURL = sqlite3_column_text(statement, 6).map { String(cString: $0) }

                    metadata = SyncMetadata(
                        lastSyncTime: lastSyncTime,
                        lastSyncType: lastSyncType,
                        userId: userId,
                        serverURL: serverURL,
                        totalAssets: totalAssets,
                        lastAck: lastAck
                    )
                }
            }
            sqlite3_finalize(statement)
        }

        return metadata
    }
}
