import Foundation
import Photos
import UIKit

class PhotoLibraryManager: ObservableObject {
    @Published var assets: [PHAsset] = []
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var loadedCount: Int = 0
    @Published private(set) var totalCount: Int = 0
    
    private var fetchResult: PHFetchResult<PHAsset>?
    private var loadingTask: Task<Void, Never>?
    
    /// Number of assets to load in the initial batch for immediate display
    private let initialBatchSize = 100
    
    /// Number of assets to load in each subsequent batch
    private let batchSize = 500
    
    init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authorizationStatus == .authorized || authorizationStatus == .limited {
            fetchAssets()
        }
    }
    
    func requestAuthorization() {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if currentStatus == .authorized || currentStatus == .limited {
            DispatchQueue.main.async {
                self.authorizationStatus = currentStatus
            }
            if assets.isEmpty {
                fetchAssets()
            }
            return
        }
        
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                self?.authorizationStatus = status
            }
            if status == .authorized || status == .limited {
                self?.fetchAssets()
            }
        }
    }
    
    func fetchAssets() {
        loadingTask?.cancel()
        
        loadingTask = Task { [weak self] in
            guard let self = self else { return }
            
            await MainActor.run {
                self.isLoading = true
                self.loadedCount = 0
            }
            
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            fetchOptions.includeHiddenAssets = false
            
            let result = PHAsset.fetchAssets(with: fetchOptions)
            let total = result.count
            
            await MainActor.run {
                self.fetchResult = result
                self.totalCount = total
            }
            
            guard total > 0 else {
                await MainActor.run {
                    self.assets = []
                    self.isLoading = false
                }
                return
            }
            
            // Load initial batch immediately for fast UI response
            let initialCount = min(self.initialBatchSize, total)
            var initialAssets: [PHAsset] = []
            initialAssets.reserveCapacity(initialCount)
            
            result.enumerateObjects(options: []) { asset, index, stop in
                if index >= initialCount {
                    stop.pointee = true
                    return
                }
                initialAssets.append(asset)
            }
            
            // Check for cancellation
            if Task.isCancelled { return }
            
            await MainActor.run {
                self.assets = initialAssets
                self.loadedCount = initialAssets.count
            }
            
            if initialCount >= total {
                await MainActor.run {
                    self.isLoading = false
                }
                await self.triggerFavoriteSync()
                return
            }
            
            // Continue loading remaining assets in batches
            var currentIndex = initialCount
            
            while currentIndex < total {
                if Task.isCancelled { return }
                
                let batchEnd = min(currentIndex + self.batchSize, total)
                var batchAssets: [PHAsset] = []
                batchAssets.reserveCapacity(batchEnd - currentIndex)
                
                let range = NSRange(location: currentIndex, length: batchEnd - currentIndex)
                guard let swiftRange = Range(range) else {
                    break
                }
                let indexSet = IndexSet(integersIn: swiftRange)
                
                result.enumerateObjects(at: indexSet, options: []) { asset, _, _ in
                    batchAssets.append(asset)
                }
                
                currentIndex = batchEnd
                
                if Task.isCancelled { return }
                
                await MainActor.run {
                    self.assets.append(contentsOf: batchAssets)
                    self.loadedCount = self.assets.count
                }
                
               await Task.yield()
            }
            
            await MainActor.run {
                self.isLoading = false
            }
            
            await self.triggerFavoriteSync()
        }
    }
    
    private func triggerFavoriteSync() async {
        await FavoriteSyncService.shared.syncFavoriteChanges()
    }
    
    func getAssetResources(for asset: PHAsset) -> [PHAssetResource] {
        return PHAssetResource.assetResources(for: asset)
    }
    
    func hasRAWResource(_ asset: PHAsset) -> Bool {
        let resources = getAssetResources(for: asset)
        return resources.contains { resource in
            let uti = resource.uniformTypeIdentifier.lowercased()
            return uti.contains("raw") || 
                   uti.contains("dng") || 
                   uti.contains("arw") || 
                   uti.contains("cr2") || 
                   uti.contains("cr3") ||
                   uti.contains("nef") ||
                   uti.contains("raf") ||
                   uti.contains("orf") ||
                   uti.contains("rw2")
        }
    }
    
    func getUploadableResources(for asset: PHAsset) -> [PHAssetResource] {
        let resources = getAssetResources(for: asset)
        
        var jpegResource: PHAssetResource?
        var rawResource: PHAssetResource?
        var videoResource: PHAssetResource?
        
        for resource in resources {
            let uti = resource.uniformTypeIdentifier.lowercased()
            
            let isRAW = uti.contains("raw-image") ||
                        uti.contains("dng") ||
                        uti.contains("arw") ||
                        uti.contains("cr2") ||
                        uti.contains("cr3") ||
                        uti.contains("nef") ||
                        uti.contains("raf") ||
                        uti.contains("orf") ||
                        uti.contains("rw2") ||
                        resource.type == .alternatePhoto
            
            let isVideo = resource.type == .video ||
                          resource.type == .fullSizeVideo ||
                          uti.contains("video") ||
                          uti.contains("movie")
            
            let isMainPhoto = (resource.type == .photo || resource.type == .fullSizePhoto) && !isRAW
            
            if isRAW {
                if rawResource == nil || resource.type == .fullSizePhoto {
                    rawResource = resource
                }
            } else if isVideo {
                if videoResource == nil || resource.type == .fullSizeVideo {
                    videoResource = resource
                }
            } else if isMainPhoto {
                if jpegResource == nil || resource.type == .fullSizePhoto {
                    jpegResource = resource
                }
            }
        }
        
        var uploadableResources: [PHAssetResource] = []
        
        if let jpeg = jpegResource {
            uploadableResources.append(jpeg)
        }
        
        if let raw = rawResource {
            uploadableResources.append(raw)
        }
        
        if let video = videoResource {
            uploadableResources.append(video)
        }
        
        if uploadableResources.isEmpty, let firstResource = resources.first {
            uploadableResources.append(firstResource)
        }
        
        return uploadableResources
    }
    
    func isRAWResource(_ resource: PHAssetResource) -> Bool {
        let uti = resource.uniformTypeIdentifier.lowercased()
        return uti.contains("raw-image") ||
               uti.contains("dng") ||
               uti.contains("arw") ||
               uti.contains("cr2") ||
               uti.contains("cr3") ||
               uti.contains("nef") ||
               uti.contains("raf") ||
               uti.contains("orf") ||
               uti.contains("rw2") ||
               resource.type == .alternatePhoto
    }
    
    func getResourceData(for resource: PHAssetResource, completion: @escaping (Result<Data, Error>) -> Void) {
        var data = Data()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        
        PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
            data.append(chunk)
        } completionHandler: { error in
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(data))
            }
        }
    }
    
    func getResourceData(for resource: PHAssetResource) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            getResourceData(for: resource) { result in
                switch result {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Exports a resource to a temporary file for memory-efficient large file handling.
    func exportResourceToFile(for resource: PHAssetResource) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let sanitizedFilename = resource.originalFilename.replacingOccurrences(of: "/", with: "_")
        let fileURL = tempDir.appendingPathComponent(UUID().uuidString + "_" + sanitizedFilename)
        
        // Remove any existing file at the path
        try? FileManager.default.removeItem(at: fileURL)
        
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        
        actor CancellationFlag {
            var isCancelled = false
            func cancel() { isCancelled = true }
        }
        let cancellationFlag = CancellationFlag()
        
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                PHAssetResourceManager.default().writeData(
                    for: resource,
                    toFile: fileURL,
                    options: options
                ) { error in
                    Task {
                        if await cancellationFlag.isCancelled { return }
                        if let error = error {
                            try? FileManager.default.removeItem(at: fileURL)
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: fileURL)
                        }
                    }
                }
            }
        } onCancel: {
            Task { await cancellationFlag.cancel() }
        }
    }
    
    /// Checks if a resource should use file-based export (for large files like videos).
    func shouldUseFileExport(for resource: PHAssetResource) -> Bool {
        let uti = resource.uniformTypeIdentifier.lowercased()
        let isVideo = resource.type == .video ||
                      resource.type == .fullSizeVideo ||
                      uti.contains("video") ||
                      uti.contains("movie")
        return isVideo
    }
    
    func getThumbnail(for asset: PHAsset, targetSize: CGSize = CGSize(width: 200, height: 200), completion: @escaping (UIImage?) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            completion(image)
        }
    }
    
    func getMimeType(for resource: PHAssetResource) -> String {
        let uti = resource.uniformTypeIdentifier.lowercased()
        
        if uti.contains("jpeg") || uti.contains("jpg") {
            return "image/jpeg"
        } else if uti.contains("png") {
            return "image/png"
        } else if uti.contains("heic") || uti.contains("heif") {
            return "image/heic"
        } else if uti.contains("gif") {
            return "image/gif"
        } else if uti.contains("webp") {
            return "image/webp"
        } else if uti.contains("tiff") {
            return "image/tiff"
        }
        
        if uti.contains("dng") {
            return "image/x-adobe-dng"
        } else if uti.contains("arw") {
            return "image/x-sony-arw"
        } else if uti.contains("cr2") {
            return "image/x-canon-cr2"
        } else if uti.contains("cr3") {
            return "image/x-canon-cr3"
        } else if uti.contains("nef") {
            return "image/x-nikon-nef"
        } else if uti.contains("raf") {
            return "image/x-fuji-raf"
        } else if uti.contains("orf") {
            return "image/x-olympus-orf"
        } else if uti.contains("rw2") {
            return "image/x-panasonic-rw2"
        } else if uti.contains("raw") {
            return "image/x-raw"
        }
        
        if uti.contains("mpeg4") || uti.contains("mp4") {
            return "video/mp4"
        } else if uti.contains("quicktime") || uti.contains("mov") {
            return "video/quicktime"
        } else if uti.contains("avi") {
            return "video/x-msvideo"
        }
        
        return "application/octet-stream"
    }
    
    func getFilename(for resource: PHAssetResource) -> String {
        return resource.originalFilename
    }
}
