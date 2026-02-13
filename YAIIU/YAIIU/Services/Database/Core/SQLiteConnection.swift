import Foundation
import SQLite3

final class SQLiteConnection {
    static let shared = SQLiteConnection()
    
    private(set) var db: OpaquePointer?
    let dbQueue = DispatchQueue(label: "com.fawenyo.yaiiu.database", qos: .userInitiated)
    
    private let dbName = "yaiiu.sqlite"
    private var isInitialized = false
    private let initLock = NSLock()
    
    private static let schemaVersion = 3
    
    private init() {
        dbQueue.async { [weak self] in
            self?.openDatabase()
            self?.createTables()
            self?.migrateIfNeeded()
            self?.initLock.lock()
            self?.isInitialized = true
            self?.initLock.unlock()
            logInfo("SQLiteConnection initialized", category: .database)
        }
    }
    
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
            total_assets INTEGER DEFAULT 0
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
    
    private func createIndexes() {
        executeStatement("CREATE INDEX IF NOT EXISTS idx_jobs_status ON upload_jobs(status)")
        executeStatement("CREATE INDEX IF NOT EXISTS idx_jobs_asset ON upload_jobs(asset_id)")
        executeStatement("CREATE INDEX IF NOT EXISTS idx_uploaded_asset ON uploaded_assets(asset_id)")
        executeStatement("CREATE INDEX IF NOT EXISTS idx_server_cache_checksum ON server_assets_cache(checksum)")
        executeStatement("CREATE INDEX IF NOT EXISTS idx_server_cache_immich_id ON server_assets_cache(immich_id)")
        executeStatement("CREATE INDEX IF NOT EXISTS idx_server_cache_icloud_id ON server_assets_cache(icloud_id)")
        executeStatement("CREATE INDEX IF NOT EXISTS idx_hash_asset ON hash_cache(asset_id)")
        executeStatement("CREATE INDEX IF NOT EXISTS idx_hash_on_server ON hash_cache(is_on_server)")
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
            
            if currentVersion < 2 {
                migrateToV2()
            }
            
            if currentVersion < 3 {
                // Remediation for users affected by the v2 init ordering bug.
                // Re-running the v2 migration ensures the column exists.
                logInfo("Running v3 remediation by ensuring v2 migration logic is complete", category: .database)
                migrateToV2()
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
    
    func beginTransaction() {
        sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
    }
    
    func commitTransaction() {
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }
    
    func rollbackTransaction() {
        sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
    }
    
    func inTransaction(_ block: () -> Void) {
        beginTransaction()
        block()
        commitTransaction()
    }
    
    // MARK: - Error Handling
    
    var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(db))
    }
}
