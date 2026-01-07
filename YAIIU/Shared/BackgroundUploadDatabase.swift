import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class BackgroundUploadDatabase {
    
    static let shared = BackgroundUploadDatabase()
    
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.fawenyo.yaiiu.bgdb", qos: .utility)
    
    private init() {
        openDatabase()
    }
    
    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }
    
    // MARK: - Database Setup
    
    private func openDatabase() {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.fawenyo.yaiiu"
        ) else {
            print("[BackgroundUploadDatabase] Failed to get app group container")
            return
        }
        
        let dbPath = containerURL.appendingPathComponent("yaiiu.sqlite").path
        
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            print("[BackgroundUploadDatabase] Failed to open database at: \(dbPath)")
            db = nil
            return
        }
        
        // WAL mode for concurrent read/write across processes
        // PRAGMA returns a result row, so we need to handle it differently
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt) // This will return SQLITE_ROW with the mode value
        }
        sqlite3_finalize(stmt)
    }
    
    private func exec(_ sql: String) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            if let db = db {
                let msg = String(cString: sqlite3_errmsg(db))
                print("[BackgroundUploadDatabase] SQL prepare error: \(msg)")
                print("[BackgroundUploadDatabase] Failed SQL: \(sql)")
            }
            return
        }
        
        if sqlite3_step(stmt) != SQLITE_DONE {
            if let db = db {
                let msg = String(cString: sqlite3_errmsg(db))
                print("[BackgroundUploadDatabase] SQL execution error: \(msg)")
                print("[BackgroundUploadDatabase] Failed SQL: \(sql)")
            }
        }
    }
    
    // MARK: - Upload Jobs
    
    func createOrUpdateJob(assetId: String, resourceType: String, filename: String, status: UploadJobStatus = .pending) {
        queue.sync {
            let sql = """
                INSERT INTO upload_jobs (asset_id, resource_type, filename, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(asset_id, resource_type) DO UPDATE SET status = ?, updated_at = ?
                WHERE status != 'completed'
            """
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            
            let now = Date().timeIntervalSince1970
            sqlite3_bind_text(stmt, 1, assetId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, resourceType, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, filename, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, status.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 5, now)
            sqlite3_bind_double(stmt, 6, now)
            sqlite3_bind_text(stmt, 7, status.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 8, now)
            
            sqlite3_step(stmt)
        }
    }
    
    func getPendingJobs(limit: Int = 100) -> [UploadJobInfo] {
        queue.sync {
            let sql = """
                SELECT id, asset_id, resource_type, filename, retry_count
                FROM upload_jobs
                WHERE status = 'pending' OR status = 'failed'
                ORDER BY created_at ASC
                LIMIT ?
            """
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            
            sqlite3_bind_int(stmt, 1, Int32(limit))
            
            var jobs: [UploadJobInfo] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                jobs.append(UploadJobInfo(
                    id: Int(sqlite3_column_int64(stmt, 0)),
                    assetLocalIdentifier: String(cString: sqlite3_column_text(stmt, 1)),
                    resourceType: String(cString: sqlite3_column_text(stmt, 2)),
                    filename: String(cString: sqlite3_column_text(stmt, 3)),
                    retryCount: Int(sqlite3_column_int(stmt, 4))
                ))
            }
            return jobs
        }
    }
    
    func updateJobStatus(jobId: Int, status: UploadJobStatus, immichId: String? = nil, errorMessage: String? = nil) {
        queue.sync {
            var sql = "UPDATE upload_jobs SET status = ?, updated_at = ?"
            if immichId != nil { sql += ", immich_id = ?" }
            if errorMessage != nil { sql += ", error_message = ?" }
            if status == .failed { sql += ", retry_count = retry_count + 1" }
            sql += " WHERE id = ?"
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            
            var idx: Int32 = 1
            sqlite3_bind_text(stmt, idx, status.rawValue, -1, SQLITE_TRANSIENT); idx += 1
            sqlite3_bind_double(stmt, idx, Date().timeIntervalSince1970); idx += 1
            
            if let immichId = immichId {
                sqlite3_bind_text(stmt, idx, immichId, -1, SQLITE_TRANSIENT); idx += 1
            }
            if let errorMessage = errorMessage {
                sqlite3_bind_text(stmt, idx, errorMessage, -1, SQLITE_TRANSIENT); idx += 1
            }
            
            sqlite3_bind_int(stmt, idx, Int32(jobId))
            sqlite3_step(stmt)
        }
    }
    
    func deleteCompletedJobs() {
        queue.sync {
            exec("DELETE FROM upload_jobs WHERE status = 'completed'")
        }
    }
    
    // MARK: - Uploaded Assets
    
    func recordUploadedAsset(assetId: String, resourceType: String, filename: String, immichId: String, fileSize: Int64, isDuplicate: Bool) {
        queue.sync {
            let sql = """
                INSERT OR REPLACE INTO uploaded_assets
                (asset_id, resource_type, filename, immich_id, file_size, is_duplicate, uploaded_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            
            sqlite3_bind_text(stmt, 1, assetId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, resourceType, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, filename, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, immichId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 5, fileSize)
            sqlite3_bind_int(stmt, 6, isDuplicate ? 1 : 0)
            sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
            
            sqlite3_step(stmt)
            
            // Mark as on server in hash cache
            let updateSql = "UPDATE hash_cache SET is_on_server = 1, checked_at = ? WHERE asset_id = ?"
            var updateStmt: OpaquePointer?
            defer { sqlite3_finalize(updateStmt) }
            
            if sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK {
                sqlite3_bind_double(updateStmt, 1, Date().timeIntervalSince1970)
                sqlite3_bind_text(updateStmt, 2, assetId, -1, SQLITE_TRANSIENT)
                sqlite3_step(updateStmt)
            }
        }
    }
    
    func isResourceUploaded(assetId: String, resourceType: String) -> Bool {
        queue.sync {
            let sql = "SELECT 1 FROM uploaded_assets WHERE asset_id = ? AND resource_type = ? LIMIT 1"
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            
            sqlite3_bind_text(stmt, 1, assetId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, resourceType, -1, SQLITE_TRANSIENT)
            
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }
    
    func isAnyResourceUploaded(assetId: String) -> Bool {
        queue.sync {
            let sql = "SELECT 1 FROM uploaded_assets WHERE asset_id = ? LIMIT 1"
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            
            sqlite3_bind_text(stmt, 1, assetId, -1, SQLITE_TRANSIENT)
            
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }
    
    func getAllUploadedAssetIds() -> Set<String> {
        queue.sync {
            var ids = Set<String>()
            let sql = "SELECT DISTINCT asset_id FROM uploaded_assets WHERE asset_id IS NOT NULL"
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return ids }
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0) {
                    ids.insert(String(cString: cStr))
                }
            }
            return ids
        }
    }
    
    func getUploadedCount() -> Int {
        queue.sync {
            let sql = "SELECT COUNT(DISTINCT asset_id) FROM uploaded_assets"
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                if let db = db {
                    let msg = String(cString: sqlite3_errmsg(db))
                    print("[BackgroundUploadDatabase] getUploadedCount prepare error: \(msg)")
                }
                return 0
            }
            
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                if let db = db {
                    let msg = String(cString: sqlite3_errmsg(db))
                    print("[BackgroundUploadDatabase] getUploadedCount step error: \(msg)")
                }
                return 0
            }
            
            return Int(sqlite3_column_int(stmt, 0))
        }
    }
    
    // MARK: - Change Token
    
    func saveChangeToken(_ data: Data?) {
        queue.sync {
            let sql = "INSERT OR REPLACE INTO change_tokens (id, token_data, updated_at) VALUES (1, ?, ?)"
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            
            if let data = data {
                sqlite3_bind_blob(stmt, 1, (data as NSData).bytes, Int32(data.count), SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            
            sqlite3_step(stmt)
        }
    }
    
    func loadChangeToken() -> Data? {
        queue.sync {
            let sql = "SELECT token_data FROM change_tokens WHERE id = 1"
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let blob = sqlite3_column_blob(stmt, 0) else { return nil }
            
            let size = sqlite3_column_bytes(stmt, 0)
            return Data(bytes: blob, count: Int(size))
        }
    }
    
    // MARK: - Assets On Server
    
    func recordAssetOnServer(assetId: String, sha1Hash: String?) {
        queue.sync {
            let sql = "INSERT OR REPLACE INTO assets_on_server (asset_id, sha1_hash, synced_at) VALUES (?, ?, ?)"
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            
            sqlite3_bind_text(stmt, 1, assetId, -1, SQLITE_TRANSIENT)
            if let hash = sha1Hash {
                sqlite3_bind_text(stmt, 2, hash, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            
            sqlite3_step(stmt)
        }
    }
    
    func batchRecordAssetsOnServer(_ assets: [(assetId: String, sha1Hash: String?)]) {
        queue.sync {
            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
            defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }
            
            let sql = "INSERT OR REPLACE INTO assets_on_server (asset_id, sha1_hash, synced_at) VALUES (?, ?, ?)"
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            
            let now = Date().timeIntervalSince1970
            for asset in assets {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, asset.assetId, -1, SQLITE_TRANSIENT)
                if let hash = asset.sha1Hash {
                    sqlite3_bind_text(stmt, 2, hash, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 2)
                }
                sqlite3_bind_double(stmt, 3, now)
                sqlite3_step(stmt)
            }
        }
    }
    
    func isAssetOnServer(assetId: String) -> Bool {
        queue.sync {
            let sql = "SELECT 1 FROM assets_on_server WHERE asset_id = ? LIMIT 1"
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            
            sqlite3_bind_text(stmt, 1, assetId, -1, SQLITE_TRANSIENT)
            
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }
    
    func getAllAssetsOnServer() -> Set<String> {
        queue.sync {
            var ids = Set<String>()
            
            // From assets_on_server table
            var stmt: OpaquePointer?
            let sql1 = "SELECT asset_id FROM assets_on_server"
            if sqlite3_prepare_v2(db, sql1, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let cStr = sqlite3_column_text(stmt, 0) {
                        ids.insert(String(cString: cStr))
                    }
                }
            }
            sqlite3_finalize(stmt)
            
            // Also check hash_cache for confirmed uploads
            let sql2 = "SELECT asset_id FROM hash_cache WHERE is_on_server = 1"
            if sqlite3_prepare_v2(db, sql2, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let cStr = sqlite3_column_text(stmt, 0) {
                        ids.insert(String(cString: cStr))
                    }
                }
            }
            sqlite3_finalize(stmt)
            
            return ids
        }
    }
    
    func getAssetsOnServerCount() -> Int {
        queue.sync {
            let sql = "SELECT COUNT(*) FROM assets_on_server"
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }
    
    func clearAssetsOnServer() {
        queue.sync {
            exec("DELETE FROM assets_on_server")
        }
    }
    
    // MARK: - Hash Cache
    
    func saveAssetHash(assetId: String, sha1Hash: String) {
        queue.sync {
            let sql = """
                INSERT OR REPLACE INTO hash_cache (asset_id, sha1_hash, is_on_server, calculated_at)
                VALUES (?, ?, 0, ?)
            """
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            
            sqlite3_bind_text(stmt, 1, assetId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, sha1Hash, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            
            sqlite3_step(stmt)
        }
    }
    
    func getHashForAsset(assetId: String) -> String? {
        queue.sync {
            let sql = "SELECT sha1_hash FROM hash_cache WHERE asset_id = ?"
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            
            sqlite3_bind_text(stmt, 1, assetId, -1, SQLITE_TRANSIENT)
            
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let cStr = sqlite3_column_text(stmt, 0) else { return nil }
            
            return String(cString: cStr)
        }
    }
    
    func recordHashChecked(assetId: String, sha1Hash: String, isOnServer: Bool) {
        queue.sync {
            // Try update first
            let updateSql = "UPDATE hash_cache SET is_on_server = ?, checked_at = ? WHERE asset_id = ?"
            
            var stmt: OpaquePointer?
            
            if sqlite3_prepare_v2(db, updateSql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, isOnServer ? 1 : 0)
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
                sqlite3_bind_text(stmt, 3, assetId, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            
            // Insert if no row was updated
            if sqlite3_changes(db) == 0 {
                let insertSql = """
                    INSERT INTO hash_cache (asset_id, sha1_hash, is_on_server, calculated_at, checked_at)
                    VALUES (?, ?, ?, ?, ?)
                """
                
                if sqlite3_prepare_v2(db, insertSql, -1, &stmt, nil) == SQLITE_OK {
                    let now = Date().timeIntervalSince1970
                    sqlite3_bind_text(stmt, 1, assetId, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, sha1Hash, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(stmt, 3, isOnServer ? 1 : 0)
                    sqlite3_bind_double(stmt, 4, now)
                    sqlite3_bind_double(stmt, 5, now)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }
        }
    }
    
    func getAssetsConfirmedOnServer() -> Set<String> {
        queue.sync {
            var ids = Set<String>()
            let sql = "SELECT asset_id FROM hash_cache WHERE is_on_server = 1"
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return ids }
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0) {
                    ids.insert(String(cString: cStr))
                }
            }
            return ids
        }
    }
    
    func clearHashCache() {
        queue.sync {
            exec("DELETE FROM hash_cache")
        }
    }
}

// MARK: - Types

enum UploadJobStatus: String {
    case pending
    case uploading
    case completed
    case failed
}

struct UploadJobInfo {
    let id: Int
    let assetLocalIdentifier: String
    let resourceType: String
    let filename: String
    let retryCount: Int
}
