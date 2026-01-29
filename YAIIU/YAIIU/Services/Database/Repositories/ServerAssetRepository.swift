import Foundation
import SQLite3

final class ServerAssetRepository {
    private let connection: SQLiteConnection
    
    init(connection: SQLiteConnection = .shared) {
        self.connection = connection
    }
    
    // MARK: - Save Methods
    
    func saveServerAssets(_ assets: [ServerAssetRecord], syncType: String = "full") {
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            logInfo("Saving \(assets.count) server assets to cache (sync type: \(syncType))", category: .database)
            
            self.connection.beginTransaction()
            
            let sql = """
            INSERT OR REPLACE INTO server_assets_cache
            (immich_id, checksum, original_filename, asset_type, updated_at, synced_at, icloud_id)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                let syncTime = Date().timeIntervalSince1970
                
                for asset in assets {
                    sqlite3_bind_text(statement, 1, (asset.immichId as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(statement, 2, (asset.checksum as NSString).utf8String, -1, nil)
                    
                    if let filename = asset.originalFilename {
                        sqlite3_bind_text(statement, 3, (filename as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_null(statement, 3)
                    }
                    
                    if let type = asset.assetType {
                        sqlite3_bind_text(statement, 4, (type as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_null(statement, 4)
                    }
                    
                    if let updatedAt = asset.updatedAt {
                        sqlite3_bind_text(statement, 5, (updatedAt as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_null(statement, 5)
                    }
                    
                    sqlite3_bind_double(statement, 6, syncTime)
                    
                    if let iCloudId = asset.iCloudId {
                        sqlite3_bind_text(statement, 7, (iCloudId as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_null(statement, 7)
                    }
                    
                    if sqlite3_step(statement) != SQLITE_DONE {
                        logError("Failed to save server asset: \(self.connection.lastErrorMessage)", category: .database)
                    }
                    
                    sqlite3_reset(statement)
                }
            }
            sqlite3_finalize(statement)
            
            self.connection.commitTransaction()
            
            logInfo("Server assets cache updated successfully", category: .database)
        }
    }
    
    // MARK: - Delete Methods
    
    func deleteServerAssets(_ immichIds: [String]) {
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            if immichIds.isEmpty { return }
            
            logInfo("Deleting \(immichIds.count) assets from server cache", category: .database)
            
            self.connection.beginTransaction()
            
            let sql = "DELETE FROM server_assets_cache WHERE immich_id = ?;"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                for immichId in immichIds {
                    sqlite3_bind_text(statement, 1, (immichId as NSString).utf8String, -1, nil)
                    sqlite3_step(statement)
                    sqlite3_reset(statement)
                }
            }
            sqlite3_finalize(statement)
            
            self.connection.commitTransaction()
        }
    }
    
    // MARK: - Query Methods
    
    func isAssetOnServer(checksum: String) -> Bool {
        var exists = false
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            let sql = "SELECT COUNT(*) FROM server_assets_cache WHERE checksum = ?;"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (checksum as NSString).utf8String, -1, nil)
                
                if sqlite3_step(statement) == SQLITE_ROW {
                    exists = sqlite3_column_int(statement, 0) > 0
                }
            }
            sqlite3_finalize(statement)
        }
        
        return exists
    }
    
    func getServerAssetByChecksum(_ checksum: String) -> ServerAssetRecord? {
        var asset: ServerAssetRecord?
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            let sql = "SELECT immich_id, checksum, original_filename, asset_type, updated_at, icloud_id FROM server_assets_cache WHERE checksum = ? LIMIT 1;"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (checksum as NSString).utf8String, -1, nil)
                
                if sqlite3_step(statement) == SQLITE_ROW {
                    asset = ServerAssetRecord(
                        immichId: String(cString: sqlite3_column_text(statement, 0)),
                        checksum: String(cString: sqlite3_column_text(statement, 1)),
                        originalFilename: sqlite3_column_text(statement, 2).map { String(cString: $0) },
                        assetType: sqlite3_column_text(statement, 3).map { String(cString: $0) },
                        updatedAt: sqlite3_column_text(statement, 4).map { String(cString: $0) },
                        iCloudId: sqlite3_column_text(statement, 5).map { String(cString: $0) }
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
            
            let sql = "SELECT immich_id, checksum, original_filename, asset_type, updated_at, icloud_id FROM server_assets_cache WHERE icloud_id = ? LIMIT 1;"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (iCloudId as NSString).utf8String, -1, nil)
                
                if sqlite3_step(statement) == SQLITE_ROW {
                    asset = ServerAssetRecord(
                        immichId: String(cString: sqlite3_column_text(statement, 0)),
                        checksum: String(cString: sqlite3_column_text(statement, 1)),
                        originalFilename: sqlite3_column_text(statement, 2).map { String(cString: $0) },
                        assetType: sqlite3_column_text(statement, 3).map { String(cString: $0) },
                        updatedAt: sqlite3_column_text(statement, 4).map { String(cString: $0) },
                        iCloudId: sqlite3_column_text(statement, 5).map { String(cString: $0) }
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
            
            let sql = "SELECT checksum FROM server_assets_cache WHERE icloud_id = ? LIMIT 1;"
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
                let sql = "SELECT icloud_id, checksum FROM server_assets_cache WHERE icloud_id IN (\(placeholders));"
                
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
    
    func clearServerAssetsCache() {
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            logInfo("Clearing server assets cache", category: .database)
            self.connection.executeStatement("DELETE FROM server_assets_cache;")
            self.connection.executeStatement("DELETE FROM sync_metadata;")
        }
    }
    
    // MARK: - Sync Metadata
    
    func saveSyncMetadata(lastSyncTime: Date, syncType: String, userId: String, totalAssets: Int) {
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            let sql = """
            INSERT OR REPLACE INTO sync_metadata
            (id, last_sync_time, last_sync_type, user_id, total_assets)
            VALUES (1, ?, ?, ?, ?);
            """
            
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_double(statement, 1, lastSyncTime.timeIntervalSince1970)
                sqlite3_bind_text(statement, 2, (syncType as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 3, (userId as NSString).utf8String, -1, nil)
                sqlite3_bind_int(statement, 4, Int32(totalAssets))
                
                if sqlite3_step(statement) != SQLITE_DONE {
                    logError("Failed to save sync metadata: \(self.connection.lastErrorMessage)", category: .database)
                }
            }
            sqlite3_finalize(statement)
        }
    }
    
    func getSyncMetadata() -> SyncMetadata? {
        var metadata: SyncMetadata?
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            let sql = "SELECT * FROM sync_metadata WHERE id = 1;"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    let lastSyncTime = sqlite3_column_type(statement, 1) != SQLITE_NULL
                        ? Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                        : nil
                    let lastSyncType = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                    let userId = sqlite3_column_text(statement, 3).map { String(cString: $0) }
                    let totalAssets = Int(sqlite3_column_int(statement, 4))
                    
                    metadata = SyncMetadata(
                        lastSyncTime: lastSyncTime,
                        lastSyncType: lastSyncType,
                        userId: userId,
                        totalAssets: totalAssets
                    )
                }
            }
            sqlite3_finalize(statement)
        }
        
        return metadata
    }
}
