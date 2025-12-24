import Foundation
import SQLite3

class DatabaseManager {
    static let shared = DatabaseManager()
    
    private var db: OpaquePointer?
    private let dbName = "immich_uploader.sqlite"
    
    private let dbQueue = DispatchQueue(label: "com.immich_uploader.database", qos: .userInitiated)
    
    private var isInitialized = false
    private let initLock = NSLock()
    
    private init() {
        dbQueue.async { [weak self] in
            self?.openDatabase()
            self?.createTables()
            self?.initLock.lock()
            self?.isInitialized = true
            self?.initLock.unlock()
            logInfo("DatabaseManager initialized", category: .database)
        }
    }
    
    private func ensureInitialized() {
        initLock.lock()
        let initialized = isInitialized
        initLock.unlock()
        
        if !initialized {
            dbQueue.sync { }
        }
    }
    
    deinit {
        sqlite3_close(db)
    }
    
    // MARK: - Database Setup
    
    private func openDatabase() {
        let fileURL = getDocumentsDirectory().appendingPathComponent(dbName)
        logDebug("Opening database at: \(fileURL.path)", category: .database)
        
        if sqlite3_open(fileURL.path, &db) != SQLITE_OK {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            logError("Failed to open database: \(errorMsg)", category: .database)
        } else {
            logDebug("Database opened successfully", category: .database)
        }
    }
    
    private func createTables() {
        let createUploadedAssetsTable = """
        CREATE TABLE IF NOT EXISTS uploaded_assets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            local_identifier TEXT NOT NULL,
            resource_type TEXT NOT NULL,
            filename TEXT NOT NULL,
            immich_id TEXT,
            uploaded_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            file_size INTEGER,
            is_duplicate INTEGER DEFAULT 0,
            UNIQUE(local_identifier, resource_type)
        );
        """
        
        let createUploadQueueTable = """
        CREATE TABLE IF NOT EXISTS upload_queue (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            local_identifier TEXT NOT NULL,
            resource_type TEXT NOT NULL,
            filename TEXT NOT NULL,
            status TEXT DEFAULT 'pending',
            error_message TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(local_identifier, resource_type)
        );
        """
        
        let createHashCacheTable = """
        CREATE TABLE IF NOT EXISTS hash_cache (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            local_identifier TEXT NOT NULL UNIQUE,
            sha1_hash TEXT NOT NULL,
            file_size INTEGER,
            sync_status TEXT DEFAULT 'pending',
            is_on_server INTEGER DEFAULT 0,
            calculated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            checked_at DATETIME
        );
        """
        
        let createIndex1 = "CREATE INDEX IF NOT EXISTS idx_uploaded_assets_local_id ON uploaded_assets(local_identifier);"
        let createIndex2 = "CREATE INDEX IF NOT EXISTS idx_upload_queue_status ON upload_queue(status);"
        let createIndex3 = "CREATE INDEX IF NOT EXISTS idx_hash_cache_local_id ON hash_cache(local_identifier);"
        let createIndex4 = "CREATE INDEX IF NOT EXISTS idx_hash_cache_sha1 ON hash_cache(sha1_hash);"
        let createIndex5 = "CREATE INDEX IF NOT EXISTS idx_hash_cache_status ON hash_cache(sync_status);"
        
        executeStatement(createUploadedAssetsTable)
        executeStatement(createUploadQueueTable)
        executeStatement(createHashCacheTable)
        executeStatement(createIndex1)
        executeStatement(createIndex2)
        executeStatement(createIndex3)
        executeStatement(createIndex4)
        executeStatement(createIndex5)
    }
    
    private func executeStatement(_ sql: String) {
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_step(statement)
        }
        
        sqlite3_finalize(statement)
    }
    
    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    // MARK: - Upload Record Management
    
    func isAssetUploaded(localIdentifier: String, resourceType: String = "primary") -> Bool {
        let sql = "SELECT COUNT(*) FROM uploaded_assets WHERE local_identifier = ? AND resource_type = ?;"
        var statement: OpaquePointer?
        var isUploaded = false
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, localIdentifier, -1, nil)
            sqlite3_bind_text(statement, 2, resourceType, -1, nil)
            
            if sqlite3_step(statement) == SQLITE_ROW {
                let count = sqlite3_column_int(statement, 0)
                isUploaded = count > 0
            }
        }
        
        sqlite3_finalize(statement)
        return isUploaded
    }
    
    func isAnyResourceUploaded(localIdentifier: String) -> Bool {
        let sql = "SELECT COUNT(*) FROM uploaded_assets WHERE local_identifier = ?;"
        var statement: OpaquePointer?
        var isUploaded = false
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, localIdentifier, -1, nil)
            
            if sqlite3_step(statement) == SQLITE_ROW {
                let count = sqlite3_column_int(statement, 0)
                isUploaded = count > 0
            }
        }
        
        sqlite3_finalize(statement)
        return isUploaded
    }
    
    func recordUploadedAsset(
        localIdentifier: String,
        resourceType: String,
        filename: String,
        immichId: String,
        fileSize: Int64 = 0,
        isDuplicate: Bool = false
    ) {
        logDebug("Recording uploaded asset: \(filename) (type: \(resourceType), immichId: \(immichId))", category: .database)
        
        let sql = """
        INSERT OR REPLACE INTO uploaded_assets
        (local_identifier, resource_type, filename, immich_id, file_size, is_duplicate, uploaded_at)
        VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP);
        """
        
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (localIdentifier as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (resourceType as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (filename as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 4, (immichId as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(statement, 5, fileSize)
            sqlite3_bind_int(statement, 6, isDuplicate ? 1 : 0)
            
            if sqlite3_step(statement) != SQLITE_DONE {
                let errorMsg = String(cString: sqlite3_errmsg(db))
                logError("Failed to record uploaded asset: \(errorMsg)", category: .database)
            }
        } else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            logError("Failed to prepare statement for recordUploadedAsset: \(errorMsg)", category: .database)
        }
        
        sqlite3_finalize(statement)
    }
    
    func getUploadedCount() -> Int {
        ensureInitialized()
        let sql = "SELECT COUNT(DISTINCT local_identifier) FROM uploaded_assets;"
        var statement: OpaquePointer?
        var count = 0
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                count = Int(sqlite3_column_int(statement, 0))
            }
        }
        
        sqlite3_finalize(statement)
        return count
    }
    
    func getUploadedCountAsync(completion: @escaping (Int) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(0) }
                return
            }
            self.ensureInitialized()
            let count = self.getUploadedCountInternal()
            DispatchQueue.main.async {
                completion(count)
            }
        }
    }
    
    private func getUploadedCountInternal() -> Int {
        let sql = "SELECT COUNT(DISTINCT local_identifier) FROM uploaded_assets;"
        var statement: OpaquePointer?
        var count = 0
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                count = Int(sqlite3_column_int(statement, 0))
            }
        }
        
        sqlite3_finalize(statement)
        return count
    }
    
    func getAllUploadedAssetIds() -> Set<String> {
        ensureInitialized()
        return getAllUploadedAssetIdsInternal()
    }
    
    func getAllUploadedAssetIdsAsync(completion: @escaping (Set<String>) -> Void) {
        dbQueue.async { [weak self] in
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
        let sql = "SELECT DISTINCT local_identifier FROM uploaded_assets WHERE local_identifier != '' AND local_identifier IS NOT NULL;"
        var statement: OpaquePointer?
        var ids: Set<String> = []
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
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
    
    func getUploadedResourceCount() -> Int {
        let sql = "SELECT COUNT(*) FROM uploaded_assets;"
        var statement: OpaquePointer?
        var count = 0
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                count = Int(sqlite3_column_int(statement, 0))
            }
        }
        
        sqlite3_finalize(statement)
        return count
    }
    
    func getUploadRecords(for localIdentifier: String) -> [UploadRecord] {
        let sql = "SELECT * FROM uploaded_assets WHERE local_identifier = ?;"
        var statement: OpaquePointer?
        var records: [UploadRecord] = []
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, localIdentifier, -1, nil)
            
            while sqlite3_step(statement) == SQLITE_ROW {
                let record = UploadRecord(
                    id: Int(sqlite3_column_int(statement, 0)),
                    localIdentifier: String(cString: sqlite3_column_text(statement, 1)),
                    resourceType: String(cString: sqlite3_column_text(statement, 2)),
                    filename: String(cString: sqlite3_column_text(statement, 3)),
                    immichId: sqlite3_column_text(statement, 4).map { String(cString: $0) },
                    uploadedAt: sqlite3_column_text(statement, 5).map { String(cString: $0) },
                    fileSize: sqlite3_column_int64(statement, 6),
                    isDuplicate: sqlite3_column_int(statement, 7) == 1
                )
                records.append(record)
            }
        }
        
        sqlite3_finalize(statement)
        return records
    }
    
    func deleteUploadRecord(for localIdentifier: String) {
        let sql = "DELETE FROM uploaded_assets WHERE local_identifier = ?;"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, localIdentifier, -1, nil)
            sqlite3_step(statement)
        }
        
        sqlite3_finalize(statement)
    }
    
    func clearAllUploadRecords() {
        executeStatement("DELETE FROM uploaded_assets;")
        executeStatement("DELETE FROM upload_queue;")
    }
    
    // MARK: - Upload Queue Management
    
    func addToUploadQueue(localIdentifier: String, resourceType: String, filename: String) {
        let sql = """
        INSERT OR IGNORE INTO upload_queue 
        (local_identifier, resource_type, filename, status)
        VALUES (?, ?, ?, 'pending');
        """
        
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, localIdentifier, -1, nil)
            sqlite3_bind_text(statement, 2, resourceType, -1, nil)
            sqlite3_bind_text(statement, 3, filename, -1, nil)
            
            sqlite3_step(statement)
        }
        
        sqlite3_finalize(statement)
    }
    
    func updateQueueStatus(localIdentifier: String, resourceType: String, status: String, errorMessage: String? = nil) {
        let sql = """
        UPDATE upload_queue 
        SET status = ?, error_message = ?, updated_at = CURRENT_TIMESTAMP
        WHERE local_identifier = ? AND resource_type = ?;
        """
        
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, status, -1, nil)
            if let error = errorMessage {
                sqlite3_bind_text(statement, 2, error, -1, nil)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            sqlite3_bind_text(statement, 3, localIdentifier, -1, nil)
            sqlite3_bind_text(statement, 4, resourceType, -1, nil)
            
            sqlite3_step(statement)
        }
        
        sqlite3_finalize(statement)
    }
    
    func removeFromQueue(localIdentifier: String, resourceType: String) {
        let sql = "DELETE FROM upload_queue WHERE local_identifier = ? AND resource_type = ?;"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, localIdentifier, -1, nil)
            sqlite3_bind_text(statement, 2, resourceType, -1, nil)
            
            sqlite3_step(statement)
        }
        
        sqlite3_finalize(statement)
    }
    
    func getPendingCount() -> Int {
        let sql = "SELECT COUNT(*) FROM upload_queue WHERE status = 'pending';"
        var statement: OpaquePointer?
        var count = 0
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                count = Int(sqlite3_column_int(statement, 0))
            }
        }
        
        sqlite3_finalize(statement)
        return count
    }
    
    // MARK: - Hash Cache Management
    
    func saveHashCache(localIdentifier: String, sha1Hash: String, fileSize: Int64, syncStatus: String = "pending") {
        dbQueue.sync { [weak self] in
            guard let self = self else { return }
            self.saveHashCacheInternal(localIdentifier: localIdentifier, sha1Hash: sha1Hash, fileSize: fileSize, syncStatus: syncStatus)
        }
    }
    
    private func saveHashCacheInternal(localIdentifier: String, sha1Hash: String, fileSize: Int64, syncStatus: String) {
        let sql = """
        INSERT OR REPLACE INTO hash_cache
        (local_identifier, sha1_hash, file_size, sync_status, calculated_at)
        VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP);
        """
        
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (localIdentifier as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (sha1Hash as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(statement, 3, fileSize)
            sqlite3_bind_text(statement, 4, (syncStatus as NSString).utf8String, -1, nil)
            
            sqlite3_step(statement)
        }
        
        sqlite3_finalize(statement)
    }
    
    func batchSaveHashCache(items: [(localIdentifier: String, sha1Hash: String, fileSize: Int64, syncStatus: String)]) {
        dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            sqlite3_exec(self.db, "BEGIN TRANSACTION;", nil, nil, nil)
            
            for item in items {
                self.saveHashCacheInternal(
                    localIdentifier: item.localIdentifier,
                    sha1Hash: item.sha1Hash,
                    fileSize: item.fileSize,
                    syncStatus: item.syncStatus
                )
            }
            
            sqlite3_exec(self.db, "COMMIT;", nil, nil, nil)
        }
    }
    
    func getHashCache(localIdentifier: String) -> HashCacheRecord? {
        let sql = "SELECT * FROM hash_cache WHERE local_identifier = ?;"
        var statement: OpaquePointer?
        var record: HashCacheRecord?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (localIdentifier as NSString).utf8String, -1, nil)
            
            if sqlite3_step(statement) == SQLITE_ROW {
                record = HashCacheRecord(
                    id: Int(sqlite3_column_int(statement, 0)),
                    localIdentifier: String(cString: sqlite3_column_text(statement, 1)),
                    sha1Hash: String(cString: sqlite3_column_text(statement, 2)),
                    fileSize: sqlite3_column_int64(statement, 3),
                    syncStatus: String(cString: sqlite3_column_text(statement, 4)),
                    isOnServer: sqlite3_column_int(statement, 5) == 1,
                    calculatedAt: sqlite3_column_text(statement, 6).map { String(cString: $0) },
                    checkedAt: sqlite3_column_text(statement, 7).map { String(cString: $0) }
                )
            }
        }
        
        sqlite3_finalize(statement)
        return record
    }
    
    func updateHashCacheServerStatus(localIdentifier: String, isOnServer: Bool, syncStatus: String = "checked") {
        let sql = """
        UPDATE hash_cache
        SET is_on_server = ?, sync_status = ?, checked_at = CURRENT_TIMESTAMP
        WHERE local_identifier = ?;
        """
        
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, isOnServer ? 1 : 0)
            sqlite3_bind_text(statement, 2, (syncStatus as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (localIdentifier as NSString).utf8String, -1, nil)
            
            sqlite3_step(statement)
        }
        
        sqlite3_finalize(statement)
    }
    
    func batchUpdateHashCacheServerStatus(results: [(String, Bool)]) {
        dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            sqlite3_exec(self.db, "BEGIN TRANSACTION;", nil, nil, nil)
            
            for (localIdentifier, isOnServer) in results {
                self.updateHashCacheServerStatusInternal(localIdentifier: localIdentifier, isOnServer: isOnServer)
            }
            
            sqlite3_exec(self.db, "COMMIT;", nil, nil, nil)
        }
    }
    
    private func updateHashCacheServerStatusInternal(localIdentifier: String, isOnServer: Bool, syncStatus: String = "checked") {
        let sql = """
        UPDATE hash_cache
        SET is_on_server = ?, sync_status = ?, checked_at = CURRENT_TIMESTAMP
        WHERE local_identifier = ?;
        """
        
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, isOnServer ? 1 : 0)
            sqlite3_bind_text(statement, 2, (syncStatus as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (localIdentifier as NSString).utf8String, -1, nil)
            
            sqlite3_step(statement)
        }
        
        sqlite3_finalize(statement)
    }
    
    func getAssetsOnServerAsync(completion: @escaping (Set<String>) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            
            let sql = "SELECT local_identifier FROM hash_cache WHERE is_on_server = 1;"
            var statement: OpaquePointer?
            var ids: Set<String> = []
            
            if sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK {
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
    
    func getAllSyncStatusAsync(completion: @escaping ([String: PhotoSyncStatus]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([:]) }
                return
            }
            
            var statusMap: [String: PhotoSyncStatus] = [:]
            
            let hashSql = "SELECT local_identifier, sync_status, is_on_server FROM hash_cache;"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.db, hashSql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let cString = sqlite3_column_text(statement, 0) {
                        let identifier = String(cString: cString)
                        let syncStatus = String(cString: sqlite3_column_text(statement, 1))
                        let isOnServer = sqlite3_column_int(statement, 2) == 1
                        
                        if isOnServer {
                            statusMap[identifier] = .uploaded
                        } else if syncStatus == "checked" {
                            statusMap[identifier] = .notUploaded
                        } else if syncStatus == "checking" {
                            statusMap[identifier] = .checking
                        } else if syncStatus == "processing" {
                            statusMap[identifier] = .processing
                        } else {
                            statusMap[identifier] = .pending
                        }
                    }
                }
            }
            sqlite3_finalize(statement)
            
            let uploadedSql = "SELECT DISTINCT local_identifier FROM uploaded_assets;"
            if sqlite3_prepare_v2(self.db, uploadedSql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let cString = sqlite3_column_text(statement, 0) {
                        let identifier = String(cString: cString)
                        if !identifier.isEmpty {
                            statusMap[identifier] = .uploaded
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
        dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            
            let sql = "SELECT local_identifier FROM hash_cache;"
            var statement: OpaquePointer?
            var existingIds: Set<String> = []
            
            if sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK {
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
        dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            
            let sql = "SELECT local_identifier, sha1_hash FROM hash_cache WHERE sync_status = 'pending' OR sync_status = 'processing';"
            var statement: OpaquePointer?
            var hashes: [(String, String)] = []
            
            if sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK {
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
    
    func getHashCacheStatsAsync(completion: @escaping (Int, Int, Int) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(0, 0, 0) }
                return
            }
            
            var total = 0
            var checked = 0
            var onServer = 0
            var statement: OpaquePointer?
            
            let totalSql = "SELECT COUNT(*) FROM hash_cache;"
            if sqlite3_prepare_v2(self.db, totalSql, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    total = Int(sqlite3_column_int(statement, 0))
                }
            }
            sqlite3_finalize(statement)
            
            let checkedSql = "SELECT COUNT(*) FROM hash_cache WHERE sync_status = 'checked';"
            if sqlite3_prepare_v2(self.db, checkedSql, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    checked = Int(sqlite3_column_int(statement, 0))
                }
            }
            sqlite3_finalize(statement)
            
            let onServerSql = "SELECT COUNT(*) FROM hash_cache WHERE is_on_server = 1;"
            if sqlite3_prepare_v2(self.db, onServerSql, -1, &statement, nil) == SQLITE_OK {
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
    
    func clearHashCache() {
        executeStatement("DELETE FROM hash_cache;")
    }
}

// MARK: - Data Models

struct UploadRecord {
    let id: Int
    let localIdentifier: String
    let resourceType: String
    let filename: String
    let immichId: String?
    let uploadedAt: String?
    let fileSize: Int64
    let isDuplicate: Bool
}

struct HashCacheRecord {
    let id: Int
    let localIdentifier: String
    let sha1Hash: String
    let fileSize: Int64
    let syncStatus: String
    let isOnServer: Bool
    let calculatedAt: String?
    let checkedAt: String?
}
