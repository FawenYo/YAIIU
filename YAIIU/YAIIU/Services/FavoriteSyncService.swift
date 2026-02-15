import Foundation
import Photos

/// Service responsible for synchronizing favorite status between the Photos library and Immich server.
/// Detects changes in local favorite status and updates the server accordingly.
class FavoriteSyncService {
    static let shared = FavoriteSyncService()
    
    private let settingsManager = SettingsManager()
    private var isSyncing = false
    
    private init() {}
    
    /// Checks for favorite status changes and syncs them to the server.
    /// Should be called when the photo library is refreshed or the app becomes active.
    func syncFavoriteChanges() async {
        guard !isSyncing else {
            logDebug("Favorite sync already in progress, skipping", category: .sync)
            return
        }
        
        guard settingsManager.isLoggedIn else {
            logDebug("Not logged in, skipping favorite sync", category: .sync)
            return
        }
        
        isSyncing = true
        defer { isSyncing = false }
        
        logInfo("Starting favorite status sync", category: .sync)
        
        do {
            let changes = try await detectFavoriteChanges()
            
            if changes.isEmpty {
                logDebug("No favorite status changes detected", category: .sync)
                return
            }
            
            logInfo("Detected \(changes.count) favorite status changes", category: .sync)
            
            // Group changes by new favorite status for batch updates
            let toFavorite = changes.filter { $0.newFavorite }.map { $0.immichId }
            let toUnfavorite = changes.filter { !$0.newFavorite }.map { $0.immichId }
            
            // Update server and local database
            if !toFavorite.isEmpty {
                try await updateServerFavorites(assetIds: toFavorite, isFavorite: true)
                updateLocalFavoriteStatus(changes: changes.filter { $0.newFavorite })
            }
            
            if !toUnfavorite.isEmpty {
                try await updateServerFavorites(assetIds: toUnfavorite, isFavorite: false)
                updateLocalFavoriteStatus(changes: changes.filter { !$0.newFavorite })
            }
            
            logInfo("Favorite sync completed: \(toFavorite.count) favorited, \(toUnfavorite.count) unfavorited", category: .sync)
            
        } catch {
            logError("Favorite sync failed: \(error.localizedDescription)", category: .sync)
        }
    }
    
    /// Represents a detected change in favorite status.
    struct FavoriteChange {
        let localIdentifier: String
        let immichId: String
        let newFavorite: Bool
    }
    
    /// Detects assets whose favorite status has changed since last sync.
    private func detectFavoriteChanges() async throws -> [FavoriteChange] {
        let uploadedAssets = DatabaseManager.shared.getUploadedAssetsFavoriteStatus()
        
        guard !uploadedAssets.isEmpty else {
            return []
        }
        
        // Fetch current favorite status from Photos library
        let localIdentifiers = uploadedAssets.map { $0.localIdentifier }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        
        // Build a map of current favorite status
        var currentFavorites: [String: Bool] = [:]
        fetchResult.enumerateObjects { asset, _, _ in
            currentFavorites[asset.localIdentifier] = asset.isFavorite
        }
        
        // Find changes
        var changes: [FavoriteChange] = []
        for asset in uploadedAssets {
            guard let currentFavorite = currentFavorites[asset.localIdentifier] else {
                // Asset no longer exists in Photos library
                continue
            }
            
            if currentFavorite != asset.storedFavorite {
                changes.append(FavoriteChange(
                    localIdentifier: asset.localIdentifier,
                    immichId: asset.immichId,
                    newFavorite: currentFavorite
                ))
            }
        }
        
        return changes
    }
    
    /// Updates favorite status on the Immich server.
    private func updateServerFavorites(assetIds: [String], isFavorite: Bool) async throws {
        try await ImmichAPIService.shared.updateAssetsFavorite(
            assetIds: assetIds,
            isFavorite: isFavorite,
            serverURL: settingsManager.activeServerURL,
            apiKey: settingsManager.apiKey
        )
    }
    
    /// Updates local database with new favorite status.
    private func updateLocalFavoriteStatus(changes: [FavoriteChange]) {
        let updates = changes.map { ($0.localIdentifier, $0.newFavorite) }
        DatabaseManager.shared.batchUpdateAssetFavoriteStatus(updates: updates)
    }
}
