import Foundation
import UIKit
import Photos
import os.lock

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    /// Fallback for callers without a measured grid width.
    static let defaultTargetSize = CGSize(width: 480, height: 480)

    /// Request the rendered grid cell's pixel size, rounded up to avoid a
    /// new PhotoKit cache key for tiny layout changes. Cap iPad allocations.
    static func targetSize(forGridCellWidth width: CGFloat, displayScale: CGFloat) -> CGSize {
        guard width > 0, displayScale > 0 else { return defaultTargetSize }
        let requiredPixels = ceil(width * displayScale)
        let side = min(1024, max(480, ceil(requiredPixels / 64) * 64))
        return CGSize(width: side, height: side)
    }
    
    private let cache = NSCache<NSString, UIImage>()
    private let cachingImageManager = PHCachingImageManager()
    
    private var pendingRequests: [String: [(UIImage?) -> Void]] = [:]
    private var activeRequestIDs: [String: PHImageRequestID] = [:]
    /// A revision changes the cache key without clearing unrelated photos.
    /// Old in-flight PhotoKit results can only populate their obsolete key.
    private var assetRevisions: [String: UInt64] = [:]
    private var fullLibraryRevision: UInt64 = 0
    private var pendingLock = os_unfair_lock()
    
    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024
        
        cachingImageManager.allowsCachingHighQualityImages = false
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBackgroundTransition),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleMemoryWarning() {
        clearCache()
        logInfo("ThumbnailCache cleared due to memory warning", category: .app)
    }
    
    @objc private func handleBackgroundTransition() {
        cache.countLimit = 100
    }
    
    @objc private func handleWillEnterForeground() {
        cache.countLimit = 200
    }
    
    private func key(for localIdentifier: String, targetSize: CGSize) -> String {
        os_unfair_lock_lock(&pendingLock)
        let revision = assetRevisions[localIdentifier] ?? 0
        let libraryRevision = fullLibraryRevision
        os_unfair_lock_unlock(&pendingLock)
        return "\(localIdentifier)_r\(revision)_g\(libraryRevision)_\(Int(targetSize.width))x\(Int(targetSize.height))"
    }

    /// Visible cells compare the exact cache invalidation revision, so
    /// consecutive PhotoKit notifications cannot overwrite each other's edits.
    func contentRevision(for localIdentifier: String) -> PhotoAssetContentRevision {
        os_unfair_lock_lock(&pendingLock)
        defer { os_unfair_lock_unlock(&pendingLock) }
        return PhotoAssetContentRevision(
            library: fullLibraryRevision,
            asset: assetRevisions[localIdentifier] ?? 0
        )
    }

    /// Called for PhotoKit in-place edits before the new fetch is published.
    /// NSCache's existing 50 MB budget will evict unreachable old revisions.
    func invalidateThumbnail(for localIdentifier: String) {
        // Retire requests for the old revision before publishing the new key.
        // Otherwise an iCloud request can continue downloading for an asset
        // whose completed image can never be displayed.
        os_unfair_lock_lock(&pendingLock)
        assetRevisions[localIdentifier, default: 0] &+= 1
        let prefix = "\(localIdentifier)_r"
        let keys = activeRequestIDs.keys.filter { $0.hasPrefix(prefix) }
        let requestIDs = keys.compactMap { activeRequestIDs.removeValue(forKey: $0) }
        // A request can be invalidated before requestImage returns its ID.
        // Remove these pending callbacks too so obsolete closures are released.
        let pendingKeys = pendingRequests.keys.filter { $0.hasPrefix(prefix) }
        for key in pendingKeys { pendingRequests.removeValue(forKey: key) }
        os_unfair_lock_unlock(&pendingLock)
        for requestID in requestIDs {
            cachingImageManager.cancelImageRequest(requestID)
        }
    }

    /// A nonincremental PhotoKit change does not identify individual edits.
    /// Retire old requests and version every cache key once; normal incremental
    /// updates still invalidate only the photos they actually changed.
    func invalidateAllThumbnails() {
        os_unfair_lock_lock(&pendingLock)
        fullLibraryRevision &+= 1
        assetRevisions.removeAll()
        let requestIDs = Array(activeRequestIDs.values)
        activeRequestIDs.removeAll()
        pendingRequests.removeAll()
        os_unfair_lock_unlock(&pendingLock)

        for requestID in requestIDs {
            cachingImageManager.cancelImageRequest(requestID)
        }
        cache.removeAllObjects()
        cachingImageManager.stopCachingImagesForAllAssets()
    }

    func getThumbnail(
        for asset: PHAsset,
        targetSize: CGSize = ThumbnailCache.defaultTargetSize,
        completion: @escaping (UIImage?) -> Void
    ) {
        let cacheKey = key(for: asset.localIdentifier, targetSize: targetSize) as NSString
        
        if let cachedImage = cache.object(forKey: cacheKey) {
            DispatchQueue.main.async {
                completion(cachedImage)
            }
            return
        }
        
        let keyString = cacheKey as String
        
        os_unfair_lock_lock(&pendingLock)
        if var existingCallbacks = pendingRequests[keyString] {
            existingCallbacks.append(completion)
            pendingRequests[keyString] = existingCallbacks
            os_unfair_lock_unlock(&pendingLock)
            return
        }
        pendingRequests[keyString] = [completion]
        os_unfair_lock_unlock(&pendingLock)
        
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .exact
        
        let requestID = cachingImageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, info in
            guard let self = self,
                  self.key(for: asset.localIdentifier, targetSize: targetSize) == keyString else { return }

            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            
            if isCancelled {
                os_unfair_lock_lock(&self.pendingLock)
                self.pendingRequests.removeValue(forKey: keyString)
                self.activeRequestIDs.removeValue(forKey: keyString)
                os_unfair_lock_unlock(&self.pendingLock)
                return
            }
            
            if let image = image {
                if !isDegraded {
                    let cost: Int
                    if let cgImage = image.cgImage {
                        cost = cgImage.bytesPerRow * cgImage.height
                    } else {
                        // UIImage.size is in points; NSCache needs the decoded pixel cost.
                        let width = image.size.width * image.scale
                        let height = image.size.height * image.scale
                        cost = Int(width * height * 4)
                    }
                    self.cache.setObject(image, forKey: cacheKey, cost: cost)
                }
                
                os_unfair_lock_lock(&self.pendingLock)
                let callbacks: [(UIImage?) -> Void]
                if isDegraded {
                    callbacks = self.pendingRequests[keyString] ?? []
                } else {
                    callbacks = self.pendingRequests.removeValue(forKey: keyString) ?? []
                    self.activeRequestIDs.removeValue(forKey: keyString)
                }
                os_unfair_lock_unlock(&self.pendingLock)
                
                DispatchQueue.main.async {
                    for callback in callbacks {
                        callback(image)
                    }
                }
            } else if !isDegraded {
                os_unfair_lock_lock(&self.pendingLock)
                let callbacks = self.pendingRequests.removeValue(forKey: keyString) ?? []
                self.activeRequestIDs.removeValue(forKey: keyString)
                os_unfair_lock_unlock(&self.pendingLock)
                
                DispatchQueue.main.async {
                    for callback in callbacks {
                        callback(nil)
                    }
                }
            }
        }
        
        os_unfair_lock_lock(&pendingLock)
        let currentRevision = assetRevisions[asset.localIdentifier] ?? 0
        let expectedKey = "\(asset.localIdentifier)_r\(currentRevision)_g\(fullLibraryRevision)_\(Int(targetSize.width))x\(Int(targetSize.height))"
        let stillPending = pendingRequests[keyString] != nil && expectedKey == keyString
        if stillPending {
            activeRequestIDs[keyString] = requestID
        } else if expectedKey != keyString {
            pendingRequests.removeValue(forKey: keyString)
        }
        os_unfair_lock_unlock(&pendingLock)
        // Covers either invalidation or view cancellation between
        // requestImage() and request-ID registration.
        if !stillPending {
            cachingImageManager.cancelImageRequest(requestID)
        }
    }
    
    func cancelThumbnail(for assetIdentifier: String, targetSize: CGSize = ThumbnailCache.defaultTargetSize) {
        // A view can disappear after the asset revision changed. Cancel any
        // revision of its requested size, not just the current cache key.
        let prefix = "\(assetIdentifier)_r"
        let suffix = "_\(Int(targetSize.width))x\(Int(targetSize.height))"
        os_unfair_lock_lock(&pendingLock)
        let keys = activeRequestIDs.keys.filter {
            $0.hasPrefix(prefix) && $0.hasSuffix(suffix)
        }
        let requestIDs = keys.compactMap { activeRequestIDs.removeValue(forKey: $0) }
        let pendingKeys = pendingRequests.keys.filter {
            $0.hasPrefix(prefix) && $0.hasSuffix(suffix)
        }
        for key in pendingKeys { pendingRequests.removeValue(forKey: key) }
        os_unfair_lock_unlock(&pendingLock)
        for requestID in requestIDs {
            cachingImageManager.cancelImageRequest(requestID)
        }
    }
    
    /// Prefetch thumbnails for better scrolling performance
    func prefetchThumbnails(for assets: [PHAsset], targetSize: CGSize = ThumbnailCache.defaultTargetSize) {
        let uncachedAssets = assets.filter { asset in
            let cacheKey = key(for: asset.localIdentifier, targetSize: targetSize) as NSString
            return cache.object(forKey: cacheKey) == nil
        }
        
        guard !uncachedAssets.isEmpty else { return }
        
        let options = PHImageRequestOptions()
        // Match the visible cell's quality and resize request so preheating
        // does not decode a second fast-format variant for the same asset.
        // Keep networking disabled to avoid downloading offscreen iCloud items.
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = false
        options.resizeMode = .exact
        
        cachingImageManager.startCachingImages(
            for: uncachedAssets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        )
    }
    
    /// Stop prefetching thumbnails
    func stopPrefetching(for assets: [PHAsset], targetSize: CGSize = ThumbnailCache.defaultTargetSize) {
        let options = PHImageRequestOptions()
        // Match the visible cell's quality and resize request so preheating
        // does not decode a second fast-format variant for the same asset.
        // Keep networking disabled to avoid downloading offscreen iCloud items.
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = false
        options.resizeMode = .exact
        
        cachingImageManager.stopCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        )
    }
    
    /// Clear all cached thumbnails
    func clearCache() {
        cache.removeAllObjects()
        cachingImageManager.stopCachingImagesForAllAssets()
    }
    
    /// Keep legacy callers invalidating every cached resolution of this asset.
    func removeThumbnail(for localIdentifier: String) {
        invalidateThumbnail(for: localIdentifier)
    }
}
