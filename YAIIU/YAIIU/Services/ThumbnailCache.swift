import Foundation
import UIKit
import Photos
import os.lock

extension Notification.Name {
    static let thumbnailCacheDidClear = Notification.Name("com.fawenyo.yaiiu.thumbnailCacheDidClear")
    static let thumbnailCacheShouldReloadVisible = Notification.Name("com.fawenyo.yaiiu.thumbnailCacheShouldReloadVisible")
}

final class ThumbnailCache {
    struct RequestToken: Hashable, Sendable {
        fileprivate let key: String
        fileprivate let consumerID: UUID
    }

    static let shared = ThumbnailCache()
    
    private let cache = NSCache<NSString, UIImage>()
    private let cachingImageManager = PHCachingImageManager()
    
    /// Per-key consumer callbacks. Multiple views may share one PhotoKit
    /// request without sharing cancellation ownership.
    private var pendingRequests: [String: [UUID: (UIImage?) -> Void]] = [:]
    private var activeRequestIDs: [String: PHImageRequestID] = [:]
    /// A generation token prevents a late completion from a cancelled request
    /// from deleting state belonging to a newer request for the same cell/key.
    private var activeRequestGenerations: [String: UUID] = [:]
    /// Incremented whenever clearCache() invalidates the visible thumbnail
    /// working set. Callback delivery captures the epoch and is suppressed if a
    /// clear happened after PhotoKit completed but before the main-queue callback.
    private var cacheEpoch: UInt64 = 0
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
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleMemoryWarning() {
        clearCache()
        logInfo("ThumbnailCache cleared due to memory warning", category: .app)

        // If the app stays active, mounted cells will not receive another
        // onAppear. Give the system a short recovery window, then ask visible
        // consumers to reload only when hashing is not competing for PhotoKit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard UIApplication.shared.applicationState == .active,
                  !HashManager.shared.isProcessing else { return }
            self?.requestVisibleThumbnailReload()
        }
    }
    
    @objc private func handleBackgroundTransition() {
        cache.countLimit = Self.backgroundCountLimit
        cache.totalCostLimit = Self.backgroundCostLimit
        clearCache()
    }
    
    @objc private func handleDidBecomeActive() {
        cache.countLimit = Self.foregroundCountLimit
        cache.totalCostLimit = Self.foregroundCostLimit
        requestVisibleThumbnailReload()
    }
    
    @discardableResult
    func getThumbnail(
        for asset: PHAsset,
        targetSize: CGSize = CGSize(width: 200, height: 200),
        completion: @escaping (UIImage?) -> Void
    ) -> RequestToken? {
        let cacheKey = "\(asset.localIdentifier)_\(Int(targetSize.width))x\(Int(targetSize.height))" as NSString

        if let cachedImage = cache.object(forKey: cacheKey) {
            DispatchQueue.main.async {
                completion(cachedImage)
            }
            return nil
        }

        let keyString = cacheKey as String
        let consumerID = UUID()
        let token = RequestToken(key: keyString, consumerID: consumerID)
        let generation = UUID()

        os_unfair_lock_lock(&pendingLock)
        if var existingCallbacks = pendingRequests[keyString] {
            existingCallbacks[consumerID] = completion
            pendingRequests[keyString] = existingCallbacks
            os_unfair_lock_unlock(&pendingLock)
            return token
        }

        pendingRequests[keyString] = [consumerID: completion]
        activeRequestGenerations[keyString] = generation
        let requestEpoch = cacheEpoch
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
                let callbacks = self.pendingRequests
                    .removeValue(forKey: keyString)
                    .map { Array($0.values) } ?? []
                self.activeRequestIDs.removeValue(forKey: keyString)
                self.activeRequestGenerations.removeValue(forKey: keyString)
                os_unfair_lock_unlock(&self.pendingLock)

                if !callbacks.isEmpty {
                    self.deliver(
                        callbacks: callbacks,
                        image: nil,
                        requestEpoch: requestEpoch
                    )
                }
                return
            }

            // Keep the generation check + cache write atomic with clearCache().
            if let image, !isDegraded {
                let cost: Int
                if let cgImage = image.cgImage {
                    cost = max(1, cgImage.bytesPerRow * cgImage.height)
                } else {
                    let pixelWidth = Int(image.size.width * image.scale)
                    let pixelHeight = Int(image.size.height * image.scale)
                    cost = max(1, pixelWidth * pixelHeight * 4)
                }
                self.cache.setObject(image, forKey: cacheKey, cost: cost)
            }

            let callbacks: [(UIImage?) -> Void]
            if isDegraded {
                callbacks = self.pendingRequests[keyString].map { Array($0.values) } ?? []
            } else {
                callbacks = self.pendingRequests
                    .removeValue(forKey: keyString)
                    .map { Array($0.values) } ?? []
                self.activeRequestIDs.removeValue(forKey: keyString)
                self.activeRequestGenerations.removeValue(forKey: keyString)
            }
            os_unfair_lock_unlock(&self.pendingLock)

            if image != nil || !isDegraded {
                self.deliver(
                    callbacks: callbacks,
                    image: image,
                    requestEpoch: requestEpoch
                )
            }
        }

        var shouldCancelImmediately = false
        os_unfair_lock_lock(&pendingLock)
        if activeRequestGenerations[keyString] == generation {
            activeRequestIDs[keyString] = requestID
        } else {
            // clearCache() or the last consumer cancellation won the race while
            // requestImage was being created.
            shouldCancelImmediately = true
        }
        os_unfair_lock_unlock(&pendingLock)

        if shouldCancelImmediately {
            cachingImageManager.cancelImageRequest(requestID)
        }

        return token
    }

    /// Cancels only one consumer. The shared PhotoKit request remains alive
    /// while at least one other consumer still needs the same thumbnail.
    func cancelThumbnail(_ token: RequestToken) {
        var requestIDToCancel: PHImageRequestID?

        os_unfair_lock_lock(&pendingLock)
        guard var callbacks = pendingRequests[token.key] else {
            os_unfair_lock_unlock(&pendingLock)
            return
        }

        callbacks.removeValue(forKey: token.consumerID)
        if callbacks.isEmpty {
            pendingRequests.removeValue(forKey: token.key)
            requestIDToCancel = activeRequestIDs.removeValue(forKey: token.key)
            activeRequestGenerations.removeValue(forKey: token.key)
        } else {
            pendingRequests[token.key] = callbacks
        }
        os_unfair_lock_unlock(&pendingLock)

        if let requestIDToCancel {
            cachingImageManager.cancelImageRequest(requestIDToCancel)
        }
    }

    private func deliver(
        callbacks: [(UIImage?) -> Void],
        image: UIImage?,
        requestEpoch: UInt64
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            os_unfair_lock_lock(&self.pendingLock)
            let epochIsCurrent = self.cacheEpoch == requestEpoch
            os_unfair_lock_unlock(&self.pendingLock)

            guard epochIsCurrent else { return }
            for callback in callbacks {
                callback(image)
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
    
    /// Clear all cached thumbnails and cancel in-flight PhotoKit image work.
    /// stopCachingImagesForAllAssets() only stops preheating; it does not cancel
    /// requestImage calls already retained by this cache.
    func clearCache() {
        cachingImageManager.stopCachingImagesForAllAssets()

        os_unfair_lock_lock(&pendingLock)
        cacheEpoch &+= 1
        cache.removeAllObjects()
        let requestIDs = Array(activeRequestIDs.values)
        let callbacks = pendingRequests.values.flatMap { $0.values }
        activeRequestIDs.removeAll(keepingCapacity: false)
        activeRequestGenerations.removeAll(keepingCapacity: false)
        pendingRequests.removeAll(keepingCapacity: false)
        os_unfair_lock_unlock(&pendingLock)

        for requestID in requestIDs {
            cachingImageManager.cancelImageRequest(requestID)
        }

        if !callbacks.isEmpty {
            DispatchQueue.main.async {
                for callback in callbacks {
                    callback(nil)
                }
            }
        }

        // Clearing is intentionally separate from reloading. Memory warnings,
        // backgrounding, and hash startup must be allowed to actually shed the
        // visible-cell UIImage working set instead of immediately rebuilding it.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .thumbnailCacheDidClear, object: nil)
        }
    }

    func requestVisibleThumbnailReload() {
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState == .active else { return }
            NotificationCenter.default.post(
                name: .thumbnailCacheShouldReloadVisible,
                object: nil
            )
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
