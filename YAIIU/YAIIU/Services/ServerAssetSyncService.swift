import Foundation

// MARK: - Sync Progress

struct SyncProgress {
    let phase: SyncPhase
    let fetchedCount: Int
    let message: String
    
    enum SyncPhase {
        case connecting
        case fetchingUserInfo
        case fetchingPartners
        case fetchingAssets
        case processingAssets
        case savingToDatabase
    }
}

class ServerAssetSyncService {
    
    // MARK: - Checksum Conversion
    
    /// Converts a Base64-encoded checksum to lowercase hexadecimal string.
    /// Immich server returns checksums in Base64 format, but iOS app calculates SHA1 in hex format.
    /// This conversion is required for proper matching between local and server assets.
    private func convertBase64ToHex(_ base64String: String) -> String? {
        guard let data = Data(base64Encoded: base64String) else {
            return nil
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }
    
    static let shared = ServerAssetSyncService()
    
    private let apiService = ImmichAPIService.shared
    private let dbManager = DatabaseManager.shared
    
    private var isSyncing = false
    private let syncQueue = DispatchQueue(label: "com.yaiiu.serverassetsync", qos: .userInitiated)
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Synchronize server assets with progress reporting.
    /// - Parameters:
    ///   - serverURL: The Immich server URL
    ///   - apiKey: The API key for authentication
    ///   - forceFullSync: Force a full sync instead of delta sync
    ///   - progressHandler: Called periodically with sync progress updates
    ///   - completion: Called when sync completes or fails
    func syncServerAssets(
        serverURL: String,
        apiKey: String,
        forceFullSync: Bool = false,
        progressHandler: ((SyncProgress) -> Void)? = nil,
        completion: @escaping (Result<SyncResult, Error>) -> Void
    ) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else {
                await MainActor.run {
                    completion(.failure(SyncError.syncFailed(reason: "Service deallocated")))
                }
                return
            }
            
            let shouldProceed = self.syncQueue.sync { () -> Bool in
                guard !self.isSyncing else {
                    logWarning("Sync already in progress, skipping", category: .sync)
                    return false
                }
                self.isSyncing = true
                return true
            }
            
            guard shouldProceed else {
                await MainActor.run {
                    completion(.failure(SyncError.syncInProgress))
                }
                return
            }
            
            defer {
                self.syncQueue.sync { self.isSyncing = false }
            }
            
            do {
                let result = try await self.performSync(
                    serverURL: serverURL,
                    apiKey: apiKey,
                    forceFullSync: forceFullSync,
                    progressHandler: progressHandler
                )
                
                await MainActor.run {
                    completion(.success(result))
                }
            } catch {
                logError("Sync failed: \(error.localizedDescription)", category: .sync)
                
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }
    
    func checkAssetExistsLocally(checksum: String) -> Bool {
        return dbManager.isAssetOnServer(checksum: checksum)
    }
    
    func getLastSyncInfo() -> SyncMetadata? {
        return dbManager.getSyncMetadata()
    }
    
    func clearCache() {
        dbManager.clearServerAssetsCache()
        logInfo("Server assets cache cleared", category: .sync)
    }
    
    // MARK: - Private Methods
    
    private func reportProgress(_ progress: SyncProgress, handler: ((SyncProgress) -> Void)?) {
        guard let handler = handler else { return }
        DispatchQueue.main.async {
            handler(progress)
        }
    }
    
    private func performSync(
        serverURL: String,
        apiKey: String,
        forceFullSync: Bool,
        progressHandler: ((SyncProgress) -> Void)?
    ) async throws -> SyncResult {
        logInfo("Starting server assets sync (forceFullSync: \(forceFullSync))", category: .sync)
        
        reportProgress(SyncProgress(phase: .connecting, fetchedCount: 0, message: ""), handler: progressHandler)
        
        reportProgress(SyncProgress(phase: .fetchingUserInfo, fetchedCount: 0, message: ""), handler: progressHandler)
        let userInfo = try await apiService.getCurrentUser(serverURL: serverURL, apiKey: apiKey)
        let userId = userInfo.id
        
        reportProgress(SyncProgress(phase: .fetchingPartners, fetchedCount: 0, message: ""), handler: progressHandler)
        let partnerIds = await fetchPartnerIds(serverURL: serverURL, apiKey: apiKey)
        let allUserIds = [userId] + partnerIds
        logDebug("All user IDs for sync: \(allUserIds)", category: .sync)
        
        let syncMetadata = dbManager.getSyncMetadata()
        let shouldUseDeltaSync = !forceFullSync && syncMetadata?.lastSyncTime != nil
        
        var syncResult: SyncResult
        
        if shouldUseDeltaSync, let lastSyncTime = syncMetadata?.lastSyncTime {
            logInfo("Attempting delta sync from \(lastSyncTime)", category: .sync)
            syncResult = try await performDeltaSync(
                userIds: allUserIds,
                lastSyncTime: lastSyncTime,
                serverURL: serverURL,
                apiKey: apiKey,
                progressHandler: progressHandler
            )
            
            if syncResult.needsFullSync {
                logInfo("Delta sync requires full sync, performing full sync", category: .sync)
                syncResult = try await performFullSync(
                    userId: userId,
                    serverURL: serverURL,
                    apiKey: apiKey,
                    progressHandler: progressHandler
                )
            }
        } else {
            logInfo("Performing full sync", category: .sync)
            syncResult = try await performFullSync(
                userId: userId,
                serverURL: serverURL,
                apiKey: apiKey,
                progressHandler: progressHandler
            )
        }
        
        reportProgress(SyncProgress(phase: .savingToDatabase, fetchedCount: syncResult.totalAssets, message: ""), handler: progressHandler)
        
        dbManager.saveSyncMetadata(
            lastSyncTime: Date(),
            syncType: syncResult.syncType,
            userId: userId,
            totalAssets: syncResult.totalAssets
        )
        
        logInfo("Sync completed: type=\(syncResult.syncType), total=\(syncResult.totalAssets), upserted=\(syncResult.upsertedCount), deleted=\(syncResult.deletedCount)", category: .sync)
        
        return syncResult
    }
    
    private func fetchPartnerIds(serverURL: String, apiKey: String) async -> [String] {
        do {
            let partners = try await apiService.fetchPartners(serverURL: serverURL, apiKey: apiKey)
            let partnerIds = partners.map { $0.id }
            logDebug("Fetched \(partnerIds.count) partner IDs: \(partnerIds)", category: .sync)
            return partnerIds
        } catch {
            logWarning("Failed to fetch partners, proceeding without partner IDs: \(error.localizedDescription)", category: .sync)
            return []
        }
    }
    
    private func performFullSync(
        userId: String,
        serverURL: String,
        apiKey: String,
        progressHandler: ((SyncProgress) -> Void)?
    ) async throws -> SyncResult {
        var allAssets: [ServerAsset] = []
        var lastId: String? = nil
        let chunkSize = 10000
        let updatedUntil = Date()
        
        logInfo("Starting full sync for user \(userId)", category: .sync)
        
        reportProgress(SyncProgress(phase: .fetchingAssets, fetchedCount: 0, message: ""), handler: progressHandler)
        
        while true {
            let assets = try await apiService.fetchFullSync(
                userId: userId,
                limit: chunkSize,
                lastId: lastId,
                updatedUntil: updatedUntil,
                serverURL: serverURL,
                apiKey: apiKey
            )
            
            logDebug("Fetched \(assets.count) assets (lastId: \(lastId ?? "nil"))", category: .sync)
            allAssets.append(contentsOf: assets)
            
            reportProgress(
                SyncProgress(phase: .fetchingAssets, fetchedCount: allAssets.count, message: ""),
                handler: progressHandler
            )
            
            if assets.count < chunkSize {
                break
            }
            
            lastId = assets.last?.id
        }
        
        logInfo("Full sync fetched \(allAssets.count) total assets", category: .sync)
        
        reportProgress(
            SyncProgress(phase: .processingAssets, fetchedCount: allAssets.count, message: ""),
            handler: progressHandler
        )
        
        // Convert Base64 checksums to hex format for matching with locally calculated SHA1 hashes
        let serverAssetRecords = allAssets.compactMap { asset -> ServerAssetRecord? in
            guard let hexChecksum = convertBase64ToHex(asset.checksum) else {
                logWarning("Failed to convert checksum for asset \(asset.id): \(asset.checksum)", category: .sync)
                return nil
            }
            return ServerAssetRecord(
                immichId: asset.id,
                checksum: hexChecksum,
                originalFilename: asset.originalFileName,
                assetType: asset.type,
                updatedAt: asset.updatedAt
            )
        }
        
        if serverAssetRecords.count != allAssets.count {
            logWarning("Skipped \(allAssets.count - serverAssetRecords.count) assets due to checksum conversion failure", category: .sync)
        }
        
        reportProgress(
            SyncProgress(phase: .savingToDatabase, fetchedCount: allAssets.count, message: ""),
            handler: progressHandler
        )
        
        dbManager.clearServerAssetsCache()
        dbManager.saveServerAssets(serverAssetRecords, syncType: "full")
        
        return SyncResult(
            syncType: "full",
            totalAssets: allAssets.count,
            upsertedCount: allAssets.count,
            deletedCount: 0,
            needsFullSync: false
        )
    }
    
    private func performDeltaSync(
        userIds: [String],
        lastSyncTime: Date,
        serverURL: String,
        apiKey: String,
        progressHandler: ((SyncProgress) -> Void)?
    ) async throws -> SyncResult {
        logInfo("Starting delta sync from \(lastSyncTime) for \(userIds.count) user(s)", category: .sync)
        
        reportProgress(SyncProgress(phase: .fetchingAssets, fetchedCount: 0, message: ""), handler: progressHandler)
        
        let deltaResponse = try await apiService.fetchDeltaSync(
            updatedAfter: lastSyncTime,
            userIds: userIds,
            serverURL: serverURL,
            apiKey: apiKey
        )
        
        if deltaResponse.needsFullSync {
            logInfo("Server requires full sync", category: .sync)
            return SyncResult(
                syncType: "delta",
                totalAssets: 0,
                upsertedCount: 0,
                deletedCount: 0,
                needsFullSync: true
            )
        }
        
        let totalChanges = deltaResponse.upserted.count + deltaResponse.deleted.count
        logInfo("Delta sync: upserted=\(deltaResponse.upserted.count), deleted=\(deltaResponse.deleted.count)", category: .sync)
        
        reportProgress(
            SyncProgress(phase: .processingAssets, fetchedCount: totalChanges, message: ""),
            handler: progressHandler
        )
        
        if !deltaResponse.upserted.isEmpty {
            // Convert Base64 checksums to hex format for matching with locally calculated SHA1 hashes
            let serverAssetRecords = deltaResponse.upserted.compactMap { asset -> ServerAssetRecord? in
                guard let hexChecksum = convertBase64ToHex(asset.checksum) else {
                    logWarning("Failed to convert checksum for asset \(asset.id): \(asset.checksum)", category: .sync)
                    return nil
                }
                return ServerAssetRecord(
                    immichId: asset.id,
                    checksum: hexChecksum,
                    originalFilename: asset.originalFileName,
                    assetType: asset.type,
                    updatedAt: asset.updatedAt
                )
            }
            
            if serverAssetRecords.count != deltaResponse.upserted.count {
                logWarning("Delta sync: skipped \(deltaResponse.upserted.count - serverAssetRecords.count) assets due to checksum conversion failure", category: .sync)
            }
            
            dbManager.saveServerAssets(serverAssetRecords, syncType: "delta")
        }
        
        if !deltaResponse.deleted.isEmpty {
            dbManager.deleteServerAssets(deltaResponse.deleted)
        }
        
        let currentTotal = dbManager.getServerAssetsCacheCount()
        
        return SyncResult(
            syncType: "delta",
            totalAssets: currentTotal,
            upsertedCount: deltaResponse.upserted.count,
            deletedCount: deltaResponse.deleted.count,
            needsFullSync: false
        )
    }
}

// MARK: - Data Models

struct SyncResult {
    let syncType: String
    let totalAssets: Int
    let upsertedCount: Int
    let deletedCount: Int
    let needsFullSync: Bool
}

enum SyncError: LocalizedError {
    case syncInProgress
    case syncFailed(reason: String)
    
    var errorDescription: String? {
        switch self {
        case .syncInProgress:
            return "Sync already in progress"
        case .syncFailed(let reason):
            return "Sync failed: \(reason)"
        }
    }
}
