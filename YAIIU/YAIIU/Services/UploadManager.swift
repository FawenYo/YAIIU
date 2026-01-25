import CoreLocation
import Foundation
import Photos
import UIKit
import SwiftUI

enum UploadStatus: String {
    case pending = "pending"
    case uploading = "uploading"
    case completed = "completed"
    case failed = "failed"
    
    var description: String {
        return rawValue
    }
}

class UploadItem: Identifiable, ObservableObject {
    let id = UUID()
    let asset: PHAsset
    let localIdentifier: String
    let filename: String
    let isVideo: Bool
    let hasRAW: Bool
    
    @Published var status: UploadStatus = .pending
    @Published var progress: Double = 0.0
    @Published var thumbnail: UIImage?
    @Published var errorMessage: String?
    
    var resourcesUploaded: [String: Bool] = [:]
    var totalResources: Int = 0
    
    init(asset: PHAsset, filename: String, hasRAW: Bool) {
        self.asset = asset
        self.localIdentifier = asset.localIdentifier
        self.filename = filename
        self.isVideo = asset.mediaType == .video
        self.hasRAW = hasRAW
    }
    
    var statusText: String {
        switch status {
        case .pending:
            return L10n.UploadStatus.pending
        case .uploading:
            return L10n.UploadStatus.uploading(Int(progress * 100))
        case .completed:
            return L10n.UploadStatus.completed
        case .failed:
            return errorMessage ?? L10n.UploadStatus.failed
        }
    }
    
    var statusColor: Color {
        switch status {
        case .pending:
            return .gray
        case .uploading:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }
}

/// Errors that can occur during timezone geocoding
enum TimezoneGeocodingError: Error, LocalizedError {
    case geocodingFailed(underlying: Error)
    case rateLimited
    case noPlacemarkFound
    
    var errorDescription: String? {
        switch self {
        case .geocodingFailed(let underlying):
            return "Geocoding failed: \(underlying.localizedDescription)"
        case .rateLimited:
            return "Geocoding rate limited"
        case .noPlacemarkFound:
            return "No placemark found for location"
        }
    }
}

class UploadManager: ObservableObject {
    @Published var uploadQueue: [UploadItem] = []
    @Published var isUploading: Bool = false
    @Published var uploadedCount: Int = 0
    
    private let photoLibraryManager = PhotoLibraryManager()
    private var uploadTask: Task<Void, Never>?
    private var isPaused: Bool = false
    
    /// Number of concurrent uploads
    private let uploadConcurrency = 2
    
    /// Shared CLGeocoder instance for timezone lookups (reused across all uploads)
    private let geocoder = CLGeocoder()
    
    var completedCount: Int {
        uploadQueue.filter { $0.status == .completed }.count
    }
    
    var totalCount: Int {
        uploadQueue.count
    }
    
    var overallProgress: Double {
        guard totalCount > 0 else { return 0 }
        let completed = Double(completedCount)
        let uploadingItems = uploadQueue.filter { $0.status == .uploading }
        let uploadingProgress = uploadingItems.reduce(0.0) { $0 + $1.progress } / Double(max(1, totalCount))
        return (completed / Double(totalCount)) + uploadingProgress
    }
    
    init() {
        logInfo("UploadManager initialized", category: .upload)
        loadUploadedCountAsync()
    }
    
    private func loadUploadedCountAsync() {
        DatabaseManager.shared.getUploadedCountAsync { [weak self] count in
            self?.uploadedCount = count
            logDebug("Loaded uploaded count: \(count)", category: .upload)
        }
    }
    
    func isAssetUploaded(_ localIdentifier: String) -> Bool {
        return DatabaseManager.shared.isAnyResourceUploaded(localIdentifier: localIdentifier)
    }
    
    func uploadAssets(_ assets: [PHAsset]) {
        logInfo("Adding \(assets.count) assets to upload queue", category: .upload)
        var addedCount = 0
        var skippedCount = 0
        
        for asset in assets {
            if uploadQueue.contains(where: { $0.localIdentifier == asset.localIdentifier && $0.status != .completed }) {
                skippedCount += 1
                continue
            }
            
            let resources = photoLibraryManager.getUploadableResources(for: asset)
            let hasRAW = photoLibraryManager.hasRAWResource(asset)
            let filename = resources.first?.originalFilename ?? "unknown"
            
            let item = UploadItem(asset: asset, filename: filename, hasRAW: hasRAW)
            item.totalResources = resources.count
            
            // Use ThumbnailCache for thumbnail loading
            ThumbnailCache.shared.getThumbnail(for: asset) { [weak item] image in
                DispatchQueue.main.async {
                    item?.thumbnail = image
                }
            }
            
            uploadQueue.append(item)
            addedCount += 1
        }
        
        logInfo("Upload queue updated: added \(addedCount), skipped \(skippedCount), total \(uploadQueue.count)", category: .upload)
        
        if !isUploading {
            startUpload()
        }
    }
    
    func startUpload() {
        guard !isUploading else {
            logDebug("Upload already in progress, ignoring startUpload call", category: .upload)
            return
        }
        
        logInfo("Starting upload process", category: .upload)
        isUploading = true
        isPaused = false
        
        uploadTask = Task {
            await processUploadQueueParallel()
        }
    }
    
    func pauseUpload() {
        logInfo("Upload paused", category: .upload)
        isPaused = true
        isUploading = false
    }
    
    func resumeUpload() {
        if !isUploading && !uploadQueue.filter({ $0.status == .pending || $0.status == .failed }).isEmpty {
            logInfo("Resuming upload", category: .upload)
            startUpload()
        }
    }
    
    /// Process upload queue with parallel uploads for better performance
    private func processUploadQueueParallel() async {
        let settingsManager = SettingsManager()
        let serverURL = settingsManager.serverURL
        let apiKey = settingsManager.apiKey
        
        guard !serverURL.isEmpty && !apiKey.isEmpty else {
            logError("Cannot process upload queue: server URL or API key is empty", category: .upload)
            await MainActor.run {
                isUploading = false
            }
            return
        }
        
        let pendingItems = uploadQueue.filter { $0.status != .completed }
        logInfo("Processing upload queue: \(pendingItems.count) items pending", category: .upload)
        
        var successCount = 0
        var failCount = 0
        
        // Process uploads in parallel with controlled concurrency
        await withTaskGroup(of: (UploadItem, Bool).self) { group in
            var activeCount = 0
            var index = 0
            let itemsToUpload = uploadQueue.filter { $0.status != .completed }
            
            while index < itemsToUpload.count || activeCount > 0 {
                // Check if paused
                if isPaused {
                    logInfo("Upload paused by user", category: .upload)
                    group.cancelAll()
                    break
                }
                
                // Add tasks up to concurrency limit
                while activeCount < uploadConcurrency && index < itemsToUpload.count {
                    if isPaused { break }
                    
                    let item = itemsToUpload[index]
                    index += 1
                    
                    // Skip already completed items
                    if item.status == .completed {
                        continue
                    }
                    
                    activeCount += 1
                    
                    await MainActor.run {
                        item.status = .uploading
                        item.progress = 0
                    }
                    
                    logDebug("Starting upload for: \(item.filename)", category: .upload)
                    
                    group.addTask {
                        do {
                            try await self.uploadItem(item, serverURL: serverURL, apiKey: apiKey)
                            return (item, true)
                        } catch {
                            logError("Upload failed for \(item.filename): \(error.localizedDescription)", category: .upload)
                            await MainActor.run {
                                item.status = .failed
                                item.errorMessage = error.localizedDescription
                            }
                            return (item, false)
                        }
                    }
                }
                
                // Wait for one task to complete
                if let (item, success) = await group.next() {
                    activeCount -= 1
                    
                    if success {
                        successCount += 1
                        logInfo("Upload successful: \(item.filename)", category: .upload)
                        
                        await MainActor.run {
                            item.status = .completed
                            item.progress = 1.0
                        }
                        
                        DatabaseManager.shared.getUploadedCountAsync { [weak self] count in
                            self?.uploadedCount = count
                        }
                    } else {
                        failCount += 1
                    }
                }
            }
        }
        
        logInfo("Upload queue processing complete: \(successCount) succeeded, \(failCount) failed", category: .upload)
        
        await MainActor.run {
            isUploading = false
            uploadQueue.removeAll { $0.status == .completed }
        }
    }
    
    private func uploadItem(_ item: UploadItem, serverURL: String, apiKey: String) async throws {
        let resources = photoLibraryManager.getUploadableResources(for: item.asset)
        let totalResources = resources.count
        
        guard totalResources > 0 else {
            logWarning("No uploadable resources found for: \(item.filename)", category: .upload)
            return
        }
        
        logDebug("Uploading \(totalResources) resource(s) for: \(item.filename)", category: .upload)
        
        let isFavorite = item.asset.isFavorite
        
        for (index, resource) in resources.enumerated() {
            let resourceType = getResourceType(for: resource)
            let filename = photoLibraryManager.getFilename(for: resource)
            
            logDebug("Fetching resource data: \(filename) (type: \(resourceType))", category: .upload)
            let fileData = try await photoLibraryManager.getResourceData(for: resource)
            
            let mimeType = photoLibraryManager.getMimeType(for: resource)
            let deviceAssetId = "\(item.localIdentifier)-\(resourceType)-\(filename)"
            
            let createdAt = item.asset.creationDate ?? Date()
            let modifiedAt = item.asset.modificationDate ?? Date()
            let timezone = await getTimezone(for: item.asset)
            
            let response = try await ImmichAPIService.shared.uploadAsset(
                fileData: fileData,
                filename: filename,
                mimeType: mimeType,
                deviceAssetId: deviceAssetId,
                createdAt: createdAt,
                modifiedAt: modifiedAt,
                isFavorite: isFavorite,
                serverURL: serverURL,
                apiKey: apiKey,
                timezone: timezone
            ) { progress in
                // progressHandler is already called on main queue by ImmichAPIService
                let baseProgress = Double(index) / Double(totalResources)
                let resourceProgress = progress / Double(totalResources)
                item.progress = baseProgress + resourceProgress
            }
            
            DatabaseManager.shared.recordUploadedAsset(
                localIdentifier: item.localIdentifier,
                resourceType: resourceType,
                filename: filename,
                immichId: response.id,
                fileSize: Int64(fileData.count),
                isDuplicate: response.duplicate ?? false,
                isFavorite: isFavorite
            )
            
            logDebug("Resource uploaded: \(filename) -> immichId: \(response.id)", category: .upload)
            
            await MainActor.run {
                item.resourcesUploaded[resourceType] = true
                item.progress = Double(index + 1) / Double(totalResources)
            }
        }
    }
    
    private func getResourceType(for resource: PHAssetResource) -> String {
        let uti = resource.uniformTypeIdentifier.lowercased()
        
        if uti.contains("raw-image") ||
           uti.contains("dng") ||
           uti.contains("arw") ||
           uti.contains("cr2") ||
           uti.contains("cr3") ||
           uti.contains("nef") ||
           uti.contains("raf") ||
           uti.contains("orf") ||
           uti.contains("rw2") {
            return "raw"
        }
        
        if resource.type == .alternatePhoto {
            return "raw"
        }
        
        if uti.contains("video") || uti.contains("movie") ||
           uti.contains("mp4") || uti.contains("quicktime") ||
           resource.type == .video || resource.type == .fullSizeVideo {
            return "video"
        }
        
        if resource.type == .photo || resource.type == .fullSizePhoto {
            if uti.contains("heic") || uti.contains("heif") {
                return "heic"
            } else if uti.contains("jpeg") || uti.contains("jpg") {
                return "jpeg"
            } else if uti.contains("png") {
                return "png"
            }
            return "jpeg"
        }
        
        return "primary"
    }
    
    func retryFailedItems() {
        let failedCount = uploadQueue.filter { $0.status == .failed }.count
        logInfo("Retrying \(failedCount) failed items", category: .upload)
        
        for item in uploadQueue where item.status == .failed {
            item.status = .pending
            item.progress = 0
            item.errorMessage = nil
        }
        
        if !isUploading {
            startUpload()
        }
    }
    
    func clearCompletedItems() {
        let completedCount = uploadQueue.filter { $0.status == .completed }.count
        logDebug("Clearing \(completedCount) completed items", category: .upload)
        uploadQueue.removeAll { $0.status == .completed }
    }
    
    func clearAllItems() {
        logInfo("Clearing all upload items", category: .upload)
        uploadTask?.cancel()
        isUploading = false
        uploadQueue.removeAll()
    }
    
    // MARK: - Timezone Helper
    
    /// Attempts to determine the timezone for an asset based on its GPS location.
    /// Uses shared CLGeocoder instance for accurate timezone including daylight saving time.
    /// Throws errors for rate limiting or other failures to allow caller to implement retry strategy.
    /// - Parameter asset: The PHAsset to get timezone for
    /// - Returns: TimeZone from GPS location
    /// - Throws: TimezoneGeocodingError if geocoding fails
    private func getTimezoneFromLocation(for asset: PHAsset) async throws -> TimeZone {
        guard let location = asset.location else {
            return TimeZone.current
        }
        
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let timezone = placemarks.first?.timeZone else {
                throw TimezoneGeocodingError.noPlacemarkFound
            }
            return timezone
        } catch let error as CLError where error.code == .network {
            // Network errors might indicate rate limiting
            throw TimezoneGeocodingError.rateLimited
        } catch let error as TimezoneGeocodingError {
            throw error
        } catch {
            throw TimezoneGeocodingError.geocodingFailed(underlying: error)
        }
    }
    
    /// Attempts to determine the timezone for an asset based on its GPS location.
    /// Falls back to device's current timezone if geocoding fails.
    /// - Parameter asset: The PHAsset to get timezone for
    /// - Returns: TimeZone from GPS location or device's current timezone as fallback
    private func getTimezone(for asset: PHAsset) async -> TimeZone {
        do {
            return try await getTimezoneFromLocation(for: asset)
        } catch TimezoneGeocodingError.rateLimited {
            logWarning("Geocoding rate limited, using device timezone", category: .upload)
            return TimeZone.current
        } catch {
            logDebug("Failed to get timezone from location: \(error.localizedDescription)", category: .upload)
            return TimeZone.current
        }
    }
}
