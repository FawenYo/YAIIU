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
        
        sqlite3_busy_timeout(db, 5000)

        // WAL mode for concurrent read/write across processes
        // PRAGMA returns a result row, so we need to handle it differently
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt) // This will return SQLITE_ROW with the mode value
        }
        sqlite3_finalize(stmt)

        // The background upload extension may launch before the host app gets a
        // chance to run schema setup, so ensure its persistent checkpoint and durable
        // delta queue exist here.
        exec("""
            CREATE TABLE IF NOT EXISTS change_tokens (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                token_data BLOB,
                updated_at REAL NOT NULL
            )
        """)
        exec("""
            CREATE TABLE IF NOT EXISTS background_upload_queue (
                asset_id TEXT PRIMARY KEY NOT NULL,
                enqueued_at REAL NOT NULL
            )
        """)
        exec("""
            CREATE TABLE IF NOT EXISTS background_upload_state (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                bootstrap_token_data BLOB,
                destination_identity TEXT,
                updated_at REAL NOT NULL
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_background_upload_queue_enqueued_at ON background_upload_queue(enqueued_at)")

        // Older extension builds created RAW jobs without updating has_raw. Repair
        // that durable resource-presence fact so a confirmed primary never hides a
        // failed RAW retry.
        exec("""
            UPDATE hash_cache SET has_raw = 1
            WHERE asset_id IN (
                SELECT DISTINCT asset_id FROM upload_jobs WHERE resource_type = 'raw'
            )
        """)
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

    func markResourcePresent(assetId: String, resourceType: String) {
        guard resourceType == "raw" else { return }
        queue.sync {
            let sql = "UPDATE hash_cache SET has_raw = 1 WHERE asset_id = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, assetId, -1, SQLITE_TRANSIENT)
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

    func markJobStatus(assetId: String, resourceType: String, status: UploadJobStatus) {
        queue.sync {
            let sql = "UPDATE upload_jobs SET status = ?, updated_at = ? WHERE asset_id = ? AND resource_type = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, assetId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, resourceType, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    // Removes tracked jobs (pending/uploading/failed) older than createdBefore whose
    // resource key is absent from the live PhotoKit job set. Such rows represent jobs
    // that vanished from PhotoKit (crash, expiry, library churn); leaving them would
    // make fetchPendingResources skip their assets forever.
    func pruneTrackedJobs(liveKeys: Set<String>, createdBefore: Date) -> Int {
        queue.sync {
            let cutoff = createdBefore.timeIntervalSince1970
            let selectSql = """
                SELECT id, asset_id, resource_type FROM upload_jobs
                WHERE status IN ('pending', 'uploading', 'failed') AND created_at < ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, selectSql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            sqlite3_bind_double(stmt, 1, cutoff)

            var doomed: [Int64] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int64(sqlite3_column_int64(stmt, 0))
                guard let aPtr = sqlite3_column_text(stmt, 1),
                      let tPtr = sqlite3_column_text(stmt, 2) else { continue }
                let key = "\(String(cString: aPtr))||\(String(cString: tPtr))"
                if !liveKeys.contains(key) { doomed.append(id) }
            }
            guard !doomed.isEmpty else { return 0 }

            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
            let deleteSql = "DELETE FROM upload_jobs WHERE id = ?"
            for id in doomed {
                var del: OpaquePointer?
                if sqlite3_prepare_v2(db, deleteSql, -1, &del, nil) == SQLITE_OK {
                    sqlite3_bind_int64(del, 1, id)
                    sqlite3_step(del)
                }
                sqlite3_finalize(del)
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            return doomed.count
        }
    }

    // Removes a tracking row entirely so createOrUpdateJob can re-insert it for a
    // replacement job; a completed-status row would be skipped by the upsert and a
    // failed-status row would keep the resource classified as inflight.
    func deleteTrackedJob(assetId: String, resourceType: String) {
        queue.sync {
            let sql = "DELETE FROM upload_jobs WHERE asset_id = ? AND resource_type = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, assetId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, resourceType, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    // Creation timestamps of locally tracked jobs, keyed "assetId||resourceType".
    func getTrackedJobAges() -> [String: Date] {
        queue.sync {
            var ages = [String: Date]()
            let sql = """
                SELECT asset_id, resource_type, created_at FROM upload_jobs
                WHERE status IN ('pending', 'uploading', 'failed')
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return ages }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let aPtr = sqlite3_column_text(stmt, 0),
                      let tPtr = sqlite3_column_text(stmt, 1) else { continue }
                let key = "\(String(cString: aPtr))||\(String(cString: tPtr))"
                ages[key] = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            }
            return ages
        }
    }

    func getInflightJobKeys() -> Set<String> {
        queue.sync {
            var keys = Set<String>()
            let sql = """
                SELECT asset_id, resource_type FROM upload_jobs
                WHERE status IN ('pending', 'uploading', 'failed')
            """

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return keys }

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let aPtr = sqlite3_column_text(stmt, 0),
                      let tPtr = sqlite3_column_text(stmt, 1) else { continue }
                let assetId = String(cString: aPtr)
                let type = String(cString: tPtr)
                keys.insert("\(assetId)||\(type)")
            }
            return keys
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
            
            // Per-resource server flags: raw uploads confirm only the raw copy.
            let flagColumn = resourceType == "raw" ? "raw_on_server" : "is_on_server"
            let updateSql = "UPDATE hash_cache SET \(flagColumn) = 1, checked_at = ? WHERE asset_id = ?"
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

    // MARK: - Change Token / Persistent Delta Queue

    private func sqliteError(_ operation: String) -> NSError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable"
        let code = db.map { Int(sqlite3_errcode($0)) } ?? -1
        return NSError(
            domain: "com.fawenyo.yaiiu.background-upload.database",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(message)"]
        )
    }

    /// Associates persistent PhotoKit discovery with the active upload destination.
    /// Changing account/server invalidates destination-specific completion state and
    /// forces a new bootstrap, while first-time initialization preserves existing
    /// upload/hash cache data from pre-delta builds.
    @discardableResult
    func ensureDestinationIdentity(_ identity: String) throws -> Bool {
        try queue.sync {
            guard let db else { throw sqliteError("Destination state database unavailable") }

            var selectStmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT destination_identity FROM background_upload_state WHERE id = 1",
                -1,
                &selectStmt,
                nil
            ) == SQLITE_OK else {
                throw sqliteError("Prepare destination identity read")
            }

            let selectResult = sqlite3_step(selectStmt)
            let hadStateRow = selectResult == SQLITE_ROW
            let existingIdentity: String? = hadStateRow
                ? sqlite3_column_text(selectStmt, 0).map { String(cString: $0) }
                : nil
            sqlite3_finalize(selectStmt)
            selectStmt = nil

            if existingIdentity == identity {
                return false
            }
            guard selectResult == SQLITE_ROW || selectResult == SQLITE_DONE else {
                throw sqliteError("Read destination identity")
            }

            guard sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION", nil, nil, nil) == SQLITE_OK else {
                throw sqliteError("Begin destination reset")
            }
            var committed = false
            defer {
                if !committed {
                    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                }
            }

            // A checkpoint created without a destination identity cannot be trusted
            // across an upgrade, so initialization also restarts persistent discovery.
            let checkpointResetSql = [
                "DELETE FROM change_tokens",
                "DELETE FROM background_upload_queue",
            ]
            for sql in checkpointResetSql {
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                    throw sqliteError("Reset persistent discovery")
                }
            }

            let destinationChanged = hadStateRow && existingIdentity != nil
            if destinationChanged {
                // These flags describe the previous server/account. Preserve hashes,
                // but require the new destination to reconfirm server presence.
                let destinationSpecificSql = [
                    "DELETE FROM uploaded_assets",
                    "DELETE FROM upload_jobs WHERE status = 'completed'",
                    "UPDATE hash_cache SET is_on_server = 0, raw_on_server = 0, checked_at = NULL",
                ]
                for sql in destinationSpecificSql {
                    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                        throw sqliteError("Reset destination-specific upload state")
                    }
                }
            }

            let upsertSql = """
                INSERT INTO background_upload_state
                    (id, bootstrap_token_data, destination_identity, updated_at)
                VALUES (1, NULL, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    bootstrap_token_data = NULL,
                    destination_identity = excluded.destination_identity,
                    updated_at = excluded.updated_at
            """
            var upsertStmt: OpaquePointer?
            defer { sqlite3_finalize(upsertStmt) }
            guard sqlite3_prepare_v2(db, upsertSql, -1, &upsertStmt, nil) == SQLITE_OK,
                  sqlite3_bind_text(upsertStmt, 1, identity, -1, SQLITE_TRANSIENT) == SQLITE_OK,
                  sqlite3_bind_double(upsertStmt, 2, Date().timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_step(upsertStmt) == SQLITE_DONE else {
                throw sqliteError("Persist destination identity")
            }

            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw sqliteError("Commit destination reset")
            }
            committed = true
            return true
        }
    }

    func loadBootstrapToken() throws -> Data? {
        try queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(
                db,
                "SELECT bootstrap_token_data FROM background_upload_state WHERE id = 1",
                -1,
                &stmt,
                nil
            ) == SQLITE_OK else {
                throw sqliteError("Prepare bootstrap token read")
            }

            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw sqliteError("Read bootstrap token") }
            guard let blob = sqlite3_column_blob(stmt, 0) else { return nil }
            return Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
        }
    }

    func saveBootstrapToken(_ data: Data) throws {
        try queue.sync {
            let sql = """
                INSERT INTO background_upload_state
                    (id, bootstrap_token_data, destination_identity, updated_at)
                VALUES (1, ?, NULL, ?)
                ON CONFLICT(id) DO UPDATE SET
                    bootstrap_token_data = excluded.bootstrap_token_data,
                    updated_at = excluded.updated_at
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_bind_blob(
                    stmt,
                    1,
                    (data as NSData).bytes,
                    Int32(data.count),
                    SQLITE_TRANSIENT
                  ) == SQLITE_OK,
                  sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError("Persist bootstrap token")
            }
        }
    }

    /// Atomically promotes the original bootstrap checkpoint to the persistent
    /// checkpoint and clears bootstrap state after the full reconciliation finishes.
    func promoteBootstrapToken(_ data: Data) throws {
        try queue.sync {
            guard let db else { throw sqliteError("Bootstrap promotion database unavailable") }
            guard sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION", nil, nil, nil) == SQLITE_OK else {
                throw sqliteError("Begin bootstrap promotion")
            }
            var committed = false
            defer {
                if !committed {
                    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                }
            }

            let now = Date().timeIntervalSince1970
            let tokenSql = """
                INSERT OR REPLACE INTO change_tokens (id, token_data, updated_at)
                VALUES (1, ?, ?)
            """
            var tokenStmt: OpaquePointer?
            defer { sqlite3_finalize(tokenStmt) }
            guard sqlite3_prepare_v2(db, tokenSql, -1, &tokenStmt, nil) == SQLITE_OK,
                  sqlite3_bind_blob(
                    tokenStmt,
                    1,
                    (data as NSData).bytes,
                    Int32(data.count),
                    SQLITE_TRANSIENT
                  ) == SQLITE_OK,
                  sqlite3_bind_double(tokenStmt, 2, now) == SQLITE_OK,
                  sqlite3_step(tokenStmt) == SQLITE_DONE else {
                throw sqliteError("Persist promoted bootstrap token")
            }

            var clearStmt: OpaquePointer?
            defer { sqlite3_finalize(clearStmt) }
            guard sqlite3_prepare_v2(
                db,
                "UPDATE background_upload_state SET bootstrap_token_data = NULL, updated_at = ? WHERE id = 1",
                -1,
                &clearStmt,
                nil
            ) == SQLITE_OK,
            sqlite3_bind_double(clearStmt, 1, now) == SQLITE_OK,
            sqlite3_step(clearStmt) == SQLITE_DONE else {
                throw sqliteError("Clear bootstrap token after promotion")
            }

            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw sqliteError("Commit bootstrap promotion")
            }
            committed = true
        }
    }

    /// Durably queues assets discovered by bootstrap before a persistent change
    /// checkpoint is established. INSERT OR IGNORE makes replay safe.
    func enqueueAssets(_ assetIds: Set<String>) throws {
        guard !assetIds.isEmpty else { return }
        try queue.sync {
            guard let db else { throw sqliteError("Queue database unavailable") }
            guard sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION", nil, nil, nil) == SQLITE_OK else {
                throw sqliteError("Begin queue transaction")
            }

            var committed = false
            defer {
                if !committed {
                    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                }
            }

            let sql = """
                INSERT OR IGNORE INTO background_upload_queue (asset_id, enqueued_at)
                VALUES (?, ?)
            """
            let now = Date().timeIntervalSince1970

            for assetId in assetIds {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    sqlite3_finalize(stmt)
                    throw sqliteError("Prepare queue insert")
                }
                sqlite3_bind_text(stmt, 1, assetId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 2, now)
                let result = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                guard result == SQLITE_DONE else {
                    throw sqliteError("Insert queued asset")
                }
            }

            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw sqliteError("Commit queue transaction")
            }
            committed = true
        }
    }

    /// Atomically persists a Photos persistent-change checkpoint with the asset IDs
    /// discovered before that checkpoint. This guarantees that advancing the token
    /// can never strand assets if the extension is terminated immediately afterward.
    func commitPersistentChange(
        insertedAssetIds: Set<String>,
        updatedAssetIds: Set<String>,
        deletedAssetIds: Set<String>,
        tokenData: Data
    ) -> Bool {
        queue.sync {
            guard let db else { return false }
            guard sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION", nil, nil, nil) == SQLITE_OK else {
                return false
            }

            var committed = false
            defer {
                if !committed {
                    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                }
            }

            let now = Date().timeIntervalSince1970
            let insertSql = """
                INSERT OR IGNORE INTO background_upload_queue (asset_id, enqueued_at)
                VALUES (?, ?)
            """
            var insertStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSql, -1, &insertStmt, nil) == SQLITE_OK else {
                sqlite3_finalize(insertStmt)
                return false
            }
            defer { sqlite3_finalize(insertStmt) }
            for assetId in insertedAssetIds.union(updatedAssetIds) {
                sqlite3_reset(insertStmt)
                sqlite3_clear_bindings(insertStmt)
                guard sqlite3_bind_text(insertStmt, 1, assetId, -1, SQLITE_TRANSIENT) == SQLITE_OK,
                      sqlite3_bind_double(insertStmt, 2, now) == SQLITE_OK,
                      sqlite3_step(insertStmt) == SQLITE_DONE else {
                    return false
                }
            }

            // A persistent asset update invalidates the resource state that was
            // recorded for the previous asset version. Keep active job rows so the
            // extension can recognize/cancel or acknowledge their stale PhotoKit
            // jobs, but remove completed rows so a current-version replacement job
            // can be tracked by createOrUpdateJob.
            let invalidationStatements = [
                "DELETE FROM uploaded_assets WHERE asset_id = ?",
                "DELETE FROM hash_cache WHERE asset_id = ?",
                "DELETE FROM upload_jobs WHERE asset_id = ? AND status = 'completed'",
            ]
            for sql in invalidationStatements {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    sqlite3_finalize(stmt)
                    return false
                }
                for assetId in updatedAssetIds {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    guard sqlite3_bind_text(stmt, 1, assetId, -1, SQLITE_TRANSIENT) == SQLITE_OK,
                          sqlite3_step(stmt) == SQLITE_DONE else {
                        sqlite3_finalize(stmt)
                        return false
                    }
                }
                sqlite3_finalize(stmt)
            }

            let deleteSql = "DELETE FROM background_upload_queue WHERE asset_id = ?"
            var deleteStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK else {
                sqlite3_finalize(deleteStmt)
                return false
            }
            defer { sqlite3_finalize(deleteStmt) }
            for assetId in deletedAssetIds {
                sqlite3_reset(deleteStmt)
                sqlite3_clear_bindings(deleteStmt)
                guard sqlite3_bind_text(deleteStmt, 1, assetId, -1, SQLITE_TRANSIENT) == SQLITE_OK,
                      sqlite3_step(deleteStmt) == SQLITE_DONE else {
                    return false
                }
            }

            let tokenSql = """
                INSERT OR REPLACE INTO change_tokens (id, token_data, updated_at)
                VALUES (1, ?, ?)
            """
            var tokenStmt: OpaquePointer?
            defer { sqlite3_finalize(tokenStmt) }
            guard sqlite3_prepare_v2(db, tokenSql, -1, &tokenStmt, nil) == SQLITE_OK else {
                return false
            }
            guard sqlite3_bind_blob(
                tokenStmt,
                1,
                (tokenData as NSData).bytes,
                Int32(tokenData.count),
                SQLITE_TRANSIENT
            ) == SQLITE_OK,
            sqlite3_bind_double(tokenStmt, 2, now) == SQLITE_OK,
            sqlite3_step(tokenStmt) == SQLITE_DONE else { return false }

            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                return false
            }
            committed = true
            return true
        }
    }

    func getQueuedAssetIds(limit: Int) throws -> [String] {
        try queue.sync {
            let sql = """
                SELECT q.asset_id
                FROM background_upload_queue AS q
                WHERE NOT EXISTS (
                    SELECT 1 FROM upload_jobs AS j
                    WHERE j.asset_id = q.asset_id
                      AND j.status IN ('pending', 'uploading', 'failed')
                )
                ORDER BY q.enqueued_at ASC
                LIMIT ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError("Prepare queued asset read")
            }
            sqlite3_bind_int(stmt, 1, Int32(max(1, limit)))

            var ids: [String] = []
            while true {
                let result = sqlite3_step(stmt)
                if result == SQLITE_ROW {
                    if let ptr = sqlite3_column_text(stmt, 0) {
                        ids.append(String(cString: ptr))
                    }
                } else if result == SQLITE_DONE {
                    break
                } else {
                    throw sqliteError("Read queued assets")
                }
            }
            return ids
        }
    }

    func removeQueuedAsset(_ assetId: String) {
        queue.sync {
            let sql = "DELETE FROM background_upload_queue WHERE asset_id = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, assetId, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    /// Keeps temporarily unresolved assets durable while rotating them behind other
    /// queued work so an iCloud-restoring asset cannot starve later candidates.
    func deferQueuedAssets(_ assetIds: Set<String>) throws {
        guard !assetIds.isEmpty else { return }
        try queue.sync {
            let sql = "UPDATE background_upload_queue SET enqueued_at = ? WHERE asset_id = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError("Prepare queued asset deferral")
            }
            let now = Date().timeIntervalSince1970
            for assetId in assetIds {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                guard sqlite3_bind_double(stmt, 1, now) == SQLITE_OK,
                      sqlite3_bind_text(stmt, 2, assetId, -1, SQLITE_TRANSIENT) == SQLITE_OK,
                      sqlite3_step(stmt) == SQLITE_DONE else {
                    throw sqliteError("Defer unresolved queued asset")
                }
            }
        }
    }

    func hasQueuedAssets() throws -> Bool {
        try queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(
                db,
                "SELECT 1 FROM background_upload_queue LIMIT 1",
                -1,
                &stmt,
                nil
            ) == SQLITE_OK else {
                throw sqliteError("Prepare queue existence read")
            }

            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW { return true }
            if result == SQLITE_DONE { return false }
            throw sqliteError("Read queue existence")
        }
    }

    func clearChangeToken() {
        queue.sync {
            exec("DELETE FROM change_tokens")
        }
    }
    
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

    // HashManager has already resolved local primary/RAW checksums against
    // server_assets_cache and persisted those results on hash_cache. The extension
    // consumes those flags; server_assets_cache itself has no local asset_id column.
    func getAllAssetsOnServer() -> Set<String> {
        queue.sync {
            var ids = Set<String>()
            let sql = """
                SELECT asset_id FROM hash_cache
                WHERE is_on_server = 1 AND (has_raw = 0 OR raw_on_server = 1)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                if let db { print("[BackgroundUploadDatabase] getAllAssetsOnServer: \(String(cString: sqlite3_errmsg(db)))") }
                return ids
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0) {
                    ids.insert(String(cString: cStr))
                }
            }
            return ids
        }
    }

    func getPartialServerCopyAssets() -> (primaryConfirmed: Set<String>, rawConfirmed: Set<String>) {
        queue.sync {
            var primaryConfirmed = Set<String>()
            var rawConfirmed = Set<String>()
            let sql = """
                SELECT asset_id, CASE WHEN is_on_server = 1 THEN 'p' ELSE 'r' END
                FROM hash_cache
                WHERE (is_on_server = 1 AND has_raw = 1 AND raw_on_server = 0)
                   OR (raw_on_server = 1 AND is_on_server = 0)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                if let db { print("[BackgroundUploadDatabase] getPartialServerCopyAssets: \(String(cString: sqlite3_errmsg(db)))") }
                return (primaryConfirmed, rawConfirmed)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idPtr = sqlite3_column_text(stmt, 0),
                      let kindPtr = sqlite3_column_text(stmt, 1) else { continue }
                let assetId = String(cString: idPtr)
                if String(cString: kindPtr) == "p" {
                    primaryConfirmed.insert(assetId)
                } else {
                    rawConfirmed.insert(assetId)
                }
            }
            return (primaryConfirmed, rawConfirmed)
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
