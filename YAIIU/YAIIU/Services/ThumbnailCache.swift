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
        os_unfair_lock_unlock(&pendingLock)
        return "\(localIdentifier)_r\(revision)_\(Int(targetSize.width))x\(Int(targetSize.height))"
    }

    /// Called for PhotoKit in-place edits before the new fetch is published.
    /// NSCache's existing 50 MB budget will evict unreachable old revisions.
    func invalidateThumbnail(for localIdentifier: String) {
        os_unfair_lock_lock(&pendingLock)
        assetRevisions[localIdentifier, default: 0] &+= 1
        os_unfair_lock_unlock(&pendingLock)
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
            guard let self = self else { return }
            
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
        activeRequestIDs[keyString] = requestID
        os_unfair_lock_unlock(&pendingLock)
    }
    
    func cancelThumbnail(for assetIdentifier: String, targetSize: CGSize = ThumbnailCache.defaultTargetSize) {
        let keyString = key(for: assetIdentifier, targetSize: targetSize)
        
        os_unfair_lock_lock(&pendingLock)
        if let requestID = activeRequestIDs.removeValue(forKey: keyString) {
            pendingRequests.removeValue(forKey: keyString)
            os_unfair_lock_unlock(&pendingLock)
            cachingImageManager.cancelImageRequest(requestID)
        } else {
            os_unfair_lock_unlock(&pendingLock)
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
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = false
        options.resizeMode = .fast
        
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
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = false
        options.resizeMode = .fast
        
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
