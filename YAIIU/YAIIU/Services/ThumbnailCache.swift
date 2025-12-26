import Foundation
import UIKit
import Photos

/// ThumbnailCache - Uses NSCache to cache thumbnails, avoiding repeated loading
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    
    private let cache = NSCache<NSString, UIImage>()
    private let requestQueue = DispatchQueue(label: "com.fawenyo.yaiiu.thumbnail", qos: .userInitiated, attributes: .concurrent)
    private var pendingRequests: [String: [(UIImage?) -> Void]] = [:]
    private let pendingLock = NSLock()
    
    /// PHCachingImageManager for prefetching
    private let cachingImageManager = PHCachingImageManager()
    
    private init() {
        // Set cache limits
        cache.countLimit = 500 // Maximum 500 thumbnails
        cache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
        
        // Listen for memory warnings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleMemoryWarning() {
        cache.removeAllObjects()
        logInfo("ThumbnailCache cleared due to memory warning", category: .app)
    }
    
    /// Get thumbnail (preferring cached version)
    func getThumbnail(
        for asset: PHAsset,
        targetSize: CGSize = CGSize(width: 200, height: 200),
        completion: @escaping (UIImage?) -> Void
    ) {
        let cacheKey = "\(asset.localIdentifier)_\(Int(targetSize.width))x\(Int(targetSize.height))" as NSString
        
        // Check cache
        if let cachedImage = cache.object(forKey: cacheKey) {
            DispatchQueue.main.async {
                completion(cachedImage)
            }
            return
        }
        
        // Merge identical requests to avoid duplicate loading
        pendingLock.lock()
        let keyString = cacheKey as String
        if var existingCallbacks = pendingRequests[keyString] {
            existingCallbacks.append(completion)
            pendingRequests[keyString] = existingCallbacks
            pendingLock.unlock()
            return
        }
        pendingRequests[keyString] = [completion]
        pendingLock.unlock()
        
        // Load thumbnail from Photos framework
        requestQueue.async { [weak self] in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            options.resizeMode = .fast
            
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { [weak self] image, info in
                guard let self = self else { return }
                
                // Check if this is a degraded image (low quality placeholder from iCloud)
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                
                if let image = image {
                    // Only cache non-degraded (high quality) images
                    if !isDegraded {
                        let cost = Int(image.size.width * image.size.height * 4)
                        self.cache.setObject(image, forKey: cacheKey, cost: cost)
                    }
                    
                    self.pendingLock.lock()
                    if isDegraded {
                        // For degraded images: notify callbacks but keep them for the high quality version
                        let callbacks = self.pendingRequests[keyString] ?? []
                        self.pendingLock.unlock()
                        
                        DispatchQueue.main.async {
                            for callback in callbacks {
                                callback(image)
                            }
                        }
                    } else {
                        // For high quality images: notify callbacks and remove them
                        let callbacks = self.pendingRequests.removeValue(forKey: keyString) ?? []
                        self.pendingLock.unlock()
                        
                        DispatchQueue.main.async {
                            for callback in callbacks {
                                callback(image)
                            }
                        }
                    }
                } else if !isDegraded {
                    // Only return nil for non-degraded cases (actual failure)
                    self.pendingLock.lock()
                    let callbacks = self.pendingRequests.removeValue(forKey: keyString) ?? []
                    self.pendingLock.unlock()
                    
                    DispatchQueue.main.async {
                        for callback in callbacks {
                            callback(nil)
                        }
                    }
                }
            }
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
