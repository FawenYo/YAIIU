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
    /// Full-quality cell requests bypass the caching manager: it answered them
    /// with its preheated low-quality image marked as final, leaving cells blurry.
    private let fullQualityManager = PHImageManager.default()
    /// Preheat start/stop calls are synchronous PhotoKit work; keep them off the
    /// main thread, which is saturated by grid layout during fast scrolling.
    private let preheatQueue = DispatchQueue(label: "com.fawenyo.yaiiu.thumbnail-preheat", qos: .userInitiated)
    
    private var pendingRequests: [String: [(token: UUID, callback: (UIImage?) -> Void)]] = [:]
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
            fullQualityManager.cancelImageRequest(requestID)
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
            fullQualityManager.cancelImageRequest(requestID)
        }
        cache.removeAllObjects()
        preheatQueue.async { [cachingImageManager] in cachingImageManager.stopCachingImagesForAllAssets() }
    }

    func cachedThumbnail(for localIdentifier: String, targetSize: CGSize) -> UIImage? {
        cache.object(forKey: key(for: localIdentifier, targetSize: targetSize) as NSString)
    }

    /// A local-only, fast-format placeholder: never downloads and never decodes
    /// a large derivative, so cells that are flung past stay cheap.
    func requestFastThumbnail(for asset: PHAsset, targetSize: CGSize, completion: @escaping (UIImage?) -> Void) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return cachingImageManager.requestImage(
            for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options
        ) { image, _ in
            DispatchQueue.main.async { completion(image) }
        }
    }

    func cancelFastThumbnail(_ requestID: PHImageRequestID) {
        cachingImageManager.cancelImageRequest(requestID)
    }

    /// Returns a token identifying this caller's wait, or nil on a cache hit.
    /// Several views can wait on one PhotoKit request for the same photo
    /// (a recycled and a newly configured cell); each cancels only its own wait.
    @discardableResult
    func getThumbnail(
        for asset: PHAsset,
        targetSize: CGSize = ThumbnailCache.defaultTargetSize,
        completion: @escaping (UIImage?) -> Void
    ) -> UUID? {
        let cacheKey = key(for: asset.localIdentifier, targetSize: targetSize) as NSString
        
        if let cachedImage = cache.object(forKey: cacheKey) {
            DispatchQueue.main.async {
                completion(cachedImage)
            }
            return nil
        }
        
        let keyString = cacheKey as String
        let token = UUID()
        
        os_unfair_lock_lock(&pendingLock)
        if pendingRequests[keyString] != nil {
            pendingRequests[keyString]?.append((token, completion))
            os_unfair_lock_unlock(&pendingLock)
            return token
        }
        pendingRequests[keyString] = [(token, completion)]
        os_unfair_lock_unlock(&pendingLock)
        
        startRequest(for: asset, targetSize: targetSize, cacheKey: cacheKey)
        return token
    }

    /// Preheating stays local-only so offscreen iCloud items are never downloaded.
    private static let preheatOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = false
        options.resizeMode = .exact
        return options
    }()

    /// Visible cells allow the network: without it PhotoKit can report a small
    /// local thumbnail of an iCloud-only photo as the final result.
    private static let visibleRequestOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .exact
        return options
    }()

    private func startRequest(for asset: PHAsset, targetSize: CGSize, cacheKey: NSString) {
        let keyString = cacheKey as String
        let requestID = fullQualityManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: Self.visibleRequestOptions
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
                    callbacks = (self.pendingRequests[keyString] ?? []).map(\.callback)
                } else {
                    callbacks = (self.pendingRequests.removeValue(forKey: keyString) ?? []).map(\.callback)
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
                let callbacks = (self.pendingRequests.removeValue(forKey: keyString) ?? []).map(\.callback)
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
            fullQualityManager.cancelImageRequest(requestID)
        }
    }
    
    func cancelThumbnail(_ token: UUID, for assetIdentifier: String, targetSize: CGSize = ThumbnailCache.defaultTargetSize) {
        // A view can disappear after the asset revision changed. Look in any
        // revision of its requested size, not just the current cache key.
        let prefix = "\(assetIdentifier)_r"
        let suffix = "_\(Int(targetSize.width))x\(Int(targetSize.height))"
        var requestIDs: [PHImageRequestID] = []
        os_unfair_lock_lock(&pendingLock)
        for key in Array(pendingRequests.keys) where key.hasPrefix(prefix) && key.hasSuffix(suffix) {
            pendingRequests[key]?.removeAll { $0.token == token }
            // Cancel PhotoKit work only once no other view is waiting for it.
            if pendingRequests[key]?.isEmpty == true {
                pendingRequests.removeValue(forKey: key)
                if let requestID = activeRequestIDs.removeValue(forKey: key) {
                    requestIDs.append(requestID)
                }
            }
        }
        os_unfair_lock_unlock(&pendingLock)
        for requestID in requestIDs {
            fullQualityManager.cancelImageRequest(requestID)
        }
    }
    
    /// Prefetch thumbnails for better scrolling performance
    func prefetchThumbnails(for assets: [PHAsset], targetSize: CGSize = ThumbnailCache.defaultTargetSize) {
        preheatQueue.async { [self] in
            let uncachedAssets = assets.filter { asset in
                let cacheKey = key(for: asset.localIdentifier, targetSize: targetSize) as NSString
                return cache.object(forKey: cacheKey) == nil
            }
            guard !uncachedAssets.isEmpty else { return }

            // Never download offscreen iCloud items while preheating.
            cachingImageManager.startCachingImages(
                for: uncachedAssets,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: Self.preheatOptions
            )
        }
    }
    
    /// Stop prefetching thumbnails
    func stopPrefetching(for assets: [PHAsset], targetSize: CGSize = ThumbnailCache.defaultTargetSize) {
        preheatQueue.async { [self] in
            cachingImageManager.stopCachingImages(
                for: assets,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: Self.preheatOptions
            )
        }
    }

    func stopAllPrefetching() {
        preheatQueue.async { [cachingImageManager] in cachingImageManager.stopCachingImagesForAllAssets() }
    }
    
    /// Clear all cached thumbnails
    func clearCache() {
        cache.removeAllObjects()
        preheatQueue.async { [cachingImageManager] in cachingImageManager.stopCachingImagesForAllAssets() }
    }
    
    /// Keep legacy callers invalidating every cached resolution of this asset.
    func removeThumbnail(for localIdentifier: String) {
        invalidateThumbnail(for: localIdentifier)
    }
}
