import Foundation
import Photos
import Combine

class HashManager: ObservableObject {
    static let shared = HashManager()
    
    @Published var isProcessing: Bool = false
    @Published var processingProgress: Double = 0.0
    @Published var totalAssetsToProcess: Int = 0
    @Published var processedAssetsCount: Int = 0
    @Published var statusMessage: String = ""
    
    @Published var syncStatusCache: [String: PhotoSyncStatus] = [:]
    
    @Published var iCloudIdMatchCount: Int = 0
    
    private var processingQueue: [String] = []
    private var isHashingActive = false
    private var isCheckingActive = false
    
    private let hashQueue = DispatchQueue(label: "com.fawenyo.yaiiu.hash", qos: .utility)
    private let checkQueue = DispatchQueue(label: "com.fawenyo.yaiiu.check", qos: .utility)
    
    /// Number of concurrent hash calculations (adjust based on device capability)
    private let hashConcurrency = 3
    /// Number of concurrent server checks
    private let checkConcurrency = 5
    /// Batch size for server checks
    private let checkBatchSize = 10
    /// Batch size for iCloud ID lookups
    private let iCloudIdBatchSize = 500
    
    private var shouldStop = false
    private var hashTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    
    private init() {
        loadCachedStatus()
    }
    
    @MainActor
    func setPreparingState() {
        guard !isProcessing else { return }
        isProcessing = true
        statusMessage = "Preparing..."
        processingProgress = 0
        processedAssetsCount = 0
        totalAssetsToProcess = 0
    }
    
    @MainActor
    func clearPreparingState() {
        isProcessing = false
        statusMessage = ""
        processingProgress = 0
        processedAssetsCount = 0
        totalAssetsToProcess = 0
    }
    
    private func loadCachedStatus() {
        DatabaseManager.shared.getAllSyncStatusAsync { [weak self] statusMap in
            DispatchQueue.main.async {
                self?.syncStatusCache = statusMap
            }
        }
    }
    
    func startBackgroundProcessing(assets: [PHAsset]) {
        let identifiers = assets.map { $0.localIdentifier }
        startBackgroundProcessing(identifiers: identifiers)
    }
    
    func startBackgroundProcessing(identifiers: [String]) {
        guard !isHashingActive && !isCheckingActive else {
            return
        }
        
        shouldStop = false
        isProcessing = true
        iCloudIdMatchCount = 0
        statusMessage = "Preparing..."
        
        DatabaseManager.shared.getAssetsNeedingHashAsync(allIdentifiers: identifiers) { [weak self] needingHash in
            guard let self = self else { return }
            
            // Ensure UI updates happen on main thread
            Task { @MainActor in
                if needingHash.isEmpty {
                    self.statusMessage = "Checking cloud status..."
                    self.startServerCheck()
                } else {
                    self.tryICloudIdMatching(identifiers: needingHash) { remainingNeedingHash in
                        if remainingNeedingHash.isEmpty {
                            self.statusMessage = "Checking cloud status..."
                            self.startServerCheck()
                        } else {
                            self.processingQueue = remainingNeedingHash
                            self.totalAssetsToProcess = remainingNeedingHash.count
                            self.processedAssetsCount = 0
                            self.processingProgress = 0
                            self.statusMessage = "Analyzing photos (0/\(remainingNeedingHash.count))..."
                            
                            self.processHashItemsParallel()
                        }
                    }
                }
            }
        }
    }
    
    private func tryICloudIdMatching(identifiers: [String], completion: @escaping ([String]) -> Void) {
        guard #available(iOS 16, *) else {
            completion(identifiers)
            return
        }
        
        let hasServerCache = DatabaseManager.shared.getServerAssetsCacheCount() > 0
        guard hasServerCache else {
            completion(identifiers)
            return
        }
        
        statusMessage = "Checking iCloud ID matches..."
        
        Task {
            var remainingIdentifiers: [String] = []
            var matchCount = 0
            var identifierToICloudId: [String: String] = [:]
            let totalBatches = (identifiers.count + iCloudIdBatchSize - 1) / iCloudIdBatchSize
            for batchIndex in 0..<totalBatches {
                let start = batchIndex * iCloudIdBatchSize
                let end = min(start + iCloudIdBatchSize, identifiers.count)
                let batch = Array(identifiers[start..<end])
                
                let iCloudIdMap = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: batch)
                for (identifier, result) in iCloudIdMap {
                    if let cloudId = try? result.get() {
                        identifierToICloudId[identifier] = cloudId.stringValue
                    }
                }
            }
            
            if identifierToICloudId.isEmpty {
                await MainActor.run {
                    completion(identifiers)
                }
                return
            }
            
            let iCloudIds = Array(identifierToICloudId.values)
            let checksumMap = DatabaseManager.shared.getChecksumsByICloudIds(iCloudIds)
            
            for identifier in identifiers {
                if let iCloudId = identifierToICloudId[identifier],
                   let checksum = checksumMap[iCloudId] {
                    DatabaseManager.shared.saveMultiResourceHashCache(
                        localIdentifier: identifier,
                        primaryHash: checksum,
                        rawHash: nil,
                        hasRAW: false
                    )
                    
                    DatabaseManager.shared.updateMultiResourceHashCacheServerStatus(
                        localIdentifier: identifier,
                        primaryOnServer: true,
                        rawOnServer: false
                    )
                    
                    matchCount += 1
                    logDebug("Found hash via iCloud ID for \(identifier.prefix(20))...: \(checksum.prefix(16))...", category: .hash)
                } else {
                    remainingIdentifiers.append(identifier)
                }
            }
            
            if matchCount > 0 {
                logInfo("Found \(matchCount) hashes via iCloud ID matching, \(remainingIdentifiers.count) still need calculation", category: .hash)
            }
            
            await MainActor.run {
                self.iCloudIdMatchCount = matchCount
                completion(remainingIdentifiers)
            }
        }
    }
    
    /// Process hash calculations in parallel with controlled concurrency
    private func processHashItemsParallel() {
        guard !shouldStop else {
            finishProcessing()
            return
        }
        
        guard !processingQueue.isEmpty else {
            statusMessage = "Checking cloud status..."
            startServerCheck()
            return
        }
        
        isHashingActive = true
        
        // Cancel any existing task
        hashTask?.cancel()
        
        hashTask = Task { [weak self] in
            guard let self = self else { return }
            
            // Create a copy of the queue
            let identifiersToProcess = self.processingQueue
            
            await MainActor.run {
                self.processingQueue.removeAll()
            }
            
            // Process in parallel with controlled concurrency using TaskGroup
            await withTaskGroup(of: (String, Bool).self) { group in
                var activeCount = 0
                var index = 0
                
                while index < identifiersToProcess.count || activeCount > 0 {
                    // Add tasks up to concurrency limit
                    while activeCount < self.hashConcurrency && index < identifiersToProcess.count {
                        guard !self.shouldStop else { break }
                        
                        let identifier = identifiersToProcess[index]
                        index += 1
                        activeCount += 1
                        
                        // Update status to processing
                        await MainActor.run {
                            self.syncStatusCache[identifier] = .processing
                            self.objectWillChange.send()
                        }
                        
                        group.addTask {
                            await self.processHashForAsset(identifier: identifier)
                            return (identifier, true)
                        }
                    }
                    
                    // Wait for one task to complete
                    if let _ = await group.next() {
                        activeCount -= 1
                        
                        await MainActor.run {
                            self.processedAssetsCount += 1
                            self.processingProgress = Double(self.processedAssetsCount) / Double(self.totalAssetsToProcess)
                            self.statusMessage = "Analyzing photos (\(self.processedAssetsCount)/\(self.totalAssetsToProcess))..."
                        }
                    }
                    
                    if self.shouldStop {
                        group.cancelAll()
                        break
                    }
                }
            }
            
            // Continue to server check after hashing
            await MainActor.run {
                if !self.shouldStop {
                    self.statusMessage = "Checking cloud status..."
                    self.startServerCheck()
                } else {
                    self.finishProcessing()
                }
            }
        }
    }
    
    private func processHashForAsset(identifier: String) async {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        
        guard let asset = fetchResult.firstObject else {
            await MainActor.run {
                self.syncStatusCache[identifier] = .error
                self.objectWillChange.send()
            }
            return
        }
        
        do {
            // Use multi-resource hash to capture both JPEG and RAW hashes
            let result = try await HashService.shared.calculateMultiResourceHash(for: asset)
            
            DatabaseManager.shared.saveMultiResourceHashCache(
                localIdentifier: result.localIdentifier,
                primaryHash: result.primaryHash,
                rawHash: result.rawHash,
                hasRAW: result.hasRAW
            )
            
            await MainActor.run {
                self.syncStatusCache[identifier] = .pending
                self.objectWillChange.send()
            }
            
        } catch {
            await MainActor.run {
                self.syncStatusCache[identifier] = .error
                self.objectWillChange.send()
            }
        }
    }
    
    private func startServerCheck() {
        guard !shouldStop else {
            finishProcessing()
            return
        }
        
        isCheckingActive = true
        
        // Get all multi-resource hashes that are not fully on server
        // For JPEG+RAW assets, both must be verified
        DatabaseManager.shared.getMultiResourceHashesNotFullyOnServerAsync { [weak self] records in
            guard let self = self else { return }
            
            // Ensure UI updates happen on main thread
            Task { @MainActor in
                if records.isEmpty {
                    self.finishProcessing()
                    return
                }
                
                self.totalAssetsToProcess = records.count
                self.processedAssetsCount = 0
                self.statusMessage = "Checking cloud status (0/\(records.count))..."
                
                self.checkMultiResourceHashesAgainstCache(records: records)
            }
        }
    }
    
    private func checkMultiResourceHashesAgainstCache(records: [MultiResourceHashRecord]) {
        guard !shouldStop else {
            finishProcessing()
            return
        }
        
        guard !records.isEmpty else {
            finishProcessing()
            return
        }
        
        // Cancel any existing task
        checkTask?.cancel()
        
        checkTask = Task { [weak self] in
            guard let self = self else { return }
            
            // First, filter out deleted photos and collect orphan identifiers
            let allIdentifiers = records.map { $0.assetId }
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: allIdentifiers, options: nil)
            
            var existingIdentifiers = Set<String>()
            fetchResult.enumerateObjects { (asset, _, _) in
                existingIdentifiers.insert(asset.localIdentifier)
            }
            
            // Find orphan records (in database but no longer in Photo Library)
            var orphanIdentifiers: [String] = []
            var validRecords: [MultiResourceHashRecord] = []
            
            for record in records {
                if existingIdentifiers.contains(record.assetId) {
                    validRecords.append(record)
                } else {
                    orphanIdentifiers.append(record.assetId)
                }
            }
            
            // Clean up orphan records from database
            if !orphanIdentifiers.isEmpty {
                logInfo("Cleaning up \(orphanIdentifiers.count) orphan hash cache records for deleted photos", category: .hash)
                DatabaseManager.shared.batchDeleteHashCacheRecords(localIdentifiers: orphanIdentifiers)
                
                // Also remove from memory cache
                await MainActor.run {
                    for identifier in orphanIdentifiers {
                        self.syncStatusCache.removeValue(forKey: identifier)
                    }
                    self.objectWillChange.send()
                }
            }
            
            // Update count to only include valid records
            if validRecords.isEmpty {
                await MainActor.run {
                    self.finishProcessing()
                }
                return
            }
            
            await MainActor.run {
                self.totalAssetsToProcess = validRecords.count
                self.processedAssetsCount = 0
                self.statusMessage = "Checking cloud status (0/\(validRecords.count))..."
            }
            
            // Check if server assets cache has been synced
            let hasServerCache = DatabaseManager.shared.getServerAssetsCacheCount() > 0
            
            for record in validRecords {
                guard !self.shouldStop else { break }
                
                let localIdentifier = record.assetId
                
                await MainActor.run {
                    self.syncStatusCache[localIdentifier] = .checking
                    self.objectWillChange.send()
                }
                
                var primaryOnServer = record.primaryOnServer
                var rawOnServer = record.rawOnServer
                
                // Check primary hash against server
                if !primaryOnServer {
                    if DatabaseManager.shared.isAssetUploaded(localIdentifier: localIdentifier, resourceType: "primary") ||
                       DatabaseManager.shared.isAssetUploaded(localIdentifier: localIdentifier, resourceType: "photo") {
                        primaryOnServer = true
                    } else if hasServerCache {
                        primaryOnServer = DatabaseManager.shared.isAssetOnServer(checksum: record.primaryHash)
                    }
                }
                
                // Check RAW hash against server if asset has RAW
                if record.hasRAW && !rawOnServer {
                    if DatabaseManager.shared.isAssetUploaded(localIdentifier: localIdentifier, resourceType: "raw") {
                        rawOnServer = true
                    } else if hasServerCache, let rawHash = record.rawHash {
                        rawOnServer = DatabaseManager.shared.isAssetOnServer(checksum: rawHash)
                    }
                }
                
                // Update database with multi-resource status
                DatabaseManager.shared.updateMultiResourceHashCacheServerStatus(
                    localIdentifier: localIdentifier,
                    primaryOnServer: primaryOnServer,
                    rawOnServer: rawOnServer
                )
                
                // Determine final upload status
                // For JPEG+RAW: both must be on server
                // For non-RAW: only primary needs to be on server
                let isFullyUploaded: Bool
                if record.hasRAW {
                    isFullyUploaded = primaryOnServer && rawOnServer
                } else {
                    isFullyUploaded = primaryOnServer
                }
                
                await MainActor.run {
                    self.processedAssetsCount += 1
                    self.processingProgress = Double(self.processedAssetsCount) / Double(self.totalAssetsToProcess)
                    self.statusMessage = "Checking cloud status (\(self.processedAssetsCount)/\(self.totalAssetsToProcess))..."
                    
                    if isFullyUploaded {
                        self.syncStatusCache[localIdentifier] = .uploaded
                    } else {
                        // Not uploaded - show as not uploaded regardless of server cache
                        self.syncStatusCache[localIdentifier] = .notUploaded
                    }
                    self.objectWillChange.send()
                }
            }
            
            await MainActor.run {
                self.finishProcessing()
            }
        }
    }
    
    private func finishProcessing() {
        isProcessing = false
        isHashingActive = false
        isCheckingActive = false
        statusMessage = ""
        processingProgress = 1.0
        
        loadCachedStatus()
    }
    
    func stopProcessing() {
        shouldStop = true
        statusMessage = "Stopping..."
        hashTask?.cancel()
        checkTask?.cancel()
    }
    
    func getSyncStatus(for localIdentifier: String) -> PhotoSyncStatus {
        return syncStatusCache[localIdentifier] ?? .pending
    }
    
    func refreshStatusCache() {
        loadCachedStatus()
    }
    
    @MainActor
    func refreshStatusCacheAsync() async {
        let statusMap = await withCheckedContinuation { continuation in
            DatabaseManager.shared.getAllSyncStatusAsync { statusMap in
                continuation.resume(returning: statusMap)
            }
        }
        
        // Batch update to reduce view invalidation overhead
        if statusMap != self.syncStatusCache {
            self.syncStatusCache = statusMap
        }
    }
    
    func forceReprocess(assets: [PHAsset]) {
        DatabaseManager.shared.clearHashCache()
        syncStatusCache.removeAll()
        
        startBackgroundProcessing(assets: assets)
    }
}
