import Foundation

// MARK: - Sync Progress

struct SyncProgress {
    let phase: SyncPhase
    let fetchedCount: Int
    let message: String

    enum SyncPhase {
        case connecting
        case fetchingUserInfo
        case fetchingAssets
        case processingAssets
        case savingToDatabase
    }
}

class ServerAssetSyncService {

    // MARK: - Checksum Conversion

    /// Converts a Base64-encoded checksum to lowercase hexadecimal string.
    /// Immich server returns checksums in Base64 format, but iOS app calculates SHA1 in hex format.
    private func convertBase64ToHex(_ base64String: String) -> String? {
        guard let data = Data(base64Encoded: base64String) else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    static let shared = ServerAssetSyncService()

    private let apiService = ImmichAPIService.shared
    private let dbManager = DatabaseManager.shared

    private var isSyncing = false
    private let syncQueue = DispatchQueue(label: "com.yaiiu.serverassetsync", qos: .userInitiated)

    private init() {}

    // MARK: - Public Methods

    func syncServerAssets(
        serverURL: String,
        apiKey: String,
        forceFullSync: Bool = false,
        progressHandler: ((SyncProgress) -> Void)? = nil,
        completion: @escaping (Result<SyncResult, Error>) -> Void
    ) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else {
                await MainActor.run { completion(.failure(SyncError.syncFailed(reason: "Service deallocated"))) }
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
                await MainActor.run { completion(.failure(SyncError.syncInProgress)) }
                return
            }

            defer { self.syncQueue.sync { self.isSyncing = false } }

            do {
                let result = try await self.performSync(
                    serverURL: serverURL,
                    apiKey: apiKey,
                    forceFullSync: forceFullSync,
                    progressHandler: progressHandler
                )
                await MainActor.run { completion(.success(result)) }
            } catch {
                logError("Sync failed: \(error.localizedDescription)", category: .sync)
                await MainActor.run { completion(.failure(error)) }
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
        DispatchQueue.main.async { handler(progress) }
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

        let syncMetadata = dbManager.getSyncMetadata()
        let lastAck = forceFullSync ? nil : syncMetadata?.lastAck

        logInfo("Stream sync: lastAck=\(lastAck ?? "nil") (incremental: \(lastAck != nil))", category: .sync)

        reportProgress(SyncProgress(phase: .fetchingAssets, fetchedCount: 0, message: ""), handler: progressHandler)

        // Fetch iCloudId map first (independent stream call)
        let iCloudIdMap = await fetchICloudIdMap(serverURL: serverURL, apiKey: apiKey)
        logDebug("Fetched \(iCloudIdMap.count) iCloudId mappings from metadata stream", category: .sync)

        // Fetch assets via stream (sends ack first if incremental)
        let streamResult = try await apiService.fetchAssetStream(
            serverURL: serverURL,
            apiKey: apiKey,
            lastAck: lastAck
        )

        let allAssets = streamResult.assets
        let newAck = streamResult.lastAck

        logInfo("Stream returned \(allAssets.count) assets, lastAck=\(newAck ?? "nil")", category: .sync)

        reportProgress(
            SyncProgress(phase: .processingAssets, fetchedCount: allAssets.count, message: ""),
            handler: progressHandler
        )

        let activeAssets = allAssets.filter { !$0.isDeleted }
        let deletedIds = allAssets.filter { $0.isDeleted }.map { $0.id }

        let serverAssetRecords = activeAssets.compactMap { asset -> ServerAssetRecord? in
            guard let hexChecksum = convertBase64ToHex(asset.checksum) else {
                logWarning("Failed to convert checksum for asset \(asset.id): \(asset.checksum)", category: .sync)
                return nil
            }
            return ServerAssetRecord(
                immichId: asset.id,
                checksum: hexChecksum,
                originalFilename: asset.originalFileName,
                assetType: asset.type,
                updatedAt: asset.fileCreatedAt,
                iCloudId: iCloudIdMap[asset.id],
                ownerId: asset.ownerId
            )
        }

        reportProgress(
            SyncProgress(phase: .savingToDatabase, fetchedCount: allAssets.count, message: ""),
            handler: progressHandler
        )

        let syncType: String
        if lastAck == nil {
            // Full stream — replace entire cache
            dbManager.clearServerAssetsCache()
            syncType = "full"
        } else {
            syncType = "delta"
        }

        if !serverAssetRecords.isEmpty {
            dbManager.saveServerAssets(serverAssetRecords, syncType: syncType)
        }

        if !deletedIds.isEmpty {
            dbManager.deleteServerAssets(deletedIds)
            logInfo("Deleted \(deletedIds.count) assets from cache", category: .sync)
        }

        dbManager.saveSyncMetadata(
            lastSyncTime: Date(),
            syncType: syncType,
            userId: userId,
            totalAssets: dbManager.getServerAssetsCacheCount(),
            lastAck: newAck ?? lastAck
        )

        dbManager.backfillImmichIdsFromServerCache()

        let total = dbManager.getServerAssetsCacheCount()
        logInfo("Sync completed: type=\(syncType), total=\(total), upserted=\(serverAssetRecords.count), deleted=\(deletedIds.count)", category: .sync)

        return SyncResult(
            syncType: syncType,
            totalAssets: total,
            upsertedCount: serverAssetRecords.count,
            deletedCount: deletedIds.count,
            needsFullSync: false
        )
    }

    private func fetchICloudIdMap(serverURL: String, apiKey: String) async -> [String: String] {
        do {
            return try await apiService.fetchAssetMetadataStream(serverURL: serverURL, apiKey: apiKey)
        } catch {
            logWarning("Failed to fetch iCloudId map from metadata stream: \(error.localizedDescription)", category: .sync)
            return [:]
        }
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
