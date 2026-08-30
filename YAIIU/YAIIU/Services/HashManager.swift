import Foundation
import Photos
import Combine

enum HashPipelinePolicy {
    static func processSerially<Element>(
        _ elements: [Element],
        operation: (Element) async -> Void
    ) async {
        for element in elements {
            guard !Task.isCancelled else { break }
            await operation(element)
        }
    }

    struct RunState {
        private(set) var currentRunID: UUID?

        mutating func begin() -> UUID {
            let runID = UUID()
            currentRunID = runID
            return runID
        }

        mutating func invalidate() {
            currentRunID = nil
        }

        func owns(_ runID: UUID) -> Bool {
            currentRunID == runID
        }
    }
}

class HashManager: ObservableObject {
    static let shared = HashManager()
    
    @Published var isProcessing: Bool = false
    @Published var processingProgress: Double = 0.0
    @Published var totalAssetsToProcess: Int = 0
    @Published var processedAssetsCount: Int = 0
    @Published var statusMessage: String = ""
    
    @Published var syncStatusCache: [String: PhotoSyncStatus] = [:]
    
    @Published var iCloudIdMatchCount: Int = 0

    /// Assets that were found on server by checksum but have no iCloudId recorded.
    /// Consumers should read this after isProcessing becomes false and push updates to the server.
    @Published var pendingICloudIdUpdates: [(immichId: String, iCloudId: String)] = []
    
    private var processingQueue: [String] = []
    private var isHashingActive = false
    private var isCheckingActive = false
    
    private let checkQueue = DispatchQueue(label: "com.fawenyo.yaiiu.check", qos: .utility)
    
    /// Number of concurrent server checks
    private let checkConcurrency = 5
    /// Batch size for server checks
    private let checkBatchSize = 10
    /// Batch size for iCloud ID lookups
    private let iCloudIdBatchSize = 500
    
    private var shouldStop = false
    private var hashTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var matchingTask: Task<Void, Never>?
    private var runState = HashPipelinePolicy.RunState()
    
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
                guard let self, !self.isProcessing else { return }
                self.syncStatusCache = statusMap
            }
        }
    }
    
    func startBackgroundProcessing(assets: [PHAsset]) {
        // Invalidate modified assets before the normal refresh pipeline
        DatabaseManager.shared.resetCacheForModifiedAssets(assets: assets)
        startBackgroundProcessing(identifiers: assets.map { $0.localIdentifier })
    }

    func startBackgroundProcessing(identifiers: [String]) {
        guard !isHashingActive && !isCheckingActive else { return }

        let runID = runState.begin()
        shouldStop = false
        isProcessing = true
        iCloudIdMatchCount = 0
        pendingICloudIdUpdates = []
        statusMessage = "Preparing..."
        logInfo("Hash pipeline started: identifiers=\(identifiers.count)", category: .hash)

        // identifiers-only path cannot compare modificationDate; no invalidation here
        DatabaseManager.shared.getAssetsNeedingHashAsync(allIdentifiers: identifiers) { [weak self] needingHash in
            guard let self = self else { return }
            logInfo("Hash cache lookup complete: total=\(identifiers.count), needingHash=\(needingHash.count)", category: .hash)

            Task { @MainActor in
                guard self.isCurrentRun(runID), !self.shouldStop else {
                    self.finishProcessing(runID: runID)
                    return
                }
                if needingHash.isEmpty {
                    self.statusMessage = "Checking cloud status..."
                    self.startServerCheck(runID: runID)
                } else {
                    self.tryICloudIdMatching(identifiers: needingHash, runID: runID) { remainingNeedingHash in
                        guard self.isCurrentRun(runID), !self.shouldStop else {
                            self.finishProcessing(runID: runID)
                            return
                        }
                        if remainingNeedingHash.isEmpty {
                            self.statusMessage = "Checking cloud status..."
                            self.startServerCheck(runID: runID)
                        } else {
                            self.processingQueue = remainingNeedingHash
                            self.totalAssetsToProcess = remainingNeedingHash.count
                            self.processedAssetsCount = 0
                            self.processingProgress = 0
                            self.statusMessage = "Analyzing photos (0/\(remainingNeedingHash.count))..."

                            self.processHashItemsSerially(runID: runID)
                        }
                    }
                }
            }
        }
    }
    
    private func tryICloudIdMatching(identifiers: [String], runID: UUID, completion: @escaping ([String]) -> Void) {
        guard #available(iOS 16, *) else {
            guard isCurrentRun(runID), !shouldStop else { return }
            completion(identifiers)
            return
        }
        
        let hasServerCache = DatabaseManager.shared.getServerAssetsCacheCount() > 0
        guard hasServerCache else {
            logInfo("iCloud ID matching skipped: server cache empty, candidates=\(identifiers.count)", category: .hash)
            guard isCurrentRun(runID), !shouldStop else { return }
            completion(identifiers)
            return
        }
        
        statusMessage = "Checking iCloud ID matches..."
        let matchingStartedAt = Date()
        logInfo("iCloud ID matching started: candidates=\(identifiers.count)", category: .hash)
        
        matchingTask?.cancel()
        matchingTask = Task {
            var remainingIdentifiers: [String] = []
            var matchCount = 0
            var identifierToICloudId: [String: String] = [:]
            let totalBatches = (identifiers.count + iCloudIdBatchSize - 1) / iCloudIdBatchSize
            for batchIndex in 0..<totalBatches {
                guard !Task.isCancelled, self.isCurrentRun(runID) else {
                    await MainActor.run { self.finishProcessing(runID: runID) }
                    return
                }
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

            logInfo(
                "iCloud ID mapping complete: mapped=\(identifierToICloudId.count), elapsed=\(String(format: "%.2f", Date().timeIntervalSince(matchingStartedAt)))s",
                category: .hash
            )
            
            guard !Task.isCancelled, self.isCurrentRun(runID) else {
                await MainActor.run { self.finishProcessing(runID: runID) }
                return
            }

            if identifierToICloudId.isEmpty {
                await MainActor.run {
                    guard !Task.isCancelled, self.isCurrentRun(runID), !self.shouldStop else {
                        self.finishProcessing(runID: runID)
                        return
                    }
                    completion(identifiers)
                }
                return
            }
            
            guard !Task.isCancelled, self.isCurrentRun(runID) else {
                await MainActor.run { self.finishProcessing(runID: runID) }
                return
            }
            let iCloudIds = Array(identifierToICloudId.values)
            let checksumMap = DatabaseManager.shared.getChecksumsByICloudIds(iCloudIds)
            logInfo(
                "Remote checksum lookup complete: requested=\(iCloudIds.count), matched=\(checksumMap.count), elapsed=\(String(format: "%.2f", Date().timeIntervalSince(matchingStartedAt)))s",
                category: .hash
            )
            
            for identifier in identifiers {
                guard !Task.isCancelled, self.isCurrentRun(runID) else {
                    await MainActor.run { self.finishProcessing(runID: runID) }
                    return
                }
                if let iCloudId = identifierToICloudId[identifier],
                   let checksum = checksumMap[iCloudId] {
                    guard !Task.isCancelled, self.isCurrentRun(runID) else { return }
                    DatabaseManager.shared.saveMultiResourceHashCache(
                        localIdentifier: identifier,
                        primaryHash: checksum,
                        rawHash: nil,
                        hasRAW: false
                    )
                    guard !Task.isCancelled, self.isCurrentRun(runID) else { return }
                    
                    DatabaseManager.shared.updateMultiResourceHashCacheServerStatus(
                        localIdentifier: identifier,
                        primaryOnServer: true,
                        rawOnServer: false
                    )
                    
                    matchCount += 1
                } else {
                    remainingIdentifiers.append(identifier)
                }
            }
            
            if matchCount > 0 {
                logInfo("Found \(matchCount) hashes via iCloud ID matching, \(remainingIdentifiers.count) still need calculation", category: .hash)
            }
            
            await MainActor.run {
                guard !Task.isCancelled, self.isCurrentRun(runID), !self.shouldStop else {
                    self.finishProcessing(runID: runID)
                    return
                }
                self.iCloudIdMatchCount = matchCount
                logInfo("iCloud ID matching finished: matched=\(matchCount), remaining=\(remainingIdentifiers.count), elapsed=\(String(format: "%.2f", Date().timeIntervalSince(matchingStartedAt)))s", category: .hash)
                completion(remainingIdentifiers)
            }
        }
    }
    
    /// Processes one PhotoKit resource request at a time. PhotoKit controls chunk
    /// delivery and may retain buffers until completion, so overlapping requests
    /// can multiply peak memory for large photos, RAW files, and videos.
    private func processHashItemsSerially(runID: UUID) {
        guard isCurrentRun(runID), !shouldStop else {
            finishProcessing(runID: runID)
            return
        }

        guard !processingQueue.isEmpty else {
            statusMessage = "Checking cloud status..."
            startServerCheck(runID: runID)
            return
        }

        isHashingActive = true
        hashTask?.cancel()

        hashTask = Task { [weak self] in
            guard let self = self else { return }

            let identifiersToProcess = self.processingQueue
            await MainActor.run {
                self.processingQueue.removeAll(keepingCapacity: false)
            }

            await HashPipelinePolicy.processSerially(identifiersToProcess) { identifier in
                guard self.isCurrentRun(runID), !self.shouldStop else { return }

                await MainActor.run {
                    guard self.isCurrentRun(runID) else { return }
                    self.syncStatusCache[identifier] = .processing
                    self.objectWillChange.send()
                }

                await self.processHashForAsset(identifier: identifier, runID: runID)

                await MainActor.run {
                    guard self.isCurrentRun(runID) else { return }
                    self.processedAssetsCount += 1
                    self.processingProgress = Double(self.processedAssetsCount) / Double(self.totalAssetsToProcess)
                    self.statusMessage = "Analyzing photos (\(self.processedAssetsCount)/\(self.totalAssetsToProcess))..."
                }
            }

            await MainActor.run {
                if self.isCurrentRun(runID), !self.shouldStop, !Task.isCancelled {
                    self.statusMessage = "Checking cloud status..."
                    self.startServerCheck(runID: runID)
                } else {
                    self.finishProcessing(runID: runID)
                }
            }
        }
    }
    
    private func processHashForAsset(identifier: String, runID: UUID) async {
        let hashStartedAt = Date()
        logInfo("Hash started: asset=\(identifier)", category: .hash)
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard isCurrentRun(runID), !shouldStop else { return }
        
        guard let asset = fetchResult.firstObject else {
            await MainActor.run {
                guard self.isCurrentRun(runID) else { return }
                self.syncStatusCache[identifier] = .error
                self.objectWillChange.send()
            }
            return
        }
        
        do {
            // Use multi-resource hash to capture both JPEG and RAW hashes
            let result = try await HashService.shared.calculateMultiResourceHash(for: asset)
            guard isCurrentRun(runID), !shouldStop else { return }
            logInfo(
                "Hash finished: asset=\(identifier), primaryBytes=\(result.primaryFileSize), rawBytes=\(result.rawFileSize ?? 0), hasRAW=\(result.hasRAW), elapsed=\(String(format: "%.2f", Date().timeIntervalSince(hashStartedAt)))s",
                category: .hash
            )
            
            DatabaseManager.shared.saveMultiResourceHashCache(
                localIdentifier: result.localIdentifier,
                primaryHash: result.primaryHash,
                rawHash: result.rawHash,
                hasRAW: result.hasRAW,
                modificationDate: asset.modificationDate
            )
            guard isCurrentRun(runID) else { return }
            
            await MainActor.run {
                guard self.isCurrentRun(runID) else { return }
                self.syncStatusCache[identifier] = .pending
                self.objectWillChange.send()
            }
            
        } catch {
            logError("Hash failed: asset=\(identifier), elapsed=\(String(format: "%.2f", Date().timeIntervalSince(hashStartedAt)))s, error=\(error.localizedDescription)", category: .hash)
            await MainActor.run {
                guard self.isCurrentRun(runID) else { return }
                self.syncStatusCache[identifier] = .error
                self.objectWillChange.send()
            }
        }
    }
    
    private func startServerCheck(runID: UUID) {
        guard isCurrentRun(runID), !shouldStop else {
            finishProcessing(runID: runID)
            return
        }
        
        isCheckingActive = true
        
        // Get all multi-resource hashes that are not fully on server
        // For JPEG+RAW assets, both must be verified
        DatabaseManager.shared.getMultiResourceHashesNotFullyOnServerAsync { [weak self] records in
            guard let self = self else { return }
            
            // Ensure UI updates happen on main thread
            Task { @MainActor in
                guard self.isCurrentRun(runID) else { return }
                if records.isEmpty {
                    self.finishProcessing(runID: runID)
                    return
                }

                self.totalAssetsToProcess = records.count
                self.processedAssetsCount = 0
                self.statusMessage = "Checking cloud status (0/\(records.count))..."

                self.checkMultiResourceHashesAgainstCache(records: records, runID: runID)
            }
        }
    }
    
    private func checkMultiResourceHashesAgainstCache(records: [MultiResourceHashRecord], runID: UUID) {
        guard isCurrentRun(runID), !shouldStop else {
            finishProcessing(runID: runID)
            return
        }
        
        guard !records.isEmpty else {
            finishProcessing(runID: runID)
            return
        }
        
        // Cancel any existing task
        checkTask?.cancel()
        
        checkTask = Task { [weak self] in
            guard let self = self else { return }
            guard self.isCurrentRun(runID), !Task.isCancelled else { return }
            
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
            guard self.isCurrentRun(runID), !Task.isCancelled else { return }

            if !orphanIdentifiers.isEmpty {
                logInfo("Cleaning up \(orphanIdentifiers.count) orphan hash cache records for deleted photos", category: .hash)
                DatabaseManager.shared.batchDeleteHashCacheRecords(localIdentifiers: orphanIdentifiers)
                
                // Also remove from memory cache
                await MainActor.run {
                    guard self.isCurrentRun(runID) else { return }
                    for identifier in orphanIdentifiers {
                        self.syncStatusCache.removeValue(forKey: identifier)
                    }
                    self.objectWillChange.send()
                }
                guard self.isCurrentRun(runID), !Task.isCancelled else { return }
            }
            
            // Update count to only include valid records
            if validRecords.isEmpty {
                await MainActor.run {
                    self.finishProcessing(runID: runID)
                }
                return
            }
            
            await MainActor.run {
                guard self.isCurrentRun(runID) else { return }
                self.totalAssetsToProcess = validRecords.count
                self.processedAssetsCount = 0
                self.statusMessage = "Checking cloud status (0/\(validRecords.count))..."
            }
            
            // Check if server assets cache has been synced
            let hasServerCache = DatabaseManager.shared.getServerAssetsCacheCount() > 0

            // Preload localIdentifier → immichId map from upload records for iCloudId backfill
            let uploadedMappings = DatabaseManager.shared.getAllUploadedAssetMappings()
            let localToImmichId: [String: String] = Dictionary(uploadedMappings.map { ($0.localIdentifier, $0.immichId) }, uniquingKeysWith: { first, _ in first })

            // Preload current user ID from sync metadata to filter out partner assets
            let currentUserId = DatabaseManager.shared.getSyncMetadata()?.userId

            // Preload iCloudIds for all valid record identifiers
            var localToCloudId: [String: String] = [:]
            if #available(iOS 16, *) {
                let allIds = validRecords.map { $0.assetId }
                let cloudMappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: allIds)
                for (localId, result) in cloudMappings {
                    if let cloudId = try? result.get(), !cloudId.stringValue.hasSuffix(":") {
                        localToCloudId[localId] = cloudId.stringValue
                    }
                }
                guard self.isCurrentRun(runID), !Task.isCancelled else { return }
            }
            
            for record in validRecords {
                guard self.isCurrentRun(runID), !self.shouldStop else { break }
                
                let localIdentifier = record.assetId
                
                guard self.isCurrentRun(runID), !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.isCurrentRun(runID) else { return }
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
                    } else if !record.hasRAW &&
                              DatabaseManager.shared.isAssetUploaded(localIdentifier: localIdentifier, resourceType: "raw") {
                        primaryOnServer = true
                    } else if hasServerCache {
                        primaryOnServer = DatabaseManager.shared.isAssetOnServer(checksum: record.primaryHash)
                    }
                }

                // Queue iCloudId update if asset is on server but server cache has no iCloudId
                if primaryOnServer {
                    if let iCloudId = localToCloudId[localIdentifier] {
                        if let immichId = localToImmichId[localIdentifier] {
                            await MainActor.run {
                                guard self.isCurrentRun(runID) else { return }
                                self.pendingICloudIdUpdates.append((immichId: immichId, iCloudId: iCloudId))
                            }
                        } else if let serverAsset = DatabaseManager.shared.getServerAssetByChecksum(record.primaryHash),
                                  serverAsset.iCloudId != iCloudId,
                                  currentUserId == nil || serverAsset.ownerId == currentUserId {
                            await MainActor.run {
                                guard self.isCurrentRun(runID) else { return }
                                self.pendingICloudIdUpdates.append((immichId: serverAsset.immichId, iCloudId: iCloudId))
                            }
                        }
                    } else {
                        logInfo("Asset \(localIdentifier) on server but no valid iCloud ID (iCloud sync incomplete?)", category: .hash)
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
                guard self.isCurrentRun(runID), !Task.isCancelled else { return }
                
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
                guard self.isCurrentRun(runID), !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.isCurrentRun(runID) else { return }
                    self.processedAssetsCount += 1
                    self.processingProgress = Double(self.processedAssetsCount) / Double(self.totalAssetsToProcess)
                    self.statusMessage = "Checking cloud status (\(self.processedAssetsCount)/\(self.totalAssetsToProcess))..."

                    if isFullyUploaded {
                        self.syncStatusCache[localIdentifier] = .uploaded
                    } else {
                        self.syncStatusCache[localIdentifier] = .notUploaded
                    }
                    self.objectWillChange.send()
                }
            }
            
            await MainActor.run {
                self.finishProcessing(runID: runID)
            }
        }
    }
    
    private func finishProcessing(runID: UUID) {
        guard isCurrentRun(runID) else { return }
        runState.invalidate()
        isProcessing = false
        isHashingActive = false
        isCheckingActive = false
        statusMessage = ""
        processingProgress = 1.0

        loadCachedStatus()
    }
    
    func stopProcessing() {
        runState.invalidate()
        shouldStop = true
        isProcessing = false
        isHashingActive = false
        isCheckingActive = false
        statusMessage = ""
        hashTask?.cancel()
        checkTask?.cancel()
        matchingTask?.cancel()
    }

    private func isCurrentRun(_ runID: UUID) -> Bool {
        runState.owns(runID)
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
