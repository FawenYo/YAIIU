import Foundation
import Photos
import SwiftUI

/// BackgroundUploadManager - Manages the iOS 26.1 background upload extension state
/// This service is used in the main app to enable or disable background upload functionality
@available(iOS 26.1, *)
class BackgroundUploadManager: ObservableObject {
    static let shared = BackgroundUploadManager()
    
    /// Whether background upload is enabled
    @Published var isEnabled: Bool = false
    
    /// Error message
    @Published var errorMessage: String?
    
    /// Upload statistics
    @Published var uploadedCount: Int = 0
    @Published var pendingCount: Int = 0
    
    private let sharedSettings = SharedSettings.shared
    private let database = BackgroundUploadDatabase.shared
    
    private init() {
        // Read from actual system API to ensure consistency with the real state
        // This prevents mismatch when the app is first installed or SQLite is imported
        let actualEnabled = PHPhotoLibrary.shared().uploadJobExtensionEnabled
        isEnabled = actualEnabled
        // Sync the actual state to SharedSettings
        sharedSettings.backgroundUploadEnabled = actualEnabled
        updateStatistics()
    }
    
    // MARK: - Public Methods
    
    /// Enable background upload extension
    /// Requires full photo library access permission first
    func enableBackgroundUpload() async throws {
        logInfo("Enabling background upload extension...", category: .upload)
        
        // 1. Check photo library permission
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else {
            let error = BackgroundUploadError.photoLibraryNotAuthorized
            await MainActor.run {
                self.errorMessage = error.localizedDescription
            }
            logError("Photo library not authorized: \(status)", category: .upload)
            throw error
        }
        
        // 2. Check if user is logged in
        guard sharedSettings.isLoggedIn else {
            let error = BackgroundUploadError.notLoggedIn
            await MainActor.run {
                self.errorMessage = error.localizedDescription
            }
            logError("Not logged in", category: .upload)
            throw error
        }
        
        // 3. Enable the extension
        let library = PHPhotoLibrary.shared()
        
        do {
            try library.setUploadJobExtensionEnabled(true)
            
            await MainActor.run {
                self.isEnabled = true
                self.sharedSettings.backgroundUploadEnabled = true
                self.errorMessage = nil
            }
            
            logInfo("Background upload extension enabled successfully", category: .upload)
            
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
            }
            logError("Failed to enable background upload extension: \(error.localizedDescription)", category: .upload)
            throw error
        }
    }
    
    /// Disable background upload extension
    func disableBackgroundUpload() async throws {
        logInfo("Disabling background upload extension...", category: .upload)
        
        let library = PHPhotoLibrary.shared()
        
        do {
            try library.setUploadJobExtensionEnabled(false)
            
            await MainActor.run {
                self.isEnabled = false
                self.sharedSettings.backgroundUploadEnabled = false
                self.errorMessage = nil
            }
            
            logInfo("Background upload extension disabled successfully", category: .upload)
            
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
            }
            logError("Failed to disable background upload extension: \(error.localizedDescription)", category: .upload)
            throw error
        }
    }
    
    /// Toggle background upload state
    func toggleBackgroundUpload() async throws {
        if isEnabled {
            try await disableBackgroundUpload()
        } else {
            try await enableBackgroundUpload()
        }
    }
    
    /// Check and update extension status
    func checkExtensionStatus() {
        let library = PHPhotoLibrary.shared()
        let currentStatus = library.uploadJobExtensionEnabled
        
        if currentStatus != isEnabled {
            isEnabled = currentStatus
            sharedSettings.backgroundUploadEnabled = currentStatus
        }
        
        updateStatistics()
    }
    
    /// Update statistics
    func updateStatistics() {
        uploadedCount = database.getUploadedCount()
        pendingCount = database.getPendingJobs().count
    }
    
    /// Sync settings to SharedSettings
    /// Call this method when user logs in
    func syncSettings(serverURL: String, apiKey: String) {
        sharedSettings.syncFromMainApp(
            serverURL: serverURL,
            apiKey: apiKey,
            isLoggedIn: true
        )
    }
    
    /// Handle logout cleanup
    func handleLogout() async {
        // Disable background upload first
        if isEnabled {
            try? await disableBackgroundUpload()
        }
        
        // Clear shared settings
        sharedSettings.clearAll()
    }
    
    /// Read background upload logs
    func readBackgroundLogs() -> String? {
        let appGroupIdentifier = "group.com.fawenyo.yaiiu"
        
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return nil
        }
        
        let logFileURL = containerURL.appendingPathComponent("background_upload.log")
        
        return try? String(contentsOf: logFileURL, encoding: .utf8)
    }
    
    /// Clear background upload logs
    func clearBackgroundLogs() {
        let appGroupIdentifier = "group.com.fawenyo.yaiiu"
        
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return
        }
        
        let logFileURL = containerURL.appendingPathComponent("background_upload.log")
        try? FileManager.default.removeItem(at: logFileURL)
    }
}

// MARK: - Error Types

enum BackgroundUploadError: LocalizedError {
    case photoLibraryNotAuthorized
    case notLoggedIn
    case extensionNotAvailable
    case unknown(String)
    
    var errorDescription: String? {
        switch self {
        case .photoLibraryNotAuthorized:
            return L10n.BackgroundUpload.errorPhotoLibraryNotAuthorized
        case .notLoggedIn:
            return L10n.BackgroundUpload.errorNotLoggedIn
        case .extensionNotAvailable:
            return L10n.BackgroundUpload.errorExtensionNotAvailable
        case .unknown(let message):
            return message
        }
    }
}
