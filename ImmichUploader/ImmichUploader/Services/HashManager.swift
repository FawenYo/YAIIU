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
    
    private var processingQueue: [String] = []
    private var isHashingActive = false
    private var isCheckingActive = false
    
    private let hashQueue = DispatchQueue(label: "com.immichuploader.hash", qos: .utility)
    private let checkQueue = DispatchQueue(label: "com.immichuploader.check", qos: .utility)
    
    /// Number of concurrent hash calculations (adjust based on device capability)
    private let hashConcurrency = 3
    /// Number of concurrent server checks
    private let checkConcurrency = 5
    /// Batch size for server checks
    private let checkBatchSize = 10
    
    private var shouldStop = false
    private var hashTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    
    private init() {
        loadCachedStatus()
    }
    
    private func loadCachedStatus() {
        DatabaseManager.shared.getAllSyncStatusAsync { [weak self] statusMap in
            self?.syncStatusCache = statusMap
        }
    }
    
    func startBackgroundProcessing(assets: [PHAsset]) {
        let identifiers = assets.map { $0.localIdentifier }
        startBackgroundProcessing(identifiers: identifiers)
    }
    
    func startBackgroundProcessing(identifiers: [String]) {
        guard !isProcessing else {
            return
        }
        
        shouldStop = false
        isProcessing = true
        statusMessage = "Preparing..."
        
        DatabaseManager.shared.getAssetsNeedingHashAsync(allIdentifiers: identifiers) { [weak self] needingHash in
            guard let self = self else { return }
            
            if needingHash.isEmpty {
                self.statusMessage = "Checking cloud status..."
                self.startServerCheck()
            } else {
                self.processingQueue = needingHash
                self.totalAssetsToProcess = needingHash.count
                self.processedAssetsCount = 0
                self.processingProgress = 0
                self.statusMessage = "Analyzing photos (0/\(needingHash.count))..."
                
                self.processHashItemsParallel()
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
    
    /// Process hash for a single asset
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
            let result = try await HashService.shared.calculateHash(for: asset)
            
            DatabaseManager.shared.saveHashCache(
                localIdentifier: result.localIdentifier,
                sha1Hash: result.sha1Hash,
                fileSize: result.fileSize,
                syncStatus: "pending"
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
        
        let settingsManager = SettingsManager()
        let serverURL = settingsManager.serverURL
        let apiKey = settingsManager.apiKey
        
        guard !serverURL.isEmpty && !apiKey.isEmpty else {
            finishProcessing()
            return
        }
        
        isCheckingActive = true
        
        DatabaseManager.shared.getHashesNeedingCheckAsync { [weak self] hashes in
            guard let self = self else { return }
            
            if hashes.isEmpty {
                self.finishProcessing()
                return
            }
            
            self.totalAssetsToProcess = hashes.count
            self.processedAssetsCount = 0
            self.statusMessage = "Checking cloud status (0/\(hashes.count))..."
            
            self.checkHashesParallel(hashes: hashes, serverURL: serverURL, apiKey: apiKey)
        }
    }
    
    /// Check hashes in parallel with controlled concurrency
    private func checkHashesParallel(hashes: [(String, String)], serverURL: String, apiKey: String) {
        guard !shouldStop else {
            finishProcessing()
            return
        }
        
        guard !hashes.isEmpty else {
            finishProcessing()
            return
        }
        
        // Cancel any existing task
        checkTask?.cancel()
        
        checkTask = Task { [weak self] in
            guard let self = self else { return }
            
            // Process in parallel with controlled concurrency
            await withTaskGroup(of: (String, Bool, Bool).self) { group in
                var activeCount = 0
                var index = 0
                
                while index < hashes.count || activeCount > 0 {
                    // Add tasks up to concurrency limit
                    while activeCount < self.checkConcurrency && index < hashes.count {
                        guard !self.shouldStop else { break }
                        
                        let (localIdentifier, sha1Hash) = hashes[index]
                        index += 1
                        activeCount += 1
                        
                        // Update status to checking
                        await MainActor.run {
                            self.syncStatusCache[localIdentifier] = .checking
                            self.objectWillChange.send()
                        }
                        
                        group.addTask {
                            do {
                                let isOnServer = try await ImmichAPIService.shared.checkAssetExists(
                                    checksum: sha1Hash,
                                    serverURL: serverURL,
                                    apiKey: apiKey
                                )
                                return (localIdentifier, isOnServer, true)
                            } catch {
                                return (localIdentifier, false, false)
                            }
                        }
                    }
                    
                    // Wait for one task to complete
                    if let (localIdentifier, isOnServer, success) = await group.next() {
                        activeCount -= 1
                        
                        if success {
                            DatabaseManager.shared.updateHashCacheServerStatus(
                                localIdentifier: localIdentifier,
                                isOnServer: isOnServer,
                                syncStatus: "checked"
                            )
                        }
                        
                        await MainActor.run {
                            self.processedAssetsCount += 1
                            self.processingProgress = Double(self.processedAssetsCount) / Double(self.totalAssetsToProcess)
                            self.statusMessage = "Checking cloud status (\(self.processedAssetsCount)/\(self.totalAssetsToProcess))..."
                            self.syncStatusCache[localIdentifier] = success ? (isOnServer ? .uploaded : .notUploaded) : .error
                            self.objectWillChange.send()
                        }
                    }
                    
                    if self.shouldStop {
                        group.cancelAll()
                        break
                    }
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
    
    func forceReprocess(assets: [PHAsset]) {
        DatabaseManager.shared.clearHashCache()
        syncStatusCache.removeAll()
        
        startBackgroundProcessing(assets: assets)
    }
}
