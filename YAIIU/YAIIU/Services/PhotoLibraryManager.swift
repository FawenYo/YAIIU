import Foundation
import Photos
import UIKit

/// Manages photo library access with lazy loading for optimal memory performance.
/// Uses PHFetchResult directly instead of materializing all PHAsset objects into arrays.
final class PhotoLibraryManager: ObservableObject {
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var assetCount: Int = 0
    
    private var _fetchResult: PHFetchResult<PHAsset>?
    private let fetchResultLock = NSLock()
    
    /// Thread-safe access to fetch result
    var fetchResult: PHFetchResult<PHAsset>? {
        fetchResultLock.lock()
        defer { fetchResultLock.unlock() }
        return _fetchResult
    }
    
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
            if _fetchResult == nil {
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
    
    /// Fetches assets lazily - only creates PHFetchResult without materializing PHAsset objects.
    /// PHFetchResult is a lazy collection that loads assets on-demand.
    func fetchAssets() {
        Task {
            await fetchAssetsAsync()
        }
    }
    
    /// Async version of fetchAssets for proper await support in pull-to-refresh.
    @MainActor
    func fetchAssetsAsync() async {
        isLoading = true
        
        let (result, count) = await Task.detached(priority: .userInitiated) {
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            fetchOptions.includeHiddenAssets = false
            
            let result = PHAsset.fetchAssets(with: fetchOptions)
            return (result, result.count)
        }.value
        
        fetchResultLock.lock()
        _fetchResult = result
        fetchResultLock.unlock()
        
        assetCount = count
        isLoading = false
        
        await triggerFavoriteSync()
    }
    
    /// Returns the formatted date for a given asset index.
    func creationDate(at index: Int) -> Date? {
        guard let asset = asset(at: index) else { return nil }
        return asset.creationDate
    }
    
    /// Returns asset at specific index. This is the preferred way to access assets
    /// as it only materializes one PHAsset object at a time.
    func asset(at index: Int) -> PHAsset? {
        guard let result = fetchResult, index >= 0, index < result.count else {
            return nil
        }
        return result.object(at: index)
    }
    
    /// Returns local identifier at specific index without materializing PHAsset.
    /// Useful for ID-based operations where full asset object isn't needed.
    func localIdentifier(at index: Int) -> String? {
        return asset(at: index)?.localIdentifier
    }
    
    /// Returns assets within index range for batch operations.
    /// Use sparingly - prefer index-based access for UI rendering.
    func assets(in range: Range<Int>) -> [PHAsset] {
        guard let result = fetchResult else { return [] }
        let clampedRange = max(0, range.lowerBound)..<min(result.count, range.upperBound)
        guard clampedRange.lowerBound < clampedRange.upperBound else { return [] }
        
        let indexSet = IndexSet(clampedRange)
        return result.objects(at: indexSet)
    }
    
    /// Returns all local identifiers. This is efficient as it only accesses identifiers.
    func allLocalIdentifiers() -> [String] {
        guard let result = fetchResult else { return [] }
        var identifiers: [String] = []
        identifiers.reserveCapacity(result.count)
        
        result.enumerateObjects { asset, _, _ in
            identifiers.append(asset.localIdentifier)
        }
        return identifiers
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
        return resource.resolvedFilename()
    }
}
