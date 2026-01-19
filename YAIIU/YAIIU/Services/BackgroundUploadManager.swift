import Foundation
import Photos
import SwiftUI

/// BackgroundUploadManager - Manages the iOS 26.1 background upload extension state
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
        let actualEnabled = PHPhotoLibrary.shared().uploadJobExtensionEnabled
        isEnabled = actualEnabled
        sharedSettings.backgroundUploadEnabled = actualEnabled
        updateStatistics()
    }
    
    // MARK: - Public Methods
    
    func enableBackgroundUpload() async throws {
        logInfo("Enabling background upload extension...", category: .upload)
        
        // Check photo library permission
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else {
            let error = BackgroundUploadError.photoLibraryNotAuthorized
            await MainActor.run {
                self.errorMessage = error.localizedDescription
            }
            logError("Photo library not authorized: \(status)", category: .upload)
            throw error
        }
        
        // Check if user is logged in
        guard sharedSettings.isLoggedIn else {
            let error = BackgroundUploadError.notLoggedIn
            await MainActor.run {
                self.errorMessage = error.localizedDescription
            }
            logError("Not logged in", category: .upload)
            throw error
        }
        
        // Enable the extension
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
    
    func toggleBackgroundUpload() async throws {
        if isEnabled {
            try await disableBackgroundUpload()
        } else {
            try await enableBackgroundUpload()
        }
    }
    
    func checkExtensionStatus() {
        let library = PHPhotoLibrary.shared()
        let currentStatus = library.uploadJobExtensionEnabled
        
        if currentStatus != isEnabled {
            isEnabled = currentStatus
            sharedSettings.backgroundUploadEnabled = currentStatus
        }
        
        updateStatistics()
    }
    
    func updateStatistics() {
        // Perform database operations on background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let uploaded = self.database.getUploadedCount()
            let pending = self.database.getPendingJobs().count

            // Update published properties on main thread
            DispatchQueue.main.async {
                self.uploadedCount = uploaded
                self.pendingCount = pending
            }
        }
    }
    
    func syncSettings(serverURL: String, apiKey: String, internalServerURL: String? = nil, ssid: String? = nil) {
        sharedSettings.syncFromMainApp(
            serverURL: serverURL,
            apiKey: apiKey,
            isLoggedIn: true,
            internalServerURL: internalServerURL,
            ssid: ssid
        )
    }
    
    func handleLogout() async {
        if isEnabled {
            try? await disableBackgroundUpload()
        }
        
        sharedSettings.clearAll()
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
