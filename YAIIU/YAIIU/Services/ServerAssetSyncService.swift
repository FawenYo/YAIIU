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

protocol ServerAssetSyncAPI {
    func getCurrentUser(serverURL: String, apiKey: String) async throws -> UserInfo
    func fetchAssetMetadataStream(serverURL: String, apiKey: String) async throws -> AssetMetadataStreamResult
    func fetchAssetStream(serverURL: String, apiKey: String) async throws -> AssetStreamResult
    func sendSyncAck(acks: [String], serverURL: String, apiKey: String) async throws
}

protocol ServerAssetSyncStore {
    func isAssetOnServer(checksum: String) -> Bool
    func getSyncMetadata() -> SyncMetadata?
    func clearServerAssetsCache() -> Bool
    func saveServerAssets(_ assets: [ServerAssetRecord], syncType: String) -> Bool
    func deleteServerAssets(_ immichIds: [String]) -> Bool
    func updateICloudIds(_ iCloudIdsByImmichId: [String: String]) -> Bool
    func clearICloudIds(for immichIds: Set<String>) -> Bool
    func saveSyncMetadata(lastSyncTime: Date, syncType: String, userId: String, serverURL: String, totalAssets: Int, lastAck: String?) -> Bool
    func getServerAssetsCacheCount() -> Int
    func backfillImmichIdsFromServerCache() -> Int
}

extension ImmichAPIService: ServerAssetSyncAPI {}
extension DatabaseManager: ServerAssetSyncStore {}

class ServerAssetSyncService {

    // MARK: - Checksum Conversion

    /// Converts a Base64-encoded checksum to lowercase hexadecimal string.
    /// Immich server returns checksums in Base64 format, but iOS app calculates SHA1 in hex format.
    private func convertBase64ToHex(_ base64String: String) -> String? {
        guard let data = Data(base64Encoded: base64String) else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    static let shared = ServerAssetSyncService()

    private let apiService: ServerAssetSyncAPI
    private let dbManager: ServerAssetSyncStore

    private var isSyncing = false
    private let syncQueue = DispatchQueue(label: "com.yaiiu.serverassetsync", qos: .userInitiated)

    init(
        apiService: ServerAssetSyncAPI = ImmichAPIService.shared,
        dbManager: ServerAssetSyncStore = DatabaseManager.shared
    ) {
        self.apiService = apiService
        self.dbManager = dbManager
    }

    private static func canonicalServerURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else {
            return trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        components.query = nil
        components.fragment = nil
        var normalizedPath = components.path
        while normalizedPath.count > 1 && normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        components.path = normalizedPath == "/" ? "" : normalizedPath
        return components.string ?? trimmed.lowercased()
    }

    private func settingsServerURL(serverURL: String) -> String {
        // The external URL identifies the configured server; the active URL may
        // switch between internal and external hosts as Wi-Fi changes.
        UserDefaults.standard.string(forKey: "immich_server_url") ?? serverURL
    }

    // MARK: - Public Methods

    func syncServerAssets(
        serverURL: String,
        apiKey: String,
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
                    progressHandler: progressHandler
                )
                await MainActor.run { completion(.success(result)) }
                if result.upsertedCount > 0 || result.backfilledCount > 0 {
                    Task { await AlbumSyncService.shared.syncIfEnabled() }
                }
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

    @discardableResult
    func clearCache() -> Bool {
        let cleared = dbManager.clearServerAssetsCache()
        if cleared {
            logInfo("Server assets cache cleared", category: .sync)
        } else {
            logError("Failed to clear server assets cache", category: .sync)
        }
        return cleared
    }

    // MARK: - Private Methods

    private func reportProgress(_ progress: SyncProgress, handler: ((SyncProgress) -> Void)?) {
        guard let handler = handler else { return }
        DispatchQueue.main.async { handler(progress) }
    }

    private func performSync(
        serverURL: String,
        apiKey: String,
        progressHandler: ((SyncProgress) -> Void)?,
        resetRetryRemaining: Bool = true
    ) async throws -> SyncResult {
        logInfo("Starting server assets sync", category: .sync)
        reportProgress(SyncProgress(phase: .connecting, fetchedCount: 0, message: ""), handler: progressHandler)
        reportProgress(SyncProgress(phase: .fetchingUserInfo, fetchedCount: 0, message: ""), handler: progressHandler)

        let userInfo = try await apiService.getCurrentUser(serverURL: serverURL, apiKey: apiKey)
        let userId = userInfo.id

        let syncMetadata = dbManager.getSyncMetadata()
        let normalizedServerURL = Self.canonicalServerURL(settingsServerURL(serverURL: serverURL))
        let cacheMatchesSession = syncMetadata?.userId == userId
            && (syncMetadata?.serverURL == nil
                || syncMetadata?.serverURL.map(Self.canonicalServerURL) == normalizedServerURL)
        let lastAck = cacheMatchesSession ? syncMetadata?.lastAck : nil

        reportProgress(SyncProgress(phase: .fetchingAssets, fetchedCount: 0, message: ""), handler: progressHandler)

        let metadataResult = try await apiService.fetchAssetMetadataStream(
            serverURL: serverURL,
            apiKey: apiKey
        )
        let streamResult = try await apiService.fetchAssetStream(
            serverURL: serverURL,
            apiKey: apiKey
        )

        let resetAcks = [metadataResult.resetAck, streamResult.resetAck].compactMap { $0 }
        if !resetAcks.isEmpty {
            guard resetRetryRemaining else {
                throw SyncError.repeatedServerReset
            }

            guard clearCache() else {
                throw SyncError.syncFailed(reason: "Failed to clear server cache before reset retry")
            }
            try await apiService.sendSyncAck(
                acks: Array(Set(resetAcks)).sorted(),
                serverURL: serverURL,
                apiKey: apiKey
            )
            return try await performSync(
                serverURL: serverURL,
                apiKey: apiKey,
                progressHandler: progressHandler,
                resetRetryRemaining: false
            )
        }

        let allAssets = streamResult.assets
        logInfo(
            "Streams returned assets=\(allAssets.count), metadataUpserts=\(metadataResult.iCloudIdUpserts.count), "
                + "metadataDeletes=\(metadataResult.iCloudIdDeletes.count)",
            category: .sync
        )

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
                iCloudId: metadataResult.iCloudIdUpserts[asset.id],
                ownerId: asset.ownerId
            )
        }

        reportProgress(
            SyncProgress(phase: .savingToDatabase, fetchedCount: allAssets.count, message: ""),
            handler: progressHandler
        )

        let syncType = lastAck == nil ? "full" : "delta"

        if syncType == "full", !clearCache() {
            throw SyncError.syncFailed(reason: "Failed to clear server cache before full sync")
        }

        if !serverAssetRecords.isEmpty,
           !dbManager.saveServerAssets(serverAssetRecords, syncType: syncType) {
            throw SyncError.syncFailed(reason: "Failed to persist server asset upserts")
        }

        if !deletedIds.isEmpty,
           !dbManager.deleteServerAssets(deletedIds) {
            throw SyncError.syncFailed(reason: "Failed to persist server asset deletions")
        }

        guard dbManager.updateICloudIds(metadataResult.iCloudIdUpserts) else {
            throw SyncError.syncFailed(reason: "Failed to persist iCloud ID updates")
        }
        guard dbManager.clearICloudIds(for: metadataResult.iCloudIdDeletes) else {
            throw SyncError.syncFailed(reason: "Failed to persist iCloud ID deletions")
        }

        let acks = Array(Set(streamResult.acks + metadataResult.acks)).sorted()
        let newAck = acks.last
        guard dbManager.saveSyncMetadata(
            lastSyncTime: Date(),
            syncType: syncType,
            userId: userId,
            serverURL: normalizedServerURL,
            totalAssets: dbManager.getServerAssetsCacheCount(),
            lastAck: newAck ?? lastAck
        ) else {
            throw SyncError.syncFailed(reason: "Failed to persist sync metadata")
        }

        if !acks.isEmpty {
            try await apiService.sendSyncAck(acks: acks, serverURL: serverURL, apiKey: apiKey)
        }

        let backfilledCount = dbManager.backfillImmichIdsFromServerCache()
        let total = dbManager.getServerAssetsCacheCount()
        logInfo(
            "Sync completed: type=\(syncType), total=\(total), assetUpserts=\(serverAssetRecords.count), "
                + "backfilled=\(backfilledCount), assetDeletes=\(deletedIds.count), metadataUpserts=\(metadataResult.iCloudIdUpserts.count), "
                + "metadataDeletes=\(metadataResult.iCloudIdDeletes.count), acks=\(acks.count)",
            category: .sync
        )

        return SyncResult(
            syncType: syncType,
            totalAssets: total,
            upsertedCount: serverAssetRecords.count,
            backfilledCount: backfilledCount,
            deletedCount: deletedIds.count,
            needsFullSync: false
        )
    }

}

// MARK: - Data Models

struct SyncResult {
    let syncType: String
    let totalAssets: Int
    let upsertedCount: Int
    let backfilledCount: Int
    let deletedCount: Int
    let needsFullSync: Bool
}


enum SyncError: LocalizedError {
    case syncInProgress
    case syncFailed(reason: String)
    case repeatedServerReset

    var errorDescription: String? {
        switch self {
        case .syncInProgress:
            return "Sync already in progress"
        case .syncFailed(let reason):
            return "Sync failed: \(reason)"
        case .repeatedServerReset:
            return "Sync failed: Server requested another reset after rebuilding the sync checkpoint"
        }
    }
}
