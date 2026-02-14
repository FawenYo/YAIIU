import Foundation
import SQLite3

class ImmichSQLiteImporter {
    static let shared = ImmichSQLiteImporter()
    
    struct ImportResult {
        let totalRecords: Int
        let importedRecords: Int
        let skippedRecords: Int
        let alreadyOnServer: Int
        let errorMessage: String?
    }
    
    typealias ProgressCallback = (Int, Int) -> Void
    
    struct ImmichLocalAsset {
        let id: String
        let name: String
        let type: Int
        let checksum: String?
        let width: Int?
        let height: Int?
        let durationInSeconds: Int?
        let isFavorite: Bool
    }
    
    /// Detected Immich database schema version
    private enum SchemaVersion {
        /// Old schema: local_asset_entity has checksum directly
        case legacy
        /// New schema: checksum is NULL in local_asset_entity, uses remote_asset_cloud_id_entity + i_cloud_id
        case cloudId
    }
    
    private init() {
        logInfo("ImmichSQLiteImporter initialized", category: .importer)
    }
    
    func importFromFile(fileURL: URL) -> ImportResult {
        return importFromFile(fileURL: fileURL, progressCallback: nil)
    }
    
    func importFromFile(fileURL: URL, progressCallback: ProgressCallback?) -> ImportResult {
        logInfo("Starting import from file: \(fileURL.lastPathComponent)", category: .importer)
        
        guard let localURL = copyToTempDirectory(fileURL: fileURL) else {
            logError("Failed to copy file to temp directory", category: .importer)
            return ImportResult(
                totalRecords: 0,
                importedRecords: 0,
                skippedRecords: 0,
                alreadyOnServer: 0,
                errorMessage: "Unable to copy file to temp directory"
            )
        }
        
        defer {
            cleanupTempFiles(baseURL: localURL)
        }
        
        var db: OpaquePointer?
        
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(localURL.path, &db, flags, nil) == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            logError("Failed to open database: \(errorMsg)", category: .importer)
            sqlite3_close(db)
            return ImportResult(
                totalRecords: 0,
                importedRecords: 0,
                skippedRecords: 0,
                alreadyOnServer: 0,
                errorMessage: "Unable to open database: \(errorMsg)"
            )
        }
        
        logDebug("Database opened successfully", category: .importer)
        sqlite3_exec(db, "PRAGMA journal_mode=OFF;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA locking_mode=NORMAL;", nil, nil, nil)
        
        defer {
            sqlite3_close(db)
        }
        
        let schemaVersion = detectSchemaVersion(db: db)
        logInfo("Detected Immich schema version: \(schemaVersion)", category: .importer)
        
        switch schemaVersion {
        case .legacy:
            return importLegacySchema(db: db, progressCallback: progressCallback)
        case .cloudId:
            return importCloudIdSchema(db: db, progressCallback: progressCallback)
        }
    }
    
    // MARK: - Schema Detection
    
    /// Detect whether MySQL uses legacy (checksum in local_asset_entity) or new (cloud_id) schema
    private func detectSchemaVersion(db: OpaquePointer?) -> SchemaVersion {
        // Check if local_asset_entity has any non-null checksums
        var statement: OpaquePointer?
        let checksumCountSql = "SELECT COUNT(*) FROM local_asset_entity WHERE checksum IS NOT NULL AND checksum != '';"
        
        var localChecksumCount = 0
        if sqlite3_prepare_v2(db, checksumCountSql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                localChecksumCount = Int(sqlite3_column_int(statement, 0))
            }
        }
        sqlite3_finalize(statement)
        
        if localChecksumCount > 0 {
            logDebug("Found \(localChecksumCount) local checksums - using legacy schema", category: .importer)
            return .legacy
        }
        
        // Check if remote_asset_cloud_id_entity table exists (new schema)
        let cloudIdTableSql = "SELECT name FROM sqlite_master WHERE type='table' AND name='remote_asset_cloud_id_entity';"
        var hasCloudIdTable = false
        if sqlite3_prepare_v2(db, cloudIdTableSql, -1, &statement, nil) == SQLITE_OK {
            hasCloudIdTable = sqlite3_step(statement) == SQLITE_ROW
        }
        sqlite3_finalize(statement)
        
        if hasCloudIdTable {
            logDebug("Found remote_asset_cloud_id_entity table - using cloudId schema", category: .importer)
            return .cloudId
        }
        
        // Fallback to legacy if no cloud_id table found
        logDebug("No cloud_id table found, falling back to legacy schema", category: .importer)
        return .legacy
    }
    
    // MARK: - Legacy Schema Import
    
    /// Import from old Immich schema where local_asset_entity has checksum directly
    private func importLegacySchema(db: OpaquePointer?, progressCallback: ProgressCallback?) -> ImportResult {
        logDebug("Reading remote checksums from database (legacy schema)", category: .importer)
        var remoteChecksums: Set<String> = []
        let remoteSql = "SELECT checksum FROM remote_asset_entity WHERE checksum IS NOT NULL AND checksum != '';"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, remoteSql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let cString = sqlite3_column_text(statement, 0) {
                    remoteChecksums.insert(String(cString: cString))
                }
            }
        }
        sqlite3_finalize(statement)
        logDebug("Found \(remoteChecksums.count) remote checksums", category: .importer)
        
        let localSql = """
        SELECT id, name, type, checksum, width, height, duration_in_seconds, is_favorite
        FROM local_asset_entity
        WHERE checksum IS NOT NULL AND checksum != '';
        """
        
        guard sqlite3_prepare_v2(db, localSql, -1, &statement, nil) == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            return ImportResult(
                totalRecords: 0,
                importedRecords: 0,
                skippedRecords: 0,
                alreadyOnServer: 0,
                errorMessage: "SQL preparation failed: \(errorMsg)"
            )
        }
        
        defer {
            sqlite3_finalize(statement)
        }
        
        var hashDataList: [(localIdentifier: String, sha1Hash: String, checksumBase64: String, isOnServer: Bool)] = []
        var skippedCount = 0
        
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            let checksum: String? = {
                if let cString = sqlite3_column_text(statement, 3) {
                    return String(cString: cString)
                }
                return nil
            }()
            
            if let checksumStr = checksum, let sha1Hex = convertBase64ToHex(checksumStr) {
                let isOnServer = remoteChecksums.contains(checksumStr)
                hashDataList.append((localIdentifier: id, sha1Hash: sha1Hex, checksumBase64: checksumStr, isOnServer: isOnServer))
            } else {
                skippedCount += 1
            }
        }
        
        return performBatchImport(hashDataList: hashDataList, skippedCount: skippedCount, progressCallback: progressCallback)
    }
    
    // MARK: - CloudId Schema Import
    
    /// Import from new Immich schema where checksum is obtained via remote_asset_cloud_id_entity
    private func importCloudIdSchema(db: OpaquePointer?, progressCallback: ProgressCallback?) -> ImportResult {
        logDebug("Reading data from database (cloudId schema)", category: .importer)
        
        // Build a set of remote checksums for quick lookup
        var remoteChecksums: Set<String> = []
        let remoteSql = "SELECT checksum FROM remote_asset_entity WHERE checksum IS NOT NULL AND checksum != '';"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, remoteSql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let cString = sqlite3_column_text(statement, 0) {
                    remoteChecksums.insert(String(cString: cString))
                }
            }
        }
        sqlite3_finalize(statement)
        logDebug("Found \(remoteChecksums.count) remote checksums", category: .importer)
        
        // Query: join local_asset_entity with remote_asset_cloud_id_entity and remote_asset_entity
        // to get the checksum for each local asset
        let joinSql = """
        SELECT l.id, ra.checksum
        FROM local_asset_entity l
        JOIN remote_asset_cloud_id_entity rc ON l.i_cloud_id = rc.cloud_id
        JOIN remote_asset_entity ra ON rc.asset_id = ra.id
        WHERE ra.checksum IS NOT NULL AND ra.checksum != ''
          AND l.i_cloud_id IS NOT NULL AND l.i_cloud_id != '';
        """
        
        guard sqlite3_prepare_v2(db, joinSql, -1, &statement, nil) == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            logError("Failed to prepare cloudId join query: \(errorMsg)", category: .importer)
            return ImportResult(
                totalRecords: 0,
                importedRecords: 0,
                skippedRecords: 0,
                alreadyOnServer: 0,
                errorMessage: "SQL preparation failed: \(errorMsg)"
            )
        }
        
        var hashDataList: [(localIdentifier: String, sha1Hash: String, checksumBase64: String, isOnServer: Bool)] = []
        
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            if let checksumCString = sqlite3_column_text(statement, 1) {
                let checksumStr = String(cString: checksumCString)
                if let sha1Hex = convertBase64ToHex(checksumStr) {
                    let isOnServer = remoteChecksums.contains(checksumStr)
                    hashDataList.append((localIdentifier: id, sha1Hash: sha1Hex, checksumBase64: checksumStr, isOnServer: isOnServer))
                }
            }
        }
        sqlite3_finalize(statement)
        
        // Count local assets that have i_cloud_id but couldn't be matched (no remote record)
        let unmatchedSql = """
        SELECT COUNT(*) FROM local_asset_entity l
        WHERE l.i_cloud_id IS NOT NULL AND l.i_cloud_id != ''
          AND NOT EXISTS (SELECT 1 FROM remote_asset_cloud_id_entity rc WHERE rc.cloud_id = l.i_cloud_id);
        """
        var unmatchedCount = 0
        if sqlite3_prepare_v2(db, unmatchedSql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                unmatchedCount = Int(sqlite3_column_int(statement, 0))
            }
        }
        sqlite3_finalize(statement)
        
        // Count local assets without i_cloud_id at all
        let noCloudIdSql = "SELECT COUNT(*) FROM local_asset_entity WHERE i_cloud_id IS NULL OR i_cloud_id = '';"
        var noCloudIdCount = 0
        if sqlite3_prepare_v2(db, noCloudIdSql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                noCloudIdCount = Int(sqlite3_column_int(statement, 0))
            }
        }
        sqlite3_finalize(statement)
        
        let skippedCount = unmatchedCount + noCloudIdCount
        logDebug("CloudId schema: \(unmatchedCount) unmatched assets, \(noCloudIdCount) without cloud_id", category: .importer)
        
        return performBatchImport(hashDataList: hashDataList, skippedCount: skippedCount, progressCallback: progressCallback)
    }
    
    // MARK: - Shared Batch Import
    
    private func performBatchImport(
        hashDataList: [(localIdentifier: String, sha1Hash: String, checksumBase64: String, isOnServer: Bool)],
        skippedCount: Int,
        progressCallback: ProgressCallback?
    ) -> ImportResult {
        let totalCount = hashDataList.count
        let onServerCount = hashDataList.filter { $0.isOnServer }.count
        
        logInfo("Found \(totalCount) local assets (\(onServerCount) already on server, \(skippedCount) skipped)", category: .importer)
        
        DispatchQueue.main.async {
            progressCallback?(0, totalCount)
        }
        
        let batchSize = 500
        var importedCount = 0
        
        logDebug("Starting batch import with batch size \(batchSize)", category: .importer)
        
        for batchStart in stride(from: 0, to: totalCount, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, totalCount)
            let batch = Array(hashDataList[batchStart..<batchEnd])
            
            let batchItems = batch.map { item in
                (localIdentifier: item.localIdentifier,
                 sha1Hash: item.sha1Hash,
                 fileSize: Int64(0),
                 syncStatus: item.isOnServer ? "checked" : "pending")
            }
            DatabaseManager.shared.batchSaveHashCache(items: batchItems)
            
            let onServerItems = batch.filter { $0.isOnServer }
            if !onServerItems.isEmpty {
                let results = onServerItems.map { ($0.localIdentifier, true) }
                DatabaseManager.shared.batchUpdateHashCacheServerStatus(results: results)
            }
            
            importedCount += batch.count
            
            let currentProgress = importedCount
            DispatchQueue.main.async {
                progressCallback?(currentProgress, totalCount)
            }
            
            Thread.sleep(forTimeInterval: 0.01)
        }
        
        logInfo("Import completed: \(importedCount) records imported, \(onServerCount) already on server, \(skippedCount) skipped", category: .importer)
        
        return ImportResult(
            totalRecords: totalCount + skippedCount,
            importedRecords: importedCount,
            skippedRecords: skippedCount,
            alreadyOnServer: onServerCount,
            errorMessage: nil
        )
    }
    
    func convertBase64ToHex(_ base64String: String) -> String? {
        guard let data = Data(base64Encoded: base64String) else {
            return nil
        }
        
        return data.map { String(format: "%02x", $0) }.joined()
    }
    
    func validateFile(fileURL: URL) -> (isValid: Bool, recordCount: Int, errorMessage: String?) {
        guard let localURL = copyToTempDirectory(fileURL: fileURL) else {
            return (false, 0, "Unable to copy file to temp directory")
        }
        
        defer {
            cleanupTempFiles(baseURL: localURL)
        }
        
        var db: OpaquePointer?
        
        let flags = SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(localURL.path, &db, flags, nil) == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            return (false, 0, "Unable to open database: \(errorMsg)")
        }
        
        defer {
            sqlite3_close(db)
        }
        
        let checkTableSql = """
        SELECT name FROM sqlite_master
        WHERE type='table' AND name='local_asset_entity';
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, checkTableSql, -1, &statement, nil) == SQLITE_OK else {
            return (false, 0, "Unable to query tables")
        }
        
        let hasTable = sqlite3_step(statement) == SQLITE_ROW
        sqlite3_finalize(statement)
        
        guard hasTable else {
            return (false, 0, "local_asset_entity table not found, this may not be an Immich iOS App database")
        }
        
        let schemaVersion = detectSchemaVersion(db: db)
        
        switch schemaVersion {
        case .legacy:
            let countSql = "SELECT COUNT(*) FROM local_asset_entity WHERE checksum IS NOT NULL AND checksum != '';"
            guard sqlite3_prepare_v2(db, countSql, -1, &statement, nil) == SQLITE_OK else {
                return (false, 0, "Unable to count records")
            }
            
            var count = 0
            if sqlite3_step(statement) == SQLITE_ROW {
                count = Int(sqlite3_column_int(statement, 0))
            }
            sqlite3_finalize(statement)
            
            return (true, count, nil)
            
        case .cloudId:
            // Count local assets that can be matched to remote checksums via cloud_id
            let countSql = """
            SELECT COUNT(*)
            FROM local_asset_entity l
            JOIN remote_asset_cloud_id_entity rc ON l.i_cloud_id = rc.cloud_id
            JOIN remote_asset_entity ra ON rc.asset_id = ra.id
            WHERE ra.checksum IS NOT NULL AND ra.checksum != ''
              AND l.i_cloud_id IS NOT NULL AND l.i_cloud_id != '';
            """
            guard sqlite3_prepare_v2(db, countSql, -1, &statement, nil) == SQLITE_OK else {
                return (false, 0, "Unable to count records")
            }
            
            var count = 0
            if sqlite3_step(statement) == SQLITE_ROW {
                count = Int(sqlite3_column_int(statement, 0))
            }
            sqlite3_finalize(statement)
            
            return (true, count, nil)
        }
    }
    
    func getStatistics(fileURL: URL) -> [String: Any]? {
        guard let localURL = copyToTempDirectory(fileURL: fileURL) else {
            return nil
        }
        
        defer {
            cleanupTempFiles(baseURL: localURL)
        }
        
        var db: OpaquePointer?
        
        let flags = SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(localURL.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        
        defer {
            sqlite3_close(db)
        }
        
        let schemaVersion = detectSchemaVersion(db: db)
        
        var stats: [String: Any] = [:]
        var statement: OpaquePointer?
        
        let totalSql = "SELECT COUNT(*) FROM local_asset_entity;"
        if sqlite3_prepare_v2(db, totalSql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                stats["totalAssets"] = Int(sqlite3_column_int(statement, 0))
            }
        }
        sqlite3_finalize(statement)
        
        switch schemaVersion {
        case .legacy:
            let checksumSql = "SELECT COUNT(*) FROM local_asset_entity WHERE checksum IS NOT NULL AND checksum != '';"
            if sqlite3_prepare_v2(db, checksumSql, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    stats["assetsWithChecksum"] = Int(sqlite3_column_int(statement, 0))
                }
            }
            sqlite3_finalize(statement)
            
        case .cloudId:
            // For new schema, count assets that have matching remote checksums via cloud_id join
            let checksumSql = """
            SELECT COUNT(*)
            FROM local_asset_entity l
            JOIN remote_asset_cloud_id_entity rc ON l.i_cloud_id = rc.cloud_id
            JOIN remote_asset_entity ra ON rc.asset_id = ra.id
            WHERE ra.checksum IS NOT NULL AND ra.checksum != ''
              AND l.i_cloud_id IS NOT NULL AND l.i_cloud_id != '';
            """
            if sqlite3_prepare_v2(db, checksumSql, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    stats["assetsWithChecksum"] = Int(sqlite3_column_int(statement, 0))
                }
            }
            sqlite3_finalize(statement)
        }
        
        let imageSql = "SELECT COUNT(*) FROM local_asset_entity WHERE type = 1;"
        if sqlite3_prepare_v2(db, imageSql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                stats["imageCount"] = Int(sqlite3_column_int(statement, 0))
            }
        }
        sqlite3_finalize(statement)
        
        let videoSql = "SELECT COUNT(*) FROM local_asset_entity WHERE type = 2;"
        if sqlite3_prepare_v2(db, videoSql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                stats["videoCount"] = Int(sqlite3_column_int(statement, 0))
            }
        }
        sqlite3_finalize(statement)
        
        let remoteSql = "SELECT COUNT(*) FROM remote_asset_entity;"
        if sqlite3_prepare_v2(db, remoteSql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                stats["remoteAssets"] = Int(sqlite3_column_int(statement, 0))
            }
        }
        sqlite3_finalize(statement)
        
        switch schemaVersion {
        case .legacy:
            let matchedSql = """
            SELECT COUNT(*) FROM local_asset_entity l
            INNER JOIN remote_asset_entity r ON l.checksum = r.checksum
            WHERE l.checksum IS NOT NULL AND l.checksum != '';
            """
            if sqlite3_prepare_v2(db, matchedSql, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    stats["assetsOnServer"] = Int(sqlite3_column_int(statement, 0))
                }
            }
            sqlite3_finalize(statement)
            
        case .cloudId:
            // For new schema, assets on server = those matched via cloud_id that exist in remote_asset_entity
            let matchedSql = """
            SELECT COUNT(*)
            FROM local_asset_entity l
            JOIN remote_asset_cloud_id_entity rc ON l.i_cloud_id = rc.cloud_id
            JOIN remote_asset_entity ra ON rc.asset_id = ra.id
            WHERE ra.checksum IS NOT NULL AND ra.checksum != ''
              AND l.i_cloud_id IS NOT NULL AND l.i_cloud_id != '';
            """
            if sqlite3_prepare_v2(db, matchedSql, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    stats["assetsOnServer"] = Int(sqlite3_column_int(statement, 0))
                }
            }
            sqlite3_finalize(statement)
        }
        
        return stats
    }
    
    // MARK: - Private Helpers
    
    private func copyToTempDirectory(fileURL: URL) -> URL? {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let uuid = UUID().uuidString
        let tempFileName = "immich_import_\(uuid).sqlite"
        let tempURL = tempDir.appendingPathComponent(tempFileName)
        
        do {
            cleanupTempFiles(baseURL: tempURL)
            
            try fileManager.copyItem(at: fileURL, to: tempURL)
            
            let walURL = fileURL.deletingPathExtension().appendingPathExtension("sqlite-wal")
            let tempWalURL = tempURL.deletingPathExtension().appendingPathExtension("sqlite-wal")
            if fileManager.fileExists(atPath: walURL.path) {
                try? fileManager.copyItem(at: walURL, to: tempWalURL)
            }
            
            let shmURL = fileURL.deletingPathExtension().appendingPathExtension("sqlite-shm")
            let tempShmURL = tempURL.deletingPathExtension().appendingPathExtension("sqlite-shm")
            if fileManager.fileExists(atPath: shmURL.path) {
                try? fileManager.copyItem(at: shmURL, to: tempShmURL)
            }
            
            checkpointWAL(dbPath: tempURL.path)
            
            return tempURL
        } catch {
            return nil
        }
    }
    
    private func cleanupTempFiles(baseURL: URL) {
        let fileManager = FileManager.default
        
        try? fileManager.removeItem(at: baseURL)
        
        let walURL = baseURL.deletingPathExtension().appendingPathExtension("sqlite-wal")
        try? fileManager.removeItem(at: walURL)
        
        let shmURL = baseURL.deletingPathExtension().appendingPathExtension("sqlite-shm")
        try? fileManager.removeItem(at: shmURL)
    }
    
    private func checkpointWAL(dbPath: String) {
        var db: OpaquePointer?
        
        let flags = SQLITE_OPEN_READWRITE
        if sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK {
            sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
            sqlite3_exec(db, "PRAGMA journal_mode=DELETE;", nil, nil, nil)
        }
        
        sqlite3_close(db)
    }
}
