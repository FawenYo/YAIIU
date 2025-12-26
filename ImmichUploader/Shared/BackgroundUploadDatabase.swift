import Foundation
import SQLite3

/// BackgroundUploadDatabase - SQLite database in App Group for tracking background upload status
/// This database is shared between the main app and the extension
class BackgroundUploadDatabase {
    static let shared = BackgroundUploadDatabase()
    
    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.immich.uploader.bgdb", qos: .utility)
    
    private init() {
        openDatabase()
        createTables()
    }
    
    deinit {
        closeDatabase()
    }
    
    // MARK: - Database Setup
    
    private func openDatabase() {
        let appGroupIdentifier = "group.com.immich.uploader"
        
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            print("[BackgroundUploadDatabase] Failed to get app group container URL")
            return
        }
        
        let dbURL = containerURL.appendingPathComponent("background_uploads.sqlite")
        
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            print("[BackgroundUploadDatabase] Failed to open database at: \(dbURL.path)")
            db = nil
        } else {
            print("[BackgroundUploadDatabase] Database opened at: \(dbURL.path)")
            
            // Enable WAL mode to support multi-process access
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL;", -1, &statement, nil) == SQLITE_OK {
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }
    
    private func closeDatabase() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }
    
    private func createTables() {
        guard db != nil else { return }
        
        // Upload jobs table - track each resource that needs to be uploaded
        let createUploadJobsTable = """
            CREATE TABLE IF NOT EXISTS upload_jobs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                asset_local_identifier TEXT NOT NULL,
                resource_type TEXT NOT NULL,
                filename TEXT NOT NULL,
                status TEXT DEFAULT 'pending',
                immich_id TEXT,
                error_message TEXT,
                retry_count INTEGER DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                UNIQUE(asset_local_identifier, resource_type)
            );
        """
        
        // Uploaded assets table - record successfully uploaded resources
        let createUploadedAssetsTable = """
            CREATE TABLE IF NOT EXISTS uploaded_assets (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                asset_local_identifier TEXT NOT NULL,
                resource_type TEXT NOT NULL,
                filename TEXT NOT NULL,
                immich_id TEXT NOT NULL,
                file_size INTEGER,
                is_duplicate INTEGER DEFAULT 0,
                uploaded_at REAL NOT NULL,
                UNIQUE(asset_local_identifier, resource_type)
            );
        """
        
        // Assets on server table - track assets that are already on the Immich server
        // This table is synced from the main app's hash_cache when importing SQLite
        let createAssetsOnServerTable = """
            CREATE TABLE IF NOT EXISTS assets_on_server (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                asset_local_identifier TEXT NOT NULL UNIQUE,
                sha1_hash TEXT,
                synced_at REAL NOT NULL
            );
        """
        
        // Hash cache table - cache SHA1 hashes for assets to avoid recalculation
        let createHashCacheTable = """
            CREATE TABLE IF NOT EXISTS hash_cache (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                asset_local_identifier TEXT NOT NULL UNIQUE,
                sha1_hash TEXT NOT NULL,
                calculated_at REAL NOT NULL
            );
        """
        
        // Hash checked table - track assets that have been checked against the server
        let createHashCheckedTable = """
            CREATE TABLE IF NOT EXISTS hash_checked (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                asset_local_identifier TEXT NOT NULL UNIQUE,
                sha1_hash TEXT NOT NULL,
                is_on_server INTEGER NOT NULL DEFAULT 0,
                checked_at REAL NOT NULL
            );
        """
        
        // Change token table - track photo library changes
        let createChangeTokenTable = """
            CREATE TABLE IF NOT EXISTS change_tokens (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                token_data BLOB,
                updated_at REAL NOT NULL
            );
        """
        
        // Create indexes
        let createIndexes = """
            CREATE INDEX IF NOT EXISTS idx_upload_jobs_status ON upload_jobs(status);
            CREATE INDEX IF NOT EXISTS idx_upload_jobs_asset ON upload_jobs(asset_local_identifier);
            CREATE INDEX IF NOT EXISTS idx_uploaded_assets_asset ON uploaded_assets(asset_local_identifier);
            CREATE INDEX IF NOT EXISTS idx_assets_on_server_asset ON assets_on_server(asset_local_identifier);
            CREATE INDEX IF NOT EXISTS idx_hash_cache_asset ON hash_cache(asset_local_identifier);
            CREATE INDEX IF NOT EXISTS idx_hash_checked_asset ON hash_checked(asset_local_identifier);
            CREATE INDEX IF NOT EXISTS idx_hash_checked_on_server ON hash_checked(is_on_server);
        """
        
        executeSQL(createUploadJobsTable)
        executeSQL(createUploadedAssetsTable)
        executeSQL(createAssetsOnServerTable)
        executeSQL(createHashCacheTable)
        executeSQL(createHashCheckedTable)
        executeSQL(createChangeTokenTable)
        executeSQL(createIndexes)
    }
    
    private func executeSQL(_ sql: String) {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) != SQLITE_DONE {
                let errorMessage = String(cString: sqlite3_errmsg(db))
                print("[BackgroundUploadDatabase] SQL execution failed: \(errorMessage)")
            }
        }
        sqlite3_finalize(statement)
    }
    
    // MARK: - Upload Job Management
    
    /// Create or update an upload job
    func createOrUpdateUploadJob(
        assetLocalIdentifier: String,
        resourceType: String,
        filename: String,
        status: UploadJobStatus = .pending
    ) {
        dbQueue.sync {
            let sql = """
                INSERT INTO upload_jobs (asset_local_identifier, resource_type, filename, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(asset_local_identifier, resource_type) 
                DO UPDATE SET status = ?, updated_at = ?
                WHERE status != 'completed';
            """
            
            var statement: OpaquePointer?
            let now = Date().timeIntervalSince1970
            
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, assetLocalIdentifier, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 2, resourceType, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 3, filename, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 4, status.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(statement, 5, now)
                sqlite3_bind_double(statement, 6, now)
                sqlite3_bind_text(statement, 7, status.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(statement, 8, now)
                
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }
    
    /// Get pending jobs
    func getPendingJobs(limit: Int = 100) -> [UploadJobInfo] {
        var jobs: [UploadJobInfo] = []
        
        dbQueue.sync {
            let sql = """
                SELECT id, asset_local_identifier, resource_type, filename, retry_count
                FROM upload_jobs
                WHERE status = 'pending' OR status = 'failed'
                ORDER BY created_at ASC
                LIMIT ?;
            """
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, Int32(limit))
                
                while sqlite3_step(statement) == SQLITE_ROW {
                    let job = UploadJobInfo(
                        id: Int(sqlite3_column_int64(statement, 0)),
                        assetLocalIdentifier: String(cString: sqlite3_column_text(statement, 1)),
                        resourceType: String(cString: sqlite3_column_text(statement, 2)),
                        filename: String(cString: sqlite3_column_text(statement, 3)),
                        retryCount: Int(sqlite3_column_int(statement, 4))
                    )
                    jobs.append(job)
                }
            }
            sqlite3_finalize(statement)
        }
        
        return jobs
    }
    
    /// Update job status
    func updateJobStatus(
        jobId: Int,
        status: UploadJobStatus,
        immichId: String? = nil,
        errorMessage: String? = nil
    ) {
        dbQueue.sync {
            var sql = "UPDATE upload_jobs SET status = ?, updated_at = ?"
            
            if immichId != nil {
                sql += ", immich_id = ?"
            }
            if errorMessage != nil {
                sql += ", error_message = ?"
            }
            if status == .failed {
                sql += ", retry_count = retry_count + 1"
            }
            
            sql += " WHERE id = ?;"
            
            var statement: OpaquePointer?
            let now = Date().timeIntervalSince1970
            
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                var bindIndex: Int32 = 1
                sqlite3_bind_text(statement, bindIndex, status.rawValue, -1, SQLITE_TRANSIENT)
                bindIndex += 1
                sqlite3_bind_double(statement, bindIndex, now)
                bindIndex += 1
                
                if let immichId = immichId {
                    sqlite3_bind_text(statement, bindIndex, immichId, -1, SQLITE_TRANSIENT)
                    bindIndex += 1
                }
                if let errorMessage = errorMessage {
                    sqlite3_bind_text(statement, bindIndex, errorMessage, -1, SQLITE_TRANSIENT)
                    bindIndex += 1
                }
                
                sqlite3_bind_int(statement, bindIndex, Int32(jobId))
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }
    
    /// Delete completed jobs
    func deleteCompletedJobs() {
        dbQueue.sync {
            let sql = "DELETE FROM upload_jobs WHERE status = 'completed';"
            executeSQL(sql)
        }
    }
    
    // MARK: - Uploaded Assets Management
    
    /// Record an uploaded asset
    func recordUploadedAsset(
        assetLocalIdentifier: String,
        resourceType: String,
        filename: String,
        immichId: String,
        fileSize: Int64,
        isDuplicate: Bool
    ) {
        dbQueue.sync {
            let sql = """
                INSERT OR REPLACE INTO uploaded_assets 
                (asset_local_identifier, resource_type, filename, immich_id, file_size, is_duplicate, uploaded_at)
                VALUES (?, ?, ?, ?, ?, ?, ?);
            """
            
            var statement: OpaquePointer?
            let now = Date().timeIntervalSince1970
            
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, assetLocalIdentifier, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 2, resourceType, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 3, filename, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 4, immichId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(statement, 5, fileSize)
                sqlite3_bind_int(statement, 6, isDuplicate ? 1 : 0)
                sqlite3_bind_double(statement, 7, now)
                
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }
    
    /// Check if a resource has been uploaded
    func isResourceUploaded(assetLocalIdentifier: String, resourceType: String) -> Bool {
        var isUploaded = false
        
        dbQueue.sync {
            let sql = """
                SELECT COUNT(*) FROM uploaded_assets 
                WHERE asset_local_identifier = ? AND resource_type = ?;
            """
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, assetLocalIdentifier, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 2, resourceType, -1, SQLITE_TRANSIENT)
                
                if sqlite3_step(statement) == SQLITE_ROW {
                    isUploaded = sqlite3_column_int(statement, 0) > 0
                }
            }
            sqlite3_finalize(statement)
        }
        
        return isUploaded
    }
    
    /// Check if any resource type has been uploaded for this asset
    func isAnyResourceUploaded(assetLocalIdentifier: String) -> Bool {
        var isUploaded = false
        
        dbQueue.sync {
            let sql = """
                SELECT COUNT(*) FROM uploaded_assets 
                WHERE asset_local_identifier = ?;
            """
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, assetLocalIdentifier, -1, SQLITE_TRANSIENT)
                
                if sqlite3_step(statement) == SQLITE_ROW {
                    isUploaded = sqlite3_column_int(statement, 0) > 0
                }
            }
            sqlite3_finalize(statement)
        }
        
        return isUploaded
    }
    
    /// Get all uploaded asset identifiers
    func getAllUploadedAssetIdentifiers() -> Set<String> {
        var identifiers: Set<String> = []
        
        dbQueue.sync {
            let sql = "SELECT DISTINCT asset_local_identifier FROM uploaded_assets;"
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    let identifier = String(cString: sqlite3_column_text(statement, 0))
                    identifiers.insert(identifier)
                }
            }
            sqlite3_finalize(statement)
        }
        
        return identifiers
    }
    
    /// Get the count of uploaded assets
    func getUploadedCount() -> Int {
        var count = 0
        
        dbQueue.sync {
            let sql = "SELECT COUNT(DISTINCT asset_local_identifier) FROM uploaded_assets;"
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(statement, 0))
                }
            }
            sqlite3_finalize(statement)
        }
        
        return count
    }
    
    // MARK: - Change Token Management
    
    /// Save change token
    func saveChangeToken(_ tokenData: Data?) {
        dbQueue.sync {
            let sql = """
                INSERT OR REPLACE INTO change_tokens (id, token_data, updated_at)
                VALUES (1, ?, ?);
            """
            
            var statement: OpaquePointer?
            let now = Date().timeIntervalSince1970
            
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                if let data = tokenData {
                    sqlite3_bind_blob(statement, 1, (data as NSData).bytes, Int32(data.count), SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(statement, 1)
                }
                sqlite3_bind_double(statement, 2, now)
                
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }
    
    /// Load change token
    func loadChangeToken() -> Data? {
        var tokenData: Data?
        
        dbQueue.sync {
            let sql = "SELECT token_data FROM change_tokens WHERE id = 1;"
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    if let blob = sqlite3_column_blob(statement, 0) {
                        let size = sqlite3_column_bytes(statement, 0)
                        tokenData = Data(bytes: blob, count: Int(size))
                    }
                }
            }
            sqlite3_finalize(statement)
        }
        
        return tokenData
    }
    
    // MARK: - Assets On Server Management
    
    /// Record an asset that is already on the server (synced from main app's hash_cache)
    func recordAssetOnServer(assetLocalIdentifier: String, sha1Hash: String?) {
        dbQueue.sync {
            let sql = """
                INSERT OR REPLACE INTO assets_on_server
                (asset_local_identifier, sha1_hash, synced_at)
                VALUES (?, ?, ?);
            """
            
            var statement: OpaquePointer?
            let now = Date().timeIntervalSince1970
            
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, assetLocalIdentifier, -1, SQLITE_TRANSIENT)
                if let hash = sha1Hash {
                    sqlite3_bind_text(statement, 2, hash, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(statement, 2)
                }
                sqlite3_bind_double(statement, 3, now)
                
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }
    
    /// Batch record assets that are already on the server
    func batchRecordAssetsOnServer(assets: [(assetLocalIdentifier: String, sha1Hash: String?)]) {
        dbQueue.sync {
            sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
            
            let sql = """
                INSERT OR REPLACE INTO assets_on_server
                (asset_local_identifier, sha1_hash, synced_at)
                VALUES (?, ?, ?);
            """
            
            var statement: OpaquePointer?
            let now = Date().timeIntervalSince1970
            
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                for asset in assets {
                    sqlite3_reset(statement)
                    sqlite3_bind_text(statement, 1, asset.assetLocalIdentifier, -1, SQLITE_TRANSIENT)
                    if let hash = asset.sha1Hash {
                        sqlite3_bind_text(statement, 2, hash, -1, SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_null(statement, 2)
                    }
                    sqlite3_bind_double(statement, 3, now)
                    
                    sqlite3_step(statement)
                }
            }
            sqlite3_finalize(statement)
            
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        }
    }
    
    /// Check if an asset is already on the server
    func isAssetOnServer(assetLocalIdentifier: String) -> Bool {
        var isOnServer = false
        
        dbQueue.sync {
            let sql = """
                SELECT COUNT(*) FROM assets_on_server
                WHERE asset_local_identifier = ?;
            """
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, assetLocalIdentifier, -1, SQLITE_TRANSIENT)
                
                if sqlite3_step(statement) == SQLITE_ROW {
                    isOnServer = sqlite3_column_int(statement, 0) > 0
                }
            }
            sqlite3_finalize(statement)
        }
        
        return isOnServer
    }
    
    /// Get all asset identifiers that are already on the server
    func getAllAssetsOnServer() -> Set<String> {
        var identifiers: Set<String> = []
        
        dbQueue.sync {
            let sql = "SELECT asset_local_identifier FROM assets_on_server;"
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    let identifier = String(cString: sqlite3_column_text(statement, 0))
                    identifiers.insert(identifier)
                }
            }
            sqlite3_finalize(statement)
        }
        
        return identifiers
    }
    
    /// Get count of assets on server
    func getAssetsOnServerCount() -> Int {
        var count = 0
        
        dbQueue.sync {
            let sql = "SELECT COUNT(*) FROM assets_on_server;"
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(statement, 0))
                }
            }
            sqlite3_finalize(statement)
        }
        
        return count
    }
    
    /// Clear all assets on server records
    func clearAssetsOnServer() {
        dbQueue.sync {
            let sql = "DELETE FROM assets_on_server;"
            executeSQL(sql)
        }
    }
    
    // MARK: - Hash Cache Management
    
    /// Save SHA1 hash for an asset
    func saveAssetHash(assetLocalIdentifier: String, sha1Hash: String) {
        dbQueue.sync {
            let sql = """
                INSERT OR REPLACE INTO hash_cache
                (asset_local_identifier, sha1_hash, calculated_at)
                VALUES (?, ?, ?);
            """
            
            var statement: OpaquePointer?
            let now = Date().timeIntervalSince1970
            
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, assetLocalIdentifier, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 2, sha1Hash, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(statement, 3, now)
                
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }
    
    /// Get cached SHA1 hash for an asset
    func getHashForAsset(assetLocalIdentifier: String) -> String? {
        var hash: String?
        
        dbQueue.sync {
            let sql = "SELECT sha1_hash FROM hash_cache WHERE asset_local_identifier = ?;"
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, assetLocalIdentifier, -1, SQLITE_TRANSIENT)
                
                if sqlite3_step(statement) == SQLITE_ROW {
                    if let cString = sqlite3_column_text(statement, 0) {
                        hash = String(cString: cString)
                    }
                }
            }
            sqlite3_finalize(statement)
        }
        
        return hash
    }
    
    // MARK: - Hash Checked Management
    
    /// Record that an asset's hash has been checked against the server
    func recordHashCheckedAsset(assetLocalIdentifier: String, sha1Hash: String, isOnServer: Bool) {
        dbQueue.sync {
            let sql = """
                INSERT OR REPLACE INTO hash_checked
                (asset_local_identifier, sha1_hash, is_on_server, checked_at)
                VALUES (?, ?, ?, ?);
            """
            
            var statement: OpaquePointer?
            let now = Date().timeIntervalSince1970
            
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, assetLocalIdentifier, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 2, sha1Hash, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(statement, 3, isOnServer ? 1 : 0)
                sqlite3_bind_double(statement, 4, now)
                
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }
    
    /// Get all asset identifiers that have been confirmed as existing on the server
    func getAssetsConfirmedOnServer() -> Set<String> {
        var identifiers: Set<String> = []
        
        dbQueue.sync {
            let sql = "SELECT asset_local_identifier FROM hash_checked WHERE is_on_server = 1;"
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let cString = sqlite3_column_text(statement, 0) {
                        identifiers.insert(String(cString: cString))
                    }
                }
            }
            sqlite3_finalize(statement)
        }
        
        return identifiers
    }
    
    /// Check if an asset has been hash-checked
    func isAssetHashChecked(assetLocalIdentifier: String) -> Bool {
        var isChecked = false
        
        dbQueue.sync {
            let sql = "SELECT COUNT(*) FROM hash_checked WHERE asset_local_identifier = ?;"
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, assetLocalIdentifier, -1, SQLITE_TRANSIENT)
                
                if sqlite3_step(statement) == SQLITE_ROW {
                    isChecked = sqlite3_column_int(statement, 0) > 0
                }
            }
            sqlite3_finalize(statement)
        }
        
        return isChecked
    }
    
    /// Get count of assets confirmed on server via hash check
    func getHashCheckedOnServerCount() -> Int {
        var count = 0
        
        dbQueue.sync {
            let sql = "SELECT COUNT(*) FROM hash_checked WHERE is_on_server = 1;"
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(statement, 0))
                }
            }
            sqlite3_finalize(statement)
        }
        
        return count
    }
    
    /// Clear all hash check records (useful when server data might have changed)
    func clearHashCheckedRecords() {
        dbQueue.sync {
            let sql = "DELETE FROM hash_checked;"
            executeSQL(sql)
        }
    }
    
    /// Clear hash cache
    func clearHashCache() {
        dbQueue.sync {
            let sql = "DELETE FROM hash_cache;"
            executeSQL(sql)
        }
    }
}

// MARK: - Supporting Types

enum UploadJobStatus: String {
    case pending = "pending"
    case uploading = "uploading"
    case completed = "completed"
    case failed = "failed"
}

struct UploadJobInfo {
    let id: Int
    let assetLocalIdentifier: String
    let resourceType: String
    let filename: String
    let retryCount: Int
}

// MARK: - SQLITE_TRANSIENT constant
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
