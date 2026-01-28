import Foundation
import UIKit
import Photos
import os.lock

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    
    private let cache = NSCache<NSString, UIImage>()
    private let cachingImageManager = PHCachingImageManager()
    
    private var pendingRequests: [String: [(UIImage?) -> Void]] = [:]
    private var activeRequestIDs: [String: PHImageRequestID] = [:]
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
        options.resizeMode = .fast
        
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
                    let cost = Int(image.size.width * image.size.height * 4)
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
    
    func cancelThumbnail(for assetIdentifier: String, targetSize: CGSize = CGSize(width: 200, height: 200)) {
        let keyString = "\(assetIdentifier)_\(Int(targetSize.width))x\(Int(targetSize.height))"
        
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
    
    /// Clear all cached thumbnails
    func clearCache() {
        cache.removeAllObjects()
        cachingImageManager.stopCachingImagesForAllAssets()
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
