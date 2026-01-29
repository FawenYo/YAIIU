import Foundation
import Photos

/// Service for syncing iCloud IDs to Immich server for already uploaded assets.
/// Uses PHPhotoLibrary.cloudIdentifierMappings to retrieve iCloud IDs.
final class CloudIdSyncService {
    static let shared = CloudIdSyncService()
    
    private let uploadRecordRepo = UploadRecordRepository()
    private let batchSize = 500
    
    private init() {}
    
    // MARK: - Public Interface
    
    /// Synchronizes iCloud IDs for all uploaded assets to the Immich server.
    /// - Parameters:
    ///   - serverURL: The Immich server URL.
    ///   - apiKey: The API key for authentication.
    ///   - progressHandler: Optional callback for progress updates (0.0 to 1.0).
    /// - Returns: The number of assets successfully updated.
    @available(iOS 16, *)
    func syncCloudIds(
        serverURL: String,
        apiKey: String,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws -> Int {
        logInfo("Starting iCloud ID sync", category: .sync)
        
        progressHandler?(0.0, "Fetching uploaded assets...")
        
        // Get all uploaded asset mappings
        let mappings = await withCheckedContinuation { continuation in
            uploadRecordRepo.getAllUploadedAssetMappingsAsync { result in
                continuation.resume(returning: result)
            }
        }
        
        guard !mappings.isEmpty else {
            logInfo("No uploaded assets found for iCloud ID sync", category: .sync)
            return 0
        }
        
        logInfo("Found \(mappings.count) uploaded assets for iCloud ID sync", category: .sync)
        progressHandler?(0.05, "Found \(mappings.count) assets")
        
        // Collect local identifiers
        let localIdentifiers = mappings.map { $0.localIdentifier }
        let localToImmich = Dictionary(mappings, uniquingKeysWith: { first, _ in first })
        
        // Get iCloud IDs in batches to avoid memory pressure
        var allCloudIds: [String: String] = [:]
        let totalBatches = (localIdentifiers.count + batchSize - 1) / batchSize
        
        for batchIndex in 0..<totalBatches {
            let start = batchIndex * batchSize
            let end = min(start + batchSize, localIdentifiers.count)
            let batchIds = Array(localIdentifiers[start..<end])
            
            let batchProgress = 0.05 + (Double(batchIndex) / Double(totalBatches)) * 0.45
            progressHandler?(batchProgress, "Fetching iCloud IDs (\(batchIndex + 1)/\(totalBatches))...")
            
            let cloudIds = getCloudIdsForAssets(localIdentifiers: batchIds)
            allCloudIds.merge(cloudIds) { _, new in new }
        }
        
        logInfo("Retrieved \(allCloudIds.count) valid iCloud IDs", category: .sync)
        
        guard !allCloudIds.isEmpty else {
            logInfo("No valid iCloud IDs found", category: .sync)
            return 0
        }
        
        progressHandler?(0.5, "Preparing metadata updates...")
        
        // Build metadata update items
        var updateItems: [MetadataUpdateItem] = []
        for (localId, cloudId) in allCloudIds {
            guard let immichId = localToImmich[localId] else { continue }
            
            let metadata = MobileAppMetadata(
                iCloudId: cloudId,
                createdAt: nil,
                adjustmentTime: nil,
                latitude: nil,
                longitude: nil
            )
            let item = MetadataUpdateItem(
                assetId: immichId,
                key: RemoteAssetMetadataItem.mobileAppKey,
                value: metadata
            )
            updateItems.append(item)
        }
        
        guard !updateItems.isEmpty else {
            logInfo("No metadata updates to send", category: .sync)
            return 0
        }
        
        logInfo("Sending \(updateItems.count) iCloud ID updates to server", category: .sync)
        
        // Send updates in batches
        var totalUpdated = 0
        let updateBatches = (updateItems.count + batchSize - 1) / batchSize
        
        for batchIndex in 0..<updateBatches {
            let start = batchIndex * batchSize
            let end = min(start + batchSize, updateItems.count)
            let batch = Array(updateItems[start..<end])
            
            let uploadProgress = 0.5 + (Double(batchIndex) / Double(updateBatches)) * 0.48
            progressHandler?(uploadProgress, "Uploading iCloud IDs (\(batchIndex + 1)/\(updateBatches))...")
            
            do {
                try await ImmichAPIService.shared.updateBulkAssetMetadata(
                    items: batch,
                    serverURL: serverURL,
                    apiKey: apiKey
                )
                totalUpdated += batch.count
            } catch {
                logError("Failed to update batch \(batchIndex + 1): \(error.localizedDescription)", category: .sync)
                // Continue with other batches even if one fails
            }
        }
        
        progressHandler?(1.0, "Completed")
        logInfo("iCloud ID sync completed: \(totalUpdated) assets updated", category: .sync)
        
        return totalUpdated
    }
    
    // MARK: - Private Methods
    
    /// Retrieves iCloud identifiers for the given local asset identifiers.
    @available(iOS 16, *)
    private func getCloudIdsForAssets(localIdentifiers: [String]) -> [String: String] {
        var result: [String: String] = [:]
        
        let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: localIdentifiers)
        
        for (localId, mapping) in mappings {
            switch mapping {
            case .success(let cloudIdentifier):
                let cloudId = cloudIdentifier.stringValue
                // Validate cloud ID format: should be "GUID:ID:HASH", not "GUID:ID:"
                if !cloudId.hasSuffix(":") {
                    result[localId] = cloudId
                } else {
                    logDebug("Skipping incomplete cloud ID for \(localId)", category: .sync)
                }
            case .failure(let error):
                logDebug("Failed to get cloud ID for \(localId): \(error.localizedDescription)", category: .sync)
            }
        }
        
        return result
    }
}
