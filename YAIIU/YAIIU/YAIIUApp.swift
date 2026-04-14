import SwiftUI

@main
struct YAIIUApp: App {
    @StateObject private var settingsManager = SettingsManager()
    @StateObject private var uploadManager = UploadManager()
    @StateObject private var migrationManager = MigrationManager()
    
    init() {
        TemporaryFileCleanup.purgeStaleFiles()
    }
    
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

// MARK: - Temporary File Cleanup

/// Removes leftover temporary files that may accumulate when the app is
/// terminated mid-upload (e.g. user force-quits, system kills the process).
enum TemporaryFileCleanup {

    /// Fire-and-forget cleanup dispatched at low QoS so it never
    /// contends with app launch or upload work.
    static func purgeStaleFiles() {
        DispatchQueue.global(qos: .utility).async {
            cleanDirectory(at: FileManager.default.temporaryDirectory)

            if let groupContainer = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.com.fawenyo.yaiiu"
            ) {
                let groupTmp = groupContainer.appendingPathComponent("tmp", isDirectory: true)
                cleanDirectory(at: groupTmp)
            }
        }
    }

    private static let staleThreshold: TimeInterval = 3600

    private static let legacyUploadExtensions: Set<String> = ["multipart"]

    private static func cleanDirectory(at url: URL) {
        let fm = FileManager.default

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            )
        } catch {
            logDebug("Temp directory not readable at \(url.lastPathComponent): \(error.localizedDescription)", category: .app)
            return
        }

        let cutoff = Date().addingTimeInterval(-staleThreshold)
        var removedCount = 0

        for entry in entries {
            let isLegacyUploadFile = legacyUploadExtensions.contains(entry.pathExtension)

            if !isLegacyUploadFile {
                guard let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modDate = values.contentModificationDate,
                      modDate < cutoff else {
                    continue
                }
            }

            do {
                try fm.removeItem(at: entry)
                removedCount += 1
            } catch {
                logDebug(
                    "Skipped temp item \(entry.lastPathComponent): \(error.localizedDescription)",
                    category: .app
                )
            }
        }

        if removedCount > 0 {
            logInfo(
                "Purged \(removedCount) stale temporary file(s) from \(url.lastPathComponent)",
                category: .app
            )
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
            let hasUploadedAssets = await Task.detached {
                UploadRecordRepository().getUploadedCount() > 0
            }.value
            needsCloudIdSync = hasUploadedAssets
        }
        
        if needsCloudIdSync {
            logInfo("Migration: triggering iCloud ID sync (upgrade from \(lastVersion ?? "unknown") to \(currentVersion))", category: .app)
            await triggerCloudIdSync(settingsManager: settingsManager)
        }
        
        // Update version if sync completed, or if it was never needed.
        // If it failed, the version is not updated, allowing a retry on next launch.
        if SharedSettings.shared.cloudIdSyncCompleted || !needsCloudIdSync {
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
