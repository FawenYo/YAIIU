import Foundation
import SQLite3

final class UploadRecordRepository {
    private let connection: SQLiteConnection
    
    init(connection: SQLiteConnection = .shared) {
        self.connection = connection
    }
    
    // MARK: - Query Methods
    
    func isAssetUploaded(localIdentifier: String, resourceType: String = "primary") -> Bool {
        connection.ensureInitialized()
        var result = false
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            result = self.isAssetUploadedInternal(localIdentifier: localIdentifier, resourceType: resourceType)
        }
        
        return result
    }
    
    private func isAssetUploadedInternal(localIdentifier: String, resourceType: String) -> Bool {
        let sql = "SELECT COUNT(*) FROM uploaded_assets WHERE asset_id = ? AND resource_type = ?;"
        var statement: OpaquePointer?
        var isUploaded = false
        
        if sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, localIdentifier, -1, nil)
            sqlite3_bind_text(statement, 2, resourceType, -1, nil)
            
            if sqlite3_step(statement) == SQLITE_ROW {
                isUploaded = sqlite3_column_int(statement, 0) > 0
            }
        }
        
        sqlite3_finalize(statement)
        return isUploaded
    }
    
    func isAnyResourceUploaded(localIdentifier: String) -> Bool {
        connection.ensureInitialized()
        var result = false
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            result = self.isAnyResourceUploadedInternal(localIdentifier: localIdentifier)
        }
        
        return result
    }
    
    private func isAnyResourceUploadedInternal(localIdentifier: String) -> Bool {
        let sql = "SELECT COUNT(*) FROM uploaded_assets WHERE asset_id = ?;"
        var statement: OpaquePointer?
        var isUploaded = false
        
        if sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, localIdentifier, -1, nil)
            
            if sqlite3_step(statement) == SQLITE_ROW {
                isUploaded = sqlite3_column_int(statement, 0) > 0
            }
        }
        
        sqlite3_finalize(statement)
        return isUploaded
    }
    
    // MARK: - Insert/Update Methods
    
    func recordUploadedAsset(
        localIdentifier: String,
        resourceType: String,
        filename: String,
        immichId: String,
        fileSize: Int64 = 0,
        isDuplicate: Bool = false,
        isFavorite: Bool = false
    ) {
        connection.ensureInitialized()
        logDebug("Recording uploaded asset: \(filename) (type: \(resourceType), immichId: \(immichId), favorite: \(isFavorite))", category: .database)
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            self.recordUploadedAssetInternal(
                localIdentifier: localIdentifier,
                resourceType: resourceType,
                filename: filename,
                immichId: immichId,
                fileSize: fileSize,
                isDuplicate: isDuplicate,
                isFavorite: isFavorite
            )
        }
    }
    
    private func recordUploadedAssetInternal(
        localIdentifier: String,
        resourceType: String,
        filename: String,
        immichId: String,
        fileSize: Int64,
        isDuplicate: Bool,
        isFavorite: Bool
    ) {
        let sql = """
        INSERT OR REPLACE INTO uploaded_assets
        (asset_id, resource_type, filename, immich_id, file_size, is_duplicate, is_favorite, uploaded_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (localIdentifier as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (resourceType as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (filename as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 4, (immichId as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(statement, 5, fileSize)
            sqlite3_bind_int(statement, 6, isDuplicate ? 1 : 0)
            sqlite3_bind_int(statement, 7, isFavorite ? 1 : 0)
            sqlite3_bind_double(statement, 8, Date().timeIntervalSince1970)
            
            if sqlite3_step(statement) != SQLITE_DONE {
                logError("Failed to record uploaded asset: \(connection.lastErrorMessage)", category: .database)
            }
        } else {
            logError("Failed to prepare statement for recordUploadedAsset: \(connection.lastErrorMessage)", category: .database)
        }
        
        sqlite3_finalize(statement)
    }
    
    // MARK: - Count Methods
    
    func getUploadedCount() -> Int {
        connection.ensureInitialized()
        var count = 0
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            count = self.getUploadedCountInternal()
        }
        
        return count
    }
    
    func getUploadedCountAsync(completion: @escaping (Int) -> Void) {
        connection.dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(0) }
                return
            }
            self.connection.ensureInitialized()
            let count = self.getUploadedCountInternal()
            DispatchQueue.main.async {
                completion(count)
            }
        }
    }
    
    private func getUploadedCountInternal() -> Int {
        let sql = "SELECT COUNT(DISTINCT asset_id) FROM uploaded_assets;"
        var statement: OpaquePointer?
        var count = 0
        
        if sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                count = Int(sqlite3_column_int(statement, 0))
            }
        }
        
        sqlite3_finalize(statement)
        return count
    }
    
    func getUploadedResourceCount() -> Int {
        connection.ensureInitialized()
        var count = 0
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            count = self.getUploadedResourceCountInternal()
        }
        
        return count
    }
    
    private func getUploadedResourceCountInternal() -> Int {
        let sql = "SELECT COUNT(*) FROM uploaded_assets;"
        var statement: OpaquePointer?
        var count = 0
        
        if sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                count = Int(sqlite3_column_int(statement, 0))
            }
        }
        
        sqlite3_finalize(statement)
        return count
    }
    
    // MARK: - Fetch Methods

    func getUploadRecords(for localIdentifier: String) -> [UploadRecord] {
        connection.ensureInitialized()
        var records: [UploadRecord] = []
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            records = self.getUploadRecordsInternal(for: localIdentifier)
        }
        
        return records
    }
    
    private func getUploadRecordsInternal(for localIdentifier: String) -> [UploadRecord] {
        let sql = "SELECT * FROM uploaded_assets WHERE asset_id = ?;"
        var statement: OpaquePointer?
        var records: [UploadRecord] = []
        
        if sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, localIdentifier, -1, nil)
            
            while sqlite3_step(statement) == SQLITE_ROW {
                let uploadedAt = sqlite3_column_double(statement, 7)
                let record = UploadRecord(
                    id: Int(sqlite3_column_int(statement, 0)),
                    localIdentifier: String(cString: sqlite3_column_text(statement, 1)),
                    resourceType: String(cString: sqlite3_column_text(statement, 2)),
                    filename: String(cString: sqlite3_column_text(statement, 3)),
                    immichId: sqlite3_column_text(statement, 4).map { String(cString: $0) },
                    uploadedAt: String(format: "%.0f", uploadedAt),
                    fileSize: sqlite3_column_int64(statement, 5),
                    isDuplicate: sqlite3_column_int(statement, 6) == 1
                )
                records.append(record)
            }
        }
        
        sqlite3_finalize(statement)
        return records
    }
    
    // MARK: - Delete Methods
    
    func deleteUploadRecord(for localIdentifier: String) {
        connection.ensureInitialized()
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            self.deleteUploadRecordInternal(for: localIdentifier)
        }
    }
    
    private func deleteUploadRecordInternal(for localIdentifier: String) {
        let sql = "DELETE FROM uploaded_assets WHERE asset_id = ?;"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, localIdentifier, -1, nil)
            sqlite3_step(statement)
        }
        
        sqlite3_finalize(statement)
    }
    
    func clearAllUploadRecords() {
        connection.ensureInitialized()
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            self.connection.executeStatement("DELETE FROM uploaded_assets;")
            self.connection.executeStatement("DELETE FROM upload_jobs;")
        }
    }
    
    // MARK: - iCloud ID Sync Support
    
    /// Returns all uploaded asset mappings (local identifier -> immich ID).
    /// Used for iCloud ID sync to find which assets need metadata updates.
    func getAllUploadedAssetMappings() -> [(localIdentifier: String, immichId: String)] {
        connection.ensureInitialized()
        var mappings: [(String, String)] = []
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            mappings = self.getAllUploadedAssetMappingsInternal()
        }
        
        return mappings
    }
    
    /// Async version for background processing.
    /// Note: completion is called on the database queue, not the main queue.
    func getAllUploadedAssetMappingsAsync(completion: @escaping ([(localIdentifier: String, immichId: String)]) -> Void) {
        connection.dbQueue.async { [weak self] in
            guard let self = self else {
                completion([])
                return
            }
            self.connection.ensureInitialized()
            let mappings = self.getAllUploadedAssetMappingsInternal()
            completion(mappings)
        }
    }
    
    func albumAssetIds(for localIdentifiers: [String], ownerId: String) throws -> [String] {
        guard !localIdentifiers.isEmpty else { return [] }
        connection.ensureInitialized()
        let chunkSize = 500
        var allIds: [String] = []
        for chunkStart in stride(from: 0, to: localIdentifiers.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, localIdentifiers.count)
            let chunk = Array(localIdentifiers[chunkStart..<chunkEnd])
            let chunkIds = try connection.dbQueue.sync {
                let values = Array(repeating: "(?)", count: chunk.count).joined(separator: ",")
                let sql = """
                WITH requested(asset_id) AS (VALUES \(values))
                SELECT u.immich_id
                FROM requested r
                JOIN uploaded_assets u ON u.asset_id = r.asset_id
                JOIN server_assets_cache s ON s.immich_id = u.immich_id
                WHERE u.id = (
                    SELECT MAX(u2.id) FROM uploaded_assets u2
                    WHERE u2.asset_id = u.asset_id
                      AND (
                          u2.resource_type NOT IN ('raw', 'video')
                          OR NOT EXISTS (
                              SELECT 1 FROM uploaded_assets u3
                              WHERE u3.asset_id = u.asset_id
                                AND u3.resource_type NOT IN ('raw', 'video')
                          )
                      )
                ) AND s.owner_id = ?
                UNION
                SELECT s.immich_id
                FROM requested r
                JOIN hash_cache h ON h.asset_id = r.asset_id
                JOIN server_assets_cache s ON s.source_checksum = h.sha1_hash
                WHERE s.owner_id = ?
                UNION
                SELECT s.immich_id
                FROM requested r
                JOIN hash_cache h ON h.asset_id = r.asset_id
                JOIN server_assets_cache s ON s.checksum = h.sha1_hash
                WHERE s.owner_id = ? AND s.source_checksum IS NULL
                """
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                func databaseError() -> NSError {
                    NSError(domain: "AlbumAssetResolver", code: Int(sqlite3_errcode(connection.db)),
                            userInfo: [NSLocalizedDescriptionKey: connection.lastErrorMessage])
                }
                guard sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK else { throw databaseError() }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                for (index, localIdentifier) in chunk.enumerated() {
                    _ = localIdentifier.withCString { value in
                        sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
                    }
                }
                let ownerBindingStart = chunk.count + 1
                _ = ownerId.withCString { value in
                    sqlite3_bind_text(statement, Int32(ownerBindingStart), value, -1, transient)
                    sqlite3_bind_text(statement, Int32(ownerBindingStart + 1), value, -1, transient)
                    sqlite3_bind_text(statement, Int32(ownerBindingStart + 2), value, -1, transient)
                }
                var ids: [String] = []
                var result = sqlite3_step(statement)
                while result == SQLITE_ROW {
                    if let text = sqlite3_column_text(statement, 0) {
                        let id = String(cString: text)
                        if UUID(uuidString: id) != nil { ids.append(id) }
                    }
                    result = sqlite3_step(statement)
                }
                guard result == SQLITE_DONE else { throw databaseError() }
                return ids
            }
            allIds.append(contentsOf: chunkIds)
        }
        return allIds
    }

    private func getAllUploadedAssetMappingsInternal() -> [(localIdentifier: String, immichId: String)] {
        let sql = """
        SELECT DISTINCT asset_id, immich_id FROM uploaded_assets
        WHERE asset_id != '' AND asset_id IS NOT NULL
        AND immich_id != '' AND immich_id IS NOT NULL
        AND resource_type = 'primary';
        """
        var statement: OpaquePointer?
        var mappings: [(String, String)] = []
        
        if sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let localIdPtr = sqlite3_column_text(statement, 0),
                   let immichIdPtr = sqlite3_column_text(statement, 1) {
                    let localId = String(cString: localIdPtr)
                    let immichId = String(cString: immichIdPtr)
                    if !localId.isEmpty && !immichId.isEmpty {
                        mappings.append((localId, immichId))
                    }
                }
            }
        }
        
        sqlite3_finalize(statement)
        return mappings
    }

    // MARK: - Backfill Support

    /// Returns a mapping of asset_id → immich_id for all 'unknown' rows that can be resolved
    /// via a single JOIN across uploaded_assets, hash_cache, and server_assets_cache.
    func getResolvedImmichIdsFromServerCache() -> [String: String] {
        connection.ensureInitialized()
        var resolved: [String: String] = [:]

        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            let sql = """
            SELECT ua.asset_id, sac.immich_id
            FROM uploaded_assets ua
            JOIN hash_cache hc ON hc.asset_id = ua.asset_id
            JOIN server_assets_cache sac ON sac.source_checksum = hc.sha1_hash
            WHERE ua.immich_id = 'unknown'
              AND NOT (
                  ua.resource_type IN ('raw', 'video')
                  AND EXISTS (
                      SELECT 1 FROM uploaded_assets ua2
                      WHERE ua2.asset_id = ua.asset_id
                        AND ua2.resource_type NOT IN ('raw', 'video')
                  )
              )
            UNION
            SELECT ua.asset_id, sac.immich_id
            FROM uploaded_assets ua
            JOIN hash_cache hc ON hc.asset_id = ua.asset_id
            JOIN server_assets_cache sac ON sac.checksum = hc.sha1_hash
            WHERE sac.source_checksum IS NULL
              AND ua.immich_id = 'unknown'
              AND NOT (
                  ua.resource_type IN ('raw', 'video')
                  AND EXISTS (
                      SELECT 1 FROM uploaded_assets ua2
                      WHERE ua2.asset_id = ua.asset_id
                        AND ua2.resource_type NOT IN ('raw', 'video')
                  )
              );
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let assetPtr = sqlite3_column_text(statement, 0),
                       let immichPtr = sqlite3_column_text(statement, 1) {
                        resolved[String(cString: assetPtr)] = String(cString: immichPtr)
                    }
                }
            }
            sqlite3_finalize(statement)
        }

        return resolved
    }

    /// Returns asset IDs where immich_id was never resolved (recorded as 'unknown').
    func getUnknownImmichIdAssetIds() -> [String] {
        connection.ensureInitialized()
        var assetIds: [String] = []

        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            let sql = """
            SELECT DISTINCT asset_id FROM uploaded_assets
            WHERE immich_id = 'unknown';
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let ptr = sqlite3_column_text(statement, 0) {
                        assetIds.append(String(cString: ptr))
                    }
                }
            }
            sqlite3_finalize(statement)
        }

        return assetIds
    }

    /// Updates immich_id for all rows matching the given asset_id where immich_id is 'unknown'.
    func batchUpdateImmichIds(_ mappings: [String: String]) {

        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            self.connection.inTransaction {
                let sql = """
                UPDATE uploaded_assets SET immich_id = ?
                WHERE asset_id = ? AND immich_id = 'unknown'
                  AND NOT (
                      resource_type IN ('raw', 'video')
                      AND EXISTS (
                          SELECT 1 FROM uploaded_assets ua2
                          WHERE ua2.asset_id = uploaded_assets.asset_id
                            AND ua2.resource_type NOT IN ('raw', 'video')
                      )
                  );
                """
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK else {
                    logError("Failed to prepare statement for batch immich_id update: \(self.connection.lastErrorMessage)", category: .database)
                    return
                }
                defer { sqlite3_finalize(statement) }

                for (assetId, immichId) in mappings {
                    sqlite3_bind_text(statement, 1, (immichId as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(statement, 2, (assetId as NSString).utf8String, -1, nil)
                    if sqlite3_step(statement) != SQLITE_DONE {
                        logError("Failed to update immich_id for asset \(assetId): \(self.connection.lastErrorMessage)", category: .database)
                    }
                    sqlite3_reset(statement)
                }
            }
        }
    }
}
