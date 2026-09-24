import Foundation
import UIKit
import Photos
import os.lock

extension Notification.Name {
    static let thumbnailCacheDidClear = Notification.Name("com.fawenyo.yaiiu.thumbnailCacheDidClear")
}

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    
    private let cache = NSCache<NSString, UIImage>()
    private let cachingImageManager = PHCachingImageManager()
    
    private var pendingRequests: [String: [(UIImage?) -> Void]] = [:]
    private var activeRequestIDs: [String: PHImageRequestID] = [:]
    /// A generation token prevents a late completion from a cancelled request
    /// from deleting state belonging to a newer request for the same cell/key.
    private var activeRequestGenerations: [String: UUID] = [:]
    private var pendingLock = os_unfair_lock()
    
    private static let foregroundCountLimit = 96
    private static let foregroundCostLimit = 24 * 1024 * 1024
    private static let backgroundCountLimit = 32
    private static let backgroundCostLimit = 8 * 1024 * 1024

    private init() {
        cache.countLimit = Self.foregroundCountLimit
        cache.totalCostLimit = Self.foregroundCostLimit
        
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
        cache.countLimit = Self.backgroundCountLimit
        cache.totalCostLimit = Self.backgroundCostLimit
        clearCache()
    }
    
    @objc private func handleWillEnterForeground() {
        cache.countLimit = Self.foregroundCountLimit
        cache.totalCostLimit = Self.foregroundCostLimit
    }
    
    func getThumbnail(
        for asset: PHAsset,
        targetSize: CGSize = CGSize(width: 200, height: 200),
        completion: @escaping (UIImage?) -> Void
    ) {
        let cacheKey = "\(asset.localIdentifier)_\(Int(targetSize.width))x\(Int(targetSize.height))" as NSString

        if let cachedImage = cache.object(forKey: cacheKey) {
            DispatchQueue.main.async {
                completion(cachedImage)
            }
            return
        }

        let keyString = cacheKey as String
        let generation = UUID()

        os_unfair_lock_lock(&pendingLock)
        if var existingCallbacks = pendingRequests[keyString] {
            existingCallbacks.append(completion)
            pendingRequests[keyString] = existingCallbacks
            os_unfair_lock_unlock(&pendingLock)
            return
        }
        pendingRequests[keyString] = [completion]
        activeRequestGenerations[keyString] = generation
        os_unfair_lock_unlock(&pendingLock)

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast

        let requestID = cachingImageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, info in
            guard let self else { return }

            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false

            os_unfair_lock_lock(&self.pendingLock)
            guard self.activeRequestGenerations[keyString] == generation else {
                os_unfair_lock_unlock(&self.pendingLock)
                return
            }

            if isCancelled {
                self.pendingRequests.removeValue(forKey: keyString)
                self.activeRequestIDs.removeValue(forKey: keyString)
                self.activeRequestGenerations.removeValue(forKey: keyString)
                os_unfair_lock_unlock(&self.pendingLock)
                return
            }

            let callbacks: [(UIImage?) -> Void]
            if isDegraded {
                callbacks = self.pendingRequests[keyString] ?? []
            } else {
                callbacks = self.pendingRequests.removeValue(forKey: keyString) ?? []
                self.activeRequestIDs.removeValue(forKey: keyString)
                self.activeRequestGenerations.removeValue(forKey: keyString)
            }
            os_unfair_lock_unlock(&self.pendingLock)

            if let image, !isDegraded {
                let cost = Int(image.size.width * image.size.height * 4)
                self.cache.setObject(image, forKey: cacheKey, cost: cost)
            }

            if image != nil || !isDegraded {
                DispatchQueue.main.async {
                    for callback in callbacks {
                        callback(image)
                    }
                }
            }
        }

        var shouldCancelImmediately = false
        os_unfair_lock_lock(&pendingLock)
        if activeRequestGenerations[keyString] == generation {
            activeRequestIDs[keyString] = requestID
        } else {
            // clearCache()/cancelThumbnail() won the race while requestImage
            // was being created. Do not let this orphan continue.
            shouldCancelImmediately = true
        }
        os_unfair_lock_unlock(&pendingLock)

        if shouldCancelImmediately {
            cachingImageManager.cancelImageRequest(requestID)
        }
    }

    func cancelThumbnail(
        for assetIdentifier: String,
        targetSize: CGSize = CGSize(width: 200, height: 200)
    ) {
        let keyString = "\(assetIdentifier)_\(Int(targetSize.width))x\(Int(targetSize.height))"

        os_unfair_lock_lock(&pendingLock)
        let requestID = activeRequestIDs.removeValue(forKey: keyString)
        pendingRequests.removeValue(forKey: keyString)
        activeRequestGenerations.removeValue(forKey: keyString)
        os_unfair_lock_unlock(&pendingLock)

        if let requestID {
            cachingImageManager.cancelImageRequest(requestID)
        }
    }

    /// Prefetch thumbnails for better scrolling performance
    func prefetchThumbnails(for assets: [PHAsset], targetSize: CGSize = CGSize(width: 200, height: 200)) {
        let uncachedAssets = assets.filter { asset in
            let cacheKey = "\(asset.localIdentifier)_\(Int(targetSize.width))x\(Int(targetSize.height))" as NSString
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
    func stopPrefetching(for assets: [PHAsset], targetSize: CGSize = CGSize(width: 200, height: 200)) {
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
    
    /// Clear all cached thumbnails and cancel in-flight PhotoKit image work.
    /// stopCachingImagesForAllAssets() only stops preheating; it does not cancel
    /// requestImage calls already retained by this cache.
    func clearCache() {
        cache.removeAllObjects()
        cachingImageManager.stopCachingImagesForAllAssets()

        os_unfair_lock_lock(&pendingLock)
        let requestIDs = Array(activeRequestIDs.values)
        activeRequestIDs.removeAll(keepingCapacity: false)
        activeRequestGenerations.removeAll(keepingCapacity: false)
        pendingRequests.removeAll(keepingCapacity: false)
        os_unfair_lock_unlock(&pendingLock)

        for requestID in requestIDs {
            cachingImageManager.cancelImageRequest(requestID)
        }

        // Visible cells own their display lifecycle and can selectively
        // re-request a small thumbnail after cancellation. This avoids leaving
        // an on-screen cell stuck on its placeholder while still dropping all
        // cache/preheat/in-flight PhotoKit work immediately.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .thumbnailCacheDidClear, object: nil)
        }
    }
    
    /// Remove cached thumbnail for specific asset
    func removeThumbnail(for localIdentifier: String) {
        let keysToRemove = [
            "\(localIdentifier)_200x200",
            "\(localIdentifier)_100x100",
            "\(localIdentifier)_400x400"
        ]
        
        for key in keysToRemove {
            cache.removeObject(forKey: key as NSString)
        }
    }
}
