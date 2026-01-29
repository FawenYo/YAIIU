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
    
    func getAllUploadedAssetIds() -> Set<String> {
        connection.ensureInitialized()
        var ids: Set<String> = []
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            ids = self.getAllUploadedAssetIdsInternal()
        }
        
        return ids
    }
    
    func getAllUploadedAssetIdsAsync(completion: @escaping (Set<String>) -> Void) {
        connection.dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let ids = self.getAllUploadedAssetIdsInternal()
            DispatchQueue.main.async {
                completion(ids)
            }
        }
    }
    
    private func getAllUploadedAssetIdsInternal() -> Set<String> {
        let sql = "SELECT DISTINCT asset_id FROM uploaded_assets WHERE asset_id != '' AND asset_id IS NOT NULL;"
        var statement: OpaquePointer?
        var ids: Set<String> = []
        
        if sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK {
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
        return ids
    }
    
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
    func getAllUploadedAssetMappingsAsync(completion: @escaping ([(localIdentifier: String, immichId: String)]) -> Void) {
        connection.dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            self.connection.ensureInitialized()
            let mappings = self.getAllUploadedAssetMappingsInternal()
            DispatchQueue.main.async {
                completion(mappings)
            }
        }
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
}
