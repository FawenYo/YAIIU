import Foundation
import SQLite3

final class SQLiteConnection {
    static let shared = SQLiteConnection()
    
    private(set) var db: OpaquePointer?
    let dbQueue = DispatchQueue(label: "com.fawenyo.yaiiu.database", qos: .userInitiated)
    
    private let dbName = "yaiiu.sqlite"
    private var isInitialized = false
    private let initLock = NSLock()
    
    private static let schemaVersion = 9
    
    private init(databasePath: String? = nil) {
        dbQueue.async { [weak self] in
            guard let self else { return }
            if let databasePath {
                self.openDatabaseAtPath(databasePath)
            } else {
                self.openDatabase()
            }
            self.createTables()
            self.migrateIfNeeded()
            self.initLock.lock()
            self.isInitialized = true
            self.initLock.unlock()
            logInfo("SQLiteConnection initialized", category: .database)
        }
    }

#if DEBUG
    static func testing(databasePath: String) -> SQLiteConnection {
        SQLiteConnection(databasePath: databasePath)
    }
#endif
    
    deinit {
        sqlite3_close(db)
    }
    
    // MARK: - Initialization
    
    func ensureInitialized() {
        initLock.lock()
        let initialized = isInitialized
        initLock.unlock()
        
        if !initialized {
            dbQueue.sync { }
        }
    }
    
    // MARK: - Database Setup
    
    private func openDatabase() {
        let appGroupIdentifier = "group.com.fawenyo.yaiiu"
        
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            logError("Failed to get app group container URL", category: .database)
            let fileURL = documentsDirectory.appendingPathComponent(dbName)
            openDatabaseAtPath(fileURL.path)
            return
        }
        
        let fileURL = containerURL.appendingPathComponent(dbName)
        logDebug("Opening database at: \(fileURL.path)", category: .database)
        openDatabaseAtPath(fileURL.path)
    }
    
    private func openDatabaseAtPath(_ path: String) {
        if sqlite3_open(path, &db) != SQLITE_OK {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            logError("Failed to open database: \(errorMsg)", category: .database)
            return
        }
        
        logDebug("Database opened successfully", category: .database)
        enableWALMode()
        sqlite3_busy_timeout(db, 5000)
    }
    
    private func enableWALMode() {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL;", -1, &statement, nil) == SQLITE_OK {
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }
    
    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    // MARK: - Schema Management
    
    private func createTables() {
        createUploadedAssetsTable()
        createUploadJobsTable()
        createHashCacheTable()
        createServerAssetsCacheTable()
        createSyncMetadataTable()
        createChangeTokensTable()
        createBackgroundUploadQueueTable()
        createBackgroundUploadStateTable()
        createIndexes()
    }
    
    private func createUploadedAssetsTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS uploaded_assets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            asset_id TEXT NOT NULL,
            resource_type TEXT NOT NULL,
            filename TEXT NOT NULL,
            immich_id TEXT NOT NULL,
            file_size INTEGER,
            is_duplicate INTEGER DEFAULT 0,
            is_favorite INTEGER DEFAULT 0,
            uploaded_at REAL NOT NULL,
            UNIQUE(asset_id, resource_type)
        );
        """
        executeStatement(sql)
    }
    
    private func createUploadJobsTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS upload_jobs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            asset_id TEXT NOT NULL,
            resource_type TEXT NOT NULL,
            filename TEXT NOT NULL,
            status TEXT DEFAULT 'pending',
            immich_id TEXT,
            error_message TEXT,
            retry_count INTEGER DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(asset_id, resource_type)
        );
        """
        executeStatement(sql)
    }
    
    private func createHashCacheTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS hash_cache (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            asset_id TEXT NOT NULL UNIQUE,
            sha1_hash TEXT NOT NULL,
            is_on_server INTEGER DEFAULT 0,
            calculated_at REAL NOT NULL,
            checked_at REAL,
            raw_hash TEXT,
            raw_on_server INTEGER DEFAULT 0,
            has_raw INTEGER DEFAULT 0
        );
        """
        executeStatement(sql)
    }
    
    private func createServerAssetsCacheTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS server_assets_cache (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            immich_id TEXT NOT NULL UNIQUE,
            checksum TEXT NOT NULL,
            source_checksum TEXT,
            original_filename TEXT,
            asset_type TEXT,
            updated_at TEXT,
            synced_at REAL NOT NULL
        );
        """
        executeStatement(sql)
    }
    
    private func createSyncMetadataTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS sync_metadata (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            last_sync_time REAL,
            last_sync_type TEXT,
            user_id TEXT,
            total_assets INTEGER DEFAULT 0,
            last_ack TEXT,
            server_url TEXT
        );
        """
        executeStatement(sql)
    }
    
    private func createChangeTokensTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS change_tokens (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            token_data BLOB,
            updated_at REAL NOT NULL
        );
        """
        executeStatement(sql)
    }

    private func createBackgroundUploadQueueTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS background_upload_queue (
            asset_id TEXT PRIMARY KEY NOT NULL,
            enqueued_at REAL NOT NULL
        );
        """
        executeStatement(sql)
    }

    private func createBackgroundUploadStateTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS background_upload_state (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            bootstrap_token_data BLOB,
            destination_identity TEXT,
            updated_at REAL NOT NULL
        );
        """
        executeStatement(sql)
    }
    
    private func createIndexes() {
        executeStatement("CREATE INDEX IF NOT EXISTS idx_jobs_status ON upload_jobs(status)")
        executeStatement("CREATE INDEX IF NOT EXISTS idx_background_upload_queue_enqueued_at ON background_upload_queue(enqueued_at)")
        executeStatement("CREATE INDEX IF NOT EXISTS idx_jobs_asset ON upload_jobs(asset_id)")
        executeStatement("CREATE INDEX IF NOT EXISTS idx_uploaded_asset ON uploaded_assets(asset_id)")
        executeStatement("CREATE INDEX IF NOT EXISTS idx_server_cache_checksum ON server_assets_cache(checksum)")
        executeStatement("CREATE INDEX IF NOT EXISTS idx_server_cache_immich_id ON server_assets_cache(immich_id)")
        executeStatement("CREATE INDEX IF NOT EXISTS idx_server_cache_icloud_id ON server_assets_cache(icloud_id)")
        executeStatement("CREATE INDEX IF NOT EXISTS idx_hash_asset ON hash_cache(asset_id)")
        executeStatement("CREATE INDEX IF NOT EXISTS idx_hash_on_server ON hash_cache(is_on_server)")
        executeStatement("CREATE INDEX IF NOT EXISTS idx_server_cache_source_checksum ON server_assets_cache(source_checksum)")
    }
    
    // MARK: - Schema Migration
    
    private func getCurrentSchemaVersion() -> Int {
        var version = 0
        let sql = "PRAGMA user_version;"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                version = Int(sqlite3_column_int(statement, 0))
            }
        }
        sqlite3_finalize(statement)
        return version
    }
    
    private func setSchemaVersion(_ version: Int) {
        let sql = "PRAGMA user_version = \(version);"
        executeStatement(sql)
    }
    
    /// Perform database migrations if needed.
    /// Tables are always created first via `createTables()`, so migrations
    /// can safely use ALTER TABLE even on a fresh install.
    private func migrateIfNeeded() {
        let currentVersion = getCurrentSchemaVersion()
        
        if currentVersion < SQLiteConnection.schemaVersion {
            logInfo("Database migration needed: \(currentVersion) -> \(SQLiteConnection.schemaVersion)", category: .database)

            if currentVersion < 2 { migrateToV2() }
            if currentVersion < 3 {
                logInfo("Running v3 remediation by ensuring v2 migration logic is complete", category: .database)
                migrateToV2()
            }
            if currentVersion < 4 { migrateToV4() }
            if currentVersion < 5 { migrateToV5() }
            if currentVersion < 6 { migrateToV6() }
            if currentVersion < 7 { migrateToV7() }
            if currentVersion < 8 { migrateToV8() }
            if currentVersion < 9 { migrateToV9() }

            guard hasSchemaColumnsForCurrentVersion() else {
                logError("Database migration incomplete; retaining schema version \(currentVersion)", category: .database)
                return
            }
            setSchemaVersion(SQLiteConnection.schemaVersion)
            logInfo("Database migration completed to version \(SQLiteConnection.schemaVersion)", category: .database)
        }
    }
    
    /// Migration to version 2: Add icloud_id column to server_assets_cache table.
    private func migrateToV2() {
        logInfo("Migrating database to version 2: adding icloud_id column", category: .database)
        
        // Check if column already exists (in case of partial migration)
        let checkSql = "PRAGMA table_info(server_assets_cache);"
        var statement: OpaquePointer?
        var hasICloudIdColumn = false
        
        if sqlite3_prepare_v2(db, checkSql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let columnName = sqlite3_column_text(statement, 1) {
                    let name = String(cString: columnName)
                    if name == "icloud_id" {
                        hasICloudIdColumn = true
                        break
                    }
                }
            }
        }
        sqlite3_finalize(statement)
        
        if !hasICloudIdColumn {
            executeStatement("ALTER TABLE server_assets_cache ADD COLUMN icloud_id TEXT;")
            logInfo("Added icloud_id column to server_assets_cache", category: .database)
        } else {
            logInfo("icloud_id column already exists, skipping", category: .database)
        }
    }

    /// Migration to version 4: Add asset_modification_date column to hash_cache table.
    private func migrateToV4() {
        logInfo("Migrating database to version 4: adding asset_modification_date column", category: .database)

        let checkSql = "PRAGMA table_info(hash_cache);"
        var statement: OpaquePointer?
        var hasColumn = false

        if sqlite3_prepare_v2(db, checkSql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let columnName = sqlite3_column_text(statement, 1) {
                    if String(cString: columnName) == "asset_modification_date" {
                        hasColumn = true
                        break
                    }
                }
            }
        }
        sqlite3_finalize(statement)

        if !hasColumn {
            executeStatement("ALTER TABLE hash_cache ADD COLUMN asset_modification_date REAL;")
            logInfo("Added asset_modification_date column to hash_cache", category: .database)
        } else {
            logInfo("asset_modification_date column already exists, skipping", category: .database)
        }
    }

    /// Migration to version 5: Add last_ack column to sync_metadata table and owner_id column to server_assets_cache table.
    private func migrateToV5() {
        logInfo("Migrating database to version 5", category: .database)

        let syncCheckSql = "PRAGMA table_info(sync_metadata);"
        var statement: OpaquePointer?
        var hasLastAck = false

        if sqlite3_prepare_v2(db, syncCheckSql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let columnName = sqlite3_column_text(statement, 1) {
                    if String(cString: columnName) == "last_ack" {
                        hasLastAck = true
                        break
                    }
                }
            }
        }
        sqlite3_finalize(statement)

        if !hasLastAck {
            executeStatement("ALTER TABLE sync_metadata ADD COLUMN last_ack TEXT;")
            logInfo("Added last_ack column to sync_metadata", category: .database)
        }

        let assetCheckSql = "PRAGMA table_info(server_assets_cache);"
        var hasOwnerId = false

        if sqlite3_prepare_v2(db, assetCheckSql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let columnName = sqlite3_column_text(statement, 1) {
                    if String(cString: columnName) == "owner_id" {
                        hasOwnerId = true
                        break
                    }
                }
            }
        }
        sqlite3_finalize(statement)

        if !hasOwnerId {
            executeStatement("ALTER TABLE server_assets_cache ADD COLUMN owner_id TEXT;")
            executeStatement("CREATE INDEX IF NOT EXISTS idx_server_cache_owner_id ON server_assets_cache(owner_id);")
            logInfo("Added owner_id column to server_assets_cache", category: .database)
        }
    }

    private func migrateToV6() {
        let checkSql = "PRAGMA table_info(sync_metadata);"
        var statement: OpaquePointer?
        var hasServerURL = false

        if sqlite3_prepare_v2(db, checkSql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let columnName = sqlite3_column_text(statement, 1),
                   String(cString: columnName) == "server_url" {
                    hasServerURL = true
                    break
                }
            }
        }
        sqlite3_finalize(statement)

        if !hasServerURL {
            guard sqlite3_exec(db, "ALTER TABLE sync_metadata ADD COLUMN server_url TEXT;", nil, nil, nil) == SQLITE_OK else {
                logError("Failed to add server_url column: \(lastErrorMessage)", category: .database)
                return
            }
        }
    }
    private func migrateToV7() {
        let checkSql = "PRAGMA table_info(server_assets_cache);"
        var statement: OpaquePointer?
        var hasSourceChecksum = false

        if sqlite3_prepare_v2(db, checkSql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let columnName = sqlite3_column_text(statement, 1),
                   String(cString: columnName) == "source_checksum" {
                    hasSourceChecksum = true
                    break
                }
            }
        }
        sqlite3_finalize(statement)

        if !hasSourceChecksum {
            guard sqlite3_exec(db, "ALTER TABLE server_assets_cache ADD COLUMN source_checksum TEXT;", nil, nil, nil) == SQLITE_OK else {
                logError("Failed to add source_checksum column: \(lastErrorMessage)", category: .database)
                return
            }
        }
    }

    /// Migration to version 8: index source_checksum so album-asset resolution
    /// avoids a full scan of server_assets_cache.
    private func migrateToV8() {
        logInfo("Migrating database to version 8: indexing source_checksum", category: .database)
        executeStatement("CREATE INDEX IF NOT EXISTS idx_server_cache_source_checksum ON server_assets_cache(source_checksum)")
    }

    /// Migration to version 9: persist PhotoKit delta candidates so the background
    /// upload extension can advance its persistent change token without losing assets
    /// when a run is interrupted or PhotoKit job capacity is exhausted.
    private func migrateToV9() {
        logInfo("Migrating database to version 9: adding background upload delta queue", category: .database)
        executeStatement("""
            CREATE TABLE IF NOT EXISTS background_upload_queue (
                asset_id TEXT PRIMARY KEY NOT NULL,
                enqueued_at REAL NOT NULL
            );
        """)
        executeStatement(
            "CREATE INDEX IF NOT EXISTS idx_background_upload_queue_enqueued_at ON background_upload_queue(enqueued_at)"
        )
        executeStatement("""
            CREATE TABLE IF NOT EXISTS background_upload_state (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                bootstrap_token_data BLOB,
                destination_identity TEXT,
                updated_at REAL NOT NULL
            );
        """)
    }


    private func hasSchemaColumnsForCurrentVersion() -> Bool {
        let syncMetadataColumns = tableColumns("sync_metadata")
        let serverAssetColumns = tableColumns("server_assets_cache")
        let backgroundUploadQueueColumns = tableColumns("background_upload_queue")
        let backgroundUploadStateColumns = tableColumns("background_upload_state")
        return ["last_ack", "server_url"].allSatisfy(syncMetadataColumns.contains)
            && serverAssetColumns.contains("source_checksum")
            && ["asset_id", "enqueued_at"].allSatisfy(backgroundUploadQueueColumns.contains)
            && ["bootstrap_token_data", "destination_identity", "updated_at"].allSatisfy(backgroundUploadStateColumns.contains)
    }

    private func tableColumns(_ table: String) -> Set<String> {
        var found = Set<String>()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
            return found
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                found.insert(String(cString: name))
            }
        }
        sqlite3_finalize(statement)
        return found
    }

    // MARK: - Statement Execution
    
    func executeStatement(_ sql: String) {
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_step(statement)
        }
        
        sqlite3_finalize(statement)
    }
    
    func prepareStatement(_ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            return statement
        }
        return nil
    }
    
    // MARK: - Transaction Management
    
    @discardableResult
    func beginTransaction() -> Bool {
        sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil) == SQLITE_OK
    }

    @discardableResult
    func commitTransaction() -> Bool {
        sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK
    }

    @discardableResult
    func rollbackTransaction() -> Bool {
        sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) == SQLITE_OK
    }

    @discardableResult
    func inTransaction(_ block: () -> Void) -> Bool {
        guard beginTransaction() else { return false }
        block()
        guard commitTransaction() else {
            rollbackTransaction()
            return false
        }
        return true
    }

    /// Flush WAL journal to the main database file so a file copy is complete.
    func checkpointWAL() {
        sqlite3_exec(db, "PRAGMA wal_checkpoint(FULL);", nil, nil, nil)
    }

    // MARK: - Error Handling
    
    var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(db))
    }
}
