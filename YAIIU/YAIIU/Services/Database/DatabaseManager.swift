import Foundation
import SQLite3

/// Facade for database operations.
/// Delegates to specialized repositories while maintaining backward compatibility.
final class DatabaseManager {
    static let shared = DatabaseManager()
    
    private let uploadRepo: UploadRecordRepository
    private let hashRepo: HashCacheRepository
    private let serverRepo: ServerAssetRepository
    private let favoriteRepo: FavoriteRepository
    private let connection: SQLiteConnection
    
    private init() {
        self.connection = SQLiteConnection.shared
        self.uploadRepo = UploadRecordRepository(connection: connection)
        self.hashRepo = HashCacheRepository(connection: connection)
        self.serverRepo = ServerAssetRepository(connection: connection)
        self.favoriteRepo = FavoriteRepository(connection: connection)
        logInfo("DatabaseManager initialized", category: .database)
    }
    
    // MARK: - Upload Record Management
    
    func isAssetUploaded(localIdentifier: String, resourceType: String = "primary") -> Bool {
        uploadRepo.isAssetUploaded(localIdentifier: localIdentifier, resourceType: resourceType)
    }
    
    func isAnyResourceUploaded(localIdentifier: String) -> Bool {
        uploadRepo.isAnyResourceUploaded(localIdentifier: localIdentifier)
    }
    
    func recordUploadedAsset(
        localIdentifier: String,
        resourceType: String,
        filename: String,
        immichId: String,
        fileSize: Int64 = 0,
        isDuplicate: Bool = false,
        isFavorite: Bool = false
    ) {
        uploadRepo.recordUploadedAsset(
            localIdentifier: localIdentifier,
            resourceType: resourceType,
            filename: filename,
            immichId: immichId,
            fileSize: fileSize,
            isDuplicate: isDuplicate,
            isFavorite: isFavorite
        )
    }
    
    func getUploadedCount() -> Int {
        uploadRepo.getUploadedCount()
    }
    
    func getUploadedCountAsync(completion: @escaping (Int) -> Void) {
        uploadRepo.getUploadedCountAsync(completion: completion)
    }
    
    func getAllUploadedAssetIds() -> Set<String> {
        uploadRepo.getAllUploadedAssetIds()
    }
    
    func getAllUploadedAssetIdsAsync(completion: @escaping (Set<String>) -> Void) {
        uploadRepo.getAllUploadedAssetIdsAsync(completion: completion)
    }
    
    func getUploadedResourceCount() -> Int {
        uploadRepo.getUploadedResourceCount()
    }
    
    func getUploadRecords(for localIdentifier: String) -> [UploadRecord] {
        uploadRepo.getUploadRecords(for: localIdentifier)
    }
    
    func deleteUploadRecord(for localIdentifier: String) {
        uploadRepo.deleteUploadRecord(for: localIdentifier)
    }
    
    func clearAllUploadRecords() {
        uploadRepo.clearAllUploadRecords()
    }
    
    // MARK: - Hash Cache Management
    
    func saveHashCache(localIdentifier: String, sha1Hash: String, fileSize: Int64 = 0, syncStatus: String = "pending") {
        hashRepo.saveHashCache(localIdentifier: localIdentifier, sha1Hash: sha1Hash)
    }
    
    func saveMultiResourceHashCache(
        localIdentifier: String,
        primaryHash: String,
        rawHash: String?,
        hasRAW: Bool
    ) {
        hashRepo.saveMultiResourceHashCache(
            localIdentifier: localIdentifier,
            primaryHash: primaryHash,
            rawHash: rawHash,
            hasRAW: hasRAW
        )
    }
    
    func batchSaveHashCache(items: [(localIdentifier: String, sha1Hash: String, fileSize: Int64, syncStatus: String)]) {
        hashRepo.batchSaveHashCache(items: items)
    }
    
    func getHashCache(localIdentifier: String) -> HashCacheRecord? {
        hashRepo.getHashCache(localIdentifier: localIdentifier)
    }
    
    func updateHashCacheServerStatus(localIdentifier: String, isOnServer: Bool, syncStatus: String = "checked") {
        hashRepo.updateHashCacheServerStatus(localIdentifier: localIdentifier, isOnServer: isOnServer)
    }
    
    func updateMultiResourceHashCacheServerStatus(
        localIdentifier: String,
        primaryOnServer: Bool,
        rawOnServer: Bool
    ) {
        hashRepo.updateMultiResourceHashCacheServerStatus(
            localIdentifier: localIdentifier,
            primaryOnServer: primaryOnServer,
            rawOnServer: rawOnServer
        )
    }
    
    func batchUpdateHashCacheServerStatus(results: [(String, Bool)]) {
        hashRepo.batchUpdateHashCacheServerStatus(results: results)
    }
    
    func getAssetsOnServerAsync(completion: @escaping (Set<String>) -> Void) {
        hashRepo.getAssetsOnServerAsync(completion: completion)
    }
    
    func getAllSyncStatusAsync(completion: @escaping ([String: PhotoSyncStatus]) -> Void) {
        connection.dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([:]) }
                return
            }
            
            // Build uploaded resource types map
            var uploadedResourceTypes: [String: Set<String>] = [:]
            let uploadedDetailSql = "SELECT asset_id, resource_type FROM uploaded_assets;"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.connection.db, uploadedDetailSql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let assetIdCString = sqlite3_column_text(statement, 0),
                       let resourceTypeCString = sqlite3_column_text(statement, 1) {
                        let assetId = String(cString: assetIdCString)
                        let resourceType = String(cString: resourceTypeCString)
                        if uploadedResourceTypes[assetId] == nil {
                            uploadedResourceTypes[assetId] = []
                        }
                        uploadedResourceTypes[assetId]?.insert(resourceType)
                    }
                }
            }
            sqlite3_finalize(statement)
            
            let hasServerCache = self.serverRepo.hasServerCacheInternal()
            
            self.hashRepo.getAllSyncStatusAsync(
                uploadedResourceTypes: uploadedResourceTypes,
                hasServerCache: hasServerCache,
                completion: completion
            )
        }
    }
    
    func getAssetsNeedingHashAsync(allIdentifiers: [String], completion: @escaping ([String]) -> Void) {
        hashRepo.getAssetsNeedingHashAsync(allIdentifiers: allIdentifiers, completion: completion)
    }
    
    func getHashesNeedingCheckAsync(completion: @escaping ([(String, String)]) -> Void) {
        hashRepo.getHashesNeedingCheckAsync(completion: completion)
    }
    
    func getHashesNotOnServerAsync(completion: @escaping ([(String, String)]) -> Void) {
        hashRepo.getHashesNotOnServerAsync(completion: completion)
    }
    
    func getMultiResourceHashesNotFullyOnServerAsync(completion: @escaping ([MultiResourceHashRecord]) -> Void) {
        hashRepo.getMultiResourceHashesNotFullyOnServerAsync(completion: completion)
    }
    
    func getHashCacheStatsAsync(completion: @escaping (Int, Int, Int) -> Void) {
        hashRepo.getHashCacheStatsAsync(completion: completion)
    }
    
    func clearHashCache() {
        hashRepo.clearHashCache()
    }
    
    func deleteHashCacheRecord(localIdentifier: String) {
        hashRepo.deleteHashCacheRecord(localIdentifier: localIdentifier)
    }
    
    func batchDeleteHashCacheRecords(localIdentifiers: [String]) {
        hashRepo.batchDeleteHashCacheRecords(localIdentifiers: localIdentifiers)
    }
    
    // MARK: - Server Assets Cache Management
    
    func saveServerAssets(_ assets: [ServerAssetRecord], syncType: String = "full") {
        serverRepo.saveServerAssets(assets, syncType: syncType)
    }
    
    func deleteServerAssets(_ immichIds: [String]) {
        serverRepo.deleteServerAssets(immichIds)
    }
    
    func isAssetOnServer(checksum: String) -> Bool {
        serverRepo.isAssetOnServer(checksum: checksum)
    }
    
    func getServerAssetByChecksum(_ checksum: String) -> ServerAssetRecord? {
        serverRepo.getServerAssetByChecksum(checksum)
    }
    
    func getServerAssetsCacheCount() -> Int {
        serverRepo.getServerAssetsCacheCount()
    }
    
    func clearServerAssetsCache() {
        serverRepo.clearServerAssetsCache()
    }
    
    func saveSyncMetadata(lastSyncTime: Date, syncType: String, userId: String, totalAssets: Int) {
        serverRepo.saveSyncMetadata(lastSyncTime: lastSyncTime, syncType: syncType, userId: userId, totalAssets: totalAssets)
    }
    
    func getSyncMetadata() -> SyncMetadata? {
        serverRepo.getSyncMetadata()
    }
    
    // MARK: - Favorite Sync Management
    
    func getUploadedAssetsFavoriteStatus() -> [UploadedAssetFavoriteInfo] {
        favoriteRepo.getUploadedAssetsFavoriteStatus()
    }
    
    func updateAssetFavoriteStatus(localIdentifier: String, isFavorite: Bool) {
        favoriteRepo.updateAssetFavoriteStatus(localIdentifier: localIdentifier, isFavorite: isFavorite)
    }
    
    func batchUpdateAssetFavoriteStatus(updates: [(localIdentifier: String, isFavorite: Bool)]) {
        favoriteRepo.batchUpdateAssetFavoriteStatus(updates: updates)
    }
    
    func getImmichId(for localIdentifier: String) -> String? {
        favoriteRepo.getImmichId(for: localIdentifier)
    }
}
