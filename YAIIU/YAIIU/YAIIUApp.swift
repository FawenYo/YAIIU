import SwiftUI

@main
struct YAIIUApp: App {
    @StateObject private var settingsManager = SettingsManager()
    @StateObject private var uploadManager = UploadManager()
    @StateObject private var migrationManager = MigrationManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settingsManager)
                .environmentObject(uploadManager)
                .environmentObject(migrationManager)
                .task {
                    await migrationManager.performMigrationIfNeeded(settingsManager: settingsManager)
                }
        }
    }
}

/// Handles app version migrations and one-time setup tasks.
@MainActor
final class MigrationManager: ObservableObject {
    @Published var isSyncingCloudIds = false
    @Published var cloudIdSyncProgress: Double = 0
    @Published var cloudIdSyncStatus: String = ""
    @Published var cloudIdSyncResult: CloudIdSyncResult?
    
    enum CloudIdSyncResult: Equatable {
        case success(Int)
        case error(String)
    }
    
    /// Checks and performs migrations based on version upgrade.
    func performMigrationIfNeeded(settingsManager: SettingsManager) async {
        let currentVersion = BuildInfo.version
        let lastVersion = SharedSettings.shared.lastAppVersion
        
        // Skip if user is not logged in
        guard settingsManager.isLoggedIn else {
            SharedSettings.shared.lastAppVersion = currentVersion
            return
        }
        
        // If sync is already completed, just update version and exit.
        if SharedSettings.shared.cloudIdSyncCompleted {
            SharedSettings.shared.lastAppVersion = currentVersion
            return
        }
        
        // Trigger iCloud ID sync on upgrade from versions before 0.1.0
        // or when lastVersion is nil (fresh install with imported data)
        let needsCloudIdSync: Bool
        if let last = lastVersion {
            needsCloudIdSync = isVersionLessThan(last, "0.1.0")
        } else {
            // No previous version recorded - check if there are uploaded assets
            let hasUploadedAssets = UploadRecordRepository().getUploadedCount() > 0
            needsCloudIdSync = hasUploadedAssets
        }
        
        if needsCloudIdSync {
            logInfo("Migration: triggering iCloud ID sync (upgrade from \(lastVersion ?? "unknown") to \(currentVersion))", category: .app)
            await triggerCloudIdSync(settingsManager: settingsManager)
        }
        
        // Only update the version if the sync has now completed.
        if SharedSettings.shared.cloudIdSyncCompleted {
            SharedSettings.shared.lastAppVersion = currentVersion
        }
    }
    
    /// Manually trigger iCloud ID sync.
    func triggerCloudIdSync(settingsManager: SettingsManager) async {
        guard #available(iOS 16, *) else {
            cloudIdSyncResult = .error("Requires iOS 16 or later")
            return
        }
        
        guard !isSyncingCloudIds else { return }
        
        let serverURL = settingsManager.activeServerURL
        let apiKey = settingsManager.apiKey
        
        guard !serverURL.isEmpty && !apiKey.isEmpty else {
            cloudIdSyncResult = .error("Server not configured")
            return
        }
        
        isSyncingCloudIds = true
        cloudIdSyncProgress = 0
        cloudIdSyncStatus = ""
        cloudIdSyncResult = nil
        
        do {
            let count = try await CloudIdSyncService.shared.syncCloudIds(
                serverURL: serverURL,
                apiKey: apiKey,
                progressHandler: { [weak self] (progress: Double, status: String) in
                    Task { @MainActor in
                        self?.cloudIdSyncProgress = progress
                        self?.cloudIdSyncStatus = status
                    }
                }
            )
            
            SharedSettings.shared.cloudIdSyncCompleted = true
            cloudIdSyncResult = .success(count)
            logInfo("iCloud ID sync completed: \(count) assets updated", category: .app)
        } catch {
            cloudIdSyncResult = .error(error.localizedDescription)
            logError("iCloud ID sync failed: \(error.localizedDescription)", category: .app)
        }
        
        isSyncingCloudIds = false
    }
    
    /// Simple semantic version comparison.
    private func isVersionLessThan(_ version: String, _ target: String) -> Bool {
        let v1 = version.split(separator: ".").compactMap { Int($0) }
        let v2 = target.split(separator: ".").compactMap { Int($0) }
        
        for i in 0..<max(v1.count, v2.count) {
            let a = i < v1.count ? v1[i] : 0
            let b = i < v2.count ? v2[i] : 0
            if a < b { return true }
            if a > b { return false }
        }
        return false
    }
}
