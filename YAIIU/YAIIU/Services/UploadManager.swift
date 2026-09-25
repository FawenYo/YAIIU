import CoreLocation
import Foundation
import Photos
import UIKit
import SwiftUI

enum UploadStatus: String {
    case pending = "pending"
    case uploading = "uploading"
    case processing = "processing"
    case completed = "completed"
    case failed = "failed"

    var description: String {
        return rawValue
    }
}

@MainActor
class UploadItem: Identifiable, ObservableObject {
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
        case .processing:
            return L10n.UploadStatus.processing
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
        case .processing:
            return .orange
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
private struct UploadPreparation: @unchecked Sendable {
    let resources: [PHAssetResource]
    let isFavorite: Bool
    let createdAt: Date
    let modifiedAt: Date
    let timezone: TimeZone
    let iCloudId: String?
    let latitude: Double?
    let longitude: Double?
}
private struct PreparedUploadQueue: @unchecked Sendable {
    let entries: [(asset: PHAsset, filename: String, hasRAW: Bool, resourceCount: Int)]
    let skippedCount: Int
}



private class ResponseTracker {
    private let lock = NSLock()
    private var completedCount = 0
    private var isFinished = false
    private let totalCount: Int
    private let onAllCompleted: () -> Void
    private let onError: (Error) -> Void

    init(totalCount: Int, onAllCompleted: @escaping () -> Void, onError: @escaping (Error) -> Void) {
        self.totalCount = totalCount
        self.onAllCompleted = onAllCompleted
        self.onError = onError
    }

    func markCompleted() {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinished else { return }

        completedCount += 1
        if completedCount == totalCount {
            isFinished = true
            onAllCompleted()
        }
    }

    func markFailed(error: Error) {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinished else { return }

        isFinished = true
        onError(error)
    }
}

@MainActor
class UploadManager: ObservableObject {
    @Published var uploadQueue: [UploadItem] = []
    @Published var isUploading: Bool = false
    @Published var uploadedCount: Int = 0
    
    private let photoLibraryManager = PhotoLibraryManager.shared
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
        logInfo("Preparing \(assets.count) assets for upload queue", category: .upload)
        let queuedIdentifiers = Set(
            uploadQueue.lazy
                .filter { $0.status != .completed }
                .map(\.localIdentifier)
        )

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var entries = [(asset: PHAsset, filename: String, hasRAW: Bool, resourceCount: Int)]()
            var skippedCount = 0

            for asset in assets {
                guard !queuedIdentifiers.contains(asset.localIdentifier) else {
                    skippedCount += 1
                    continue
                }
                let resources = PhotoLibraryManager.shared.getUploadableResources(for: asset)
                let hasRAW = resources.contains { PhotoLibraryManager.shared.isRAWResource($0) }
                let filename = resources.first.map { $0.resolvedFilename() } ?? "unknown"
                entries.append((asset, filename, hasRAW, resources.count))
            }
            let prepared = PreparedUploadQueue(entries: entries, skippedCount: skippedCount)

            await MainActor.run {
                var duplicateCount = 0
                for entry in prepared.entries {
                    guard !self.uploadQueue.contains(where: {
                        $0.localIdentifier == entry.asset.localIdentifier && $0.status != .completed
                    }) else {
                        duplicateCount += 1
                        continue
                    }

                    let item = UploadItem(asset: entry.asset, filename: entry.filename, hasRAW: entry.hasRAW)
                    item.totalResources = entry.resourceCount
                    // Thumbnails are loaded by visible UploadItemRow instances.
                    // Keeping them out of queue construction avoids retaining a
                    // decoded UIImage for every queued upload.
                    self.uploadQueue.append(item)
                }

                logInfo(
                    "Upload queue updated: added \(prepared.entries.count - duplicateCount), skipped \(prepared.skippedCount + duplicateCount), total \(self.uploadQueue.count)",
                    category: .upload
                )
                if !self.isUploading, prepared.entries.count > duplicateCount {
                    self.startUpload()
                }
            }
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
        setIdleTimerDisabled(true)
        
        uploadTask = Task {
            await processUploadQueueParallel()
        }
    }
    
    func pauseUpload() {
        logInfo("Upload paused", category: .upload)
        isPaused = true
        isUploading = false
        setIdleTimerDisabled(false)
    }
    
    func resumeUpload() {
        if !isUploading && !uploadQueue.filter({ $0.status == .pending || $0.status == .failed }).isEmpty {
            logInfo("Resuming upload", category: .upload)
            startUpload()
        }
    }
    
    private func processUploadQueueParallel() async {
        let settingsManager = SettingsManager()
        let serverURL = settingsManager.activeServerURL
        let apiKey = settingsManager.apiKey
        
        guard !serverURL.isEmpty && !apiKey.isEmpty else {
            logError("Cannot process upload queue: server URL or API key is empty", category: .upload)
            await MainActor.run {
                isUploading = false
                setIdleTimerDisabled(false)
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

                        // Status will be set to .completed by responseHandler after all responses received
                        await MainActor.run {
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
        if successCount > 0 {
            Task {
                guard !settingsManager.activeServerURL.isEmpty, !settingsManager.apiKey.isEmpty else { return }
                let serverSyncSucceeded = await withCheckedContinuation { continuation in
                    ServerAssetSyncService.shared.syncServerAssets(
                        serverURL: settingsManager.activeServerURL,
                        apiKey: settingsManager.apiKey
                    ) { result in
                        let succeeded: Bool
                        if case .success = result {
                            succeeded = true
                        } else {
                            succeeded = false
                        }
                        continuation.resume(returning: succeeded)
                    }
                }
                guard serverSyncSucceeded else { return }
                await AlbumSyncService.shared.syncIfEnabled()
            }
        }
        
        await MainActor.run {
            isUploading = false
            setIdleTimerDisabled(false)
            uploadQueue.removeAll { $0.status == .completed }
            // Preparations finishing while this run was active appended items
            // outside its snapshot; pick them up instead of leaving them pending.
            if !isPaused && uploadQueue.contains(where: { $0.status == .pending }) {
                logInfo("Queue received new items during upload; restarting processing", category: .upload)
                startUpload()
            }
        }
    }
    
    private func uploadItem(_ item: UploadItem, serverURL: String, apiKey: String) async throws {
        let asset = item.asset
        let localIdentifier = item.localIdentifier
        let metadata = await Task.detached(priority: .userInitiated) {
            let resources = PhotoLibraryManager.shared.getUploadableResources(for: asset)
            let timezone = await Self.getTimezone(for: asset)
            return UploadPreparation(
                resources: resources,
                isFavorite: asset.isFavorite,
                createdAt: asset.creationDate ?? Date(),
                modifiedAt: asset.modificationDate ?? Date(),
                timezone: timezone,
                iCloudId: Self.getCloudIdentifier(for: asset),
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude
            )
        }.value
        let resources = metadata.resources
        let totalResources = resources.count

        guard totalResources > 0 else {
            logWarning("No uploadable resources found for: \(item.filename)", category: .upload)
            return
        }

        logDebug("Uploading \(totalResources) resource(s) for: \(item.filename)", category: .upload)

        // Use continuation to wait for all responses
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let responseTracker = ResponseTracker(totalCount: totalResources) { [weak item] in
                Task { @MainActor in
                    item?.status = .completed
                }
                continuation.resume()
            } onError: { error in
                continuation.resume(throwing: error)
            }

            Task.detached(priority: .userInitiated) { [weak item] in
                guard let item else {
                    enum UploadError: Error { case itemDeallocated }
                    responseTracker.markFailed(error: UploadError.itemDeallocated)
                    return
                }
                for (index, resource) in resources.enumerated() {
                    let resourceType = Self.getResourceType(for: resource)
                    let filename = PhotoLibraryManager.shared.getFilename(for: resource)
                    let mimeType = PhotoLibraryManager.shared.getMimeType(for: resource)
                    let deviceAssetId = "\(item.localIdentifier)-\(resourceType)-\(filename)"
                    let currentIndex = index
                    let isLastResource = (index + 1 == totalResources)

                    do {
                        _ = try await ImmichAPIService.shared.uploadResourceNonBlocking(
                            resource: resource,
                            filename: filename,
                            mimeType: mimeType,
                            deviceAssetId: deviceAssetId,
                            createdAt: metadata.createdAt,
                            modifiedAt: metadata.modifiedAt,
                            isFavorite: metadata.isFavorite,
                            serverURL: serverURL,
                            apiKey: apiKey,
                            timezone: metadata.timezone,
                            iCloudId: metadata.iCloudId,
                            latitude: metadata.latitude,
                            longitude: metadata.longitude
                        ) { progress in
                            let baseProgress = Double(currentIndex) / Double(totalResources)
                            let resourceProgress = progress / Double(totalResources)
                            Task { @MainActor in
                                item.progress = baseProgress + resourceProgress
                            }
                        } responseHandler: { result, uploadedFileSize in
                            switch result {
                            case .success(let response):
                                DatabaseManager.shared.recordUploadedAsset(
                                    localIdentifier: localIdentifier,
                                    resourceType: resourceType,
                                    filename: filename,
                                    immichId: response.id,
                                    fileSize: uploadedFileSize,
                                    isDuplicate: response.duplicate ?? false,
                                    isFavorite: metadata.isFavorite
                                )
                                responseTracker.markCompleted()
                            case .failure(let error):
                                responseTracker.markFailed(error: error)
                            }
                        }
                    } catch {
                        responseTracker.markFailed(error: error)
                        break
                    }

                    await MainActor.run {
                        item.resourcesUploaded[resourceType] = true
                        item.progress = Double(currentIndex + 1) / Double(totalResources)
                        if isLastResource { item.status = .processing }
                    }
                }
            }
        }
    }
    
    nonisolated private static func getResourceType(for resource: PHAssetResource) -> String {
        let uti = resource.uniformTypeIdentifier.lowercased()
        if ["raw-image", "dng", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2"].contains(where: uti.contains) {
            return "raw"
        }
        if resource.type == .alternatePhoto {
            return "raw"
        }
        if uti.contains("video") || uti.contains("movie") || uti.contains("mp4") || uti.contains("quicktime")
            || resource.type == .video || resource.type == .fullSizeVideo {
            return "video"
        }
        if resource.type == .photo || resource.type == .fullSizePhoto {
            if uti.contains("heic") || uti.contains("heif") { return "heic" }
            if uti.contains("png") { return "png" }
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
        setIdleTimerDisabled(false)
        uploadQueue.removeAll()
    }
    
    // MARK: - Idle Timer
    
    /// Prevent the screen from dimming while uploads are active.
    /// The system automatically re-enables the idle timer when the app terminates.
    private func setIdleTimerDisabled(_ disabled: Bool) {
        if Thread.isMainThread {
            UIApplication.shared.isIdleTimerDisabled = disabled
        } else {
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = disabled
            }
        }
    }
    
    // MARK: - iCloud Identifier
    
    nonisolated private static func getCloudIdentifier(for asset: PHAsset) -> String? {
        guard #available(iOS 16, *) else { return nil }
        let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [asset.localIdentifier])
        guard let result = mappings[asset.localIdentifier] else { return nil }
        switch result {
        case .success(let cloudIdentifier):
            let cloudId = cloudIdentifier.stringValue
            return cloudId.hasSuffix(":") ? nil : cloudId
        case .failure:
            return nil
        }
    }

    nonisolated private static func getTimezone(for asset: PHAsset) async -> TimeZone {
        guard let location = asset.location else { return TimeZone.current }
        do {
            return try await withThrowingTaskGroup(of: TimeZone.self) { group in
                group.addTask {
                    let geocoder = CLGeocoder()
                    let placemarks = try await geocoder.reverseGeocodeLocation(location)
                    guard let timezone = placemarks.first?.timeZone else {
                        throw TimezoneGeocodingError.failed
                    }
                    return timezone
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    throw TimezoneGeocodingError.timeout
                }
                guard let result = try await group.next() else { return TimeZone.current }
                group.cancelAll()
                return result
            }
        } catch {
            return TimeZone.current
        }
    }
}
