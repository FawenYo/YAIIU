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

enum TimezoneGeocodingError: Error {
    case timeout
    case failed
}

class UploadManager: ObservableObject {
    @Published var uploadQueue: [UploadItem] = []
    @Published var isUploading: Bool = false
    @Published var uploadedCount: Int = 0
    
    private let photoLibraryManager = PhotoLibraryManager()
    private var uploadTask: Task<Void, Never>?
    private var isPaused: Bool = false
    
    private let uploadConcurrency = 2
    
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
        
        await withTaskGroup(of: (UploadItem, Bool).self) { group in
            var activeCount = 0
            var index = 0
            let itemsToUpload = uploadQueue.filter { $0.status != .completed }
            
            while index < itemsToUpload.count || activeCount > 0 {
                if isPaused {
                    logInfo("Upload paused by user", category: .upload)
                    group.cancelAll()
                    break
                }
                
                while activeCount < uploadConcurrency && index < itemsToUpload.count {
                    if isPaused { break }
                    
                    let item = itemsToUpload[index]
                    index += 1
                    
                    if item.status == .completed { continue }
                    
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
        let createdAt = item.asset.creationDate ?? Date()
        let modifiedAt = item.asset.modificationDate ?? Date()
        let timezone = await getTimezone(for: item.asset)
        
        for (index, resource) in resources.enumerated() {
            let resourceType = getResourceType(for: resource)
            let filename = photoLibraryManager.getFilename(for: resource)
            let mimeType = photoLibraryManager.getMimeType(for: resource)
            let deviceAssetId = "\(item.localIdentifier)-\(resourceType)-\(filename)"
            
            let useFileExport = photoLibraryManager.shouldUseFileExport(for: resource)
            var uploadedFileSize: Int64 = 0
            
            let response: UploadResponse
            
            if useFileExport {
                let fileURL = try await photoLibraryManager.exportResourceToFile(for: resource)
                defer {
                    try? FileManager.default.removeItem(at: fileURL)
                }
                
                enum FileAttributeError: Error { case missingSize }
                let fileAttrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                guard let fileSize = fileAttrs[.size] as? Int64 else {
                    logError("Could not determine file size for \(fileURL.path)", category: .upload)
                    throw FileAttributeError.missingSize
                }
                uploadedFileSize = fileSize
                
                response = try await ImmichAPIService.shared.uploadAssetFromFile(
                    fileURL: fileURL,
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
                    let baseProgress = Double(index) / Double(totalResources)
                    let resourceProgress = progress / Double(totalResources)
                    item.progress = baseProgress + resourceProgress
                }
            } else {
                let fileData = try await photoLibraryManager.getResourceData(for: resource)
                uploadedFileSize = Int64(fileData.count)
                
                response = try await ImmichAPIService.shared.uploadAsset(
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
                    let baseProgress = Double(index) / Double(totalResources)
                    let resourceProgress = progress / Double(totalResources)
                    item.progress = baseProgress + resourceProgress
                }
            }
            
            DatabaseManager.shared.recordUploadedAsset(
                localIdentifier: item.localIdentifier,
                resourceType: resourceType,
                filename: filename,
                immichId: response.id,
                fileSize: uploadedFileSize,
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
    
    // MARK: - Timezone
    
    private func getTimezone(for asset: PHAsset) async -> TimeZone {
        guard let location = asset.location else {
            return TimeZone.current
        }
        
        do {
            return try await withThrowingTaskGroup(of: TimeZone.self) { group in
                group.addTask {
                    let geocoder = CLGeocoder()
                    let placemarks = try await geocoder.reverseGeocodeLocation(location)
                    guard let tz = placemarks.first?.timeZone else {
                        throw TimezoneGeocodingError.failed
                    }
                    return tz
                }
                
                group.addTask {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    throw TimezoneGeocodingError.timeout
                }
                
                guard let result = try await group.next() else {
                    return TimeZone.current
                }
                group.cancelAll()
                return result
            }
        } catch {
            logDebug("Failed to get timezone from location, falling back to current. Error: \(error.localizedDescription)", category: .upload)
            return TimeZone.current
        }
    }
}
