import Foundation
import Photos
import Combine

/// FIFO admission to a shared resource budget (bytes or slots) with
/// cancellation-safe async acquisition. Acquisition returns false when the
/// waiting task is cancelled before admission, so callers never release a
/// reservation they do not hold. An amount larger than the whole limit is
/// admitted alone while idle, so oversized items cannot starve.
final class ResourceBudget: @unchecked Sendable {
    private final class Waiter: @unchecked Sendable {
        let amount: Int64
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var isAdmitted = false

        init(amount: Int64) { self.amount = amount }

        /// Returns true when already admitted and the caller must resume itself.
        func install(_ continuation: CheckedContinuation<Bool, Never>) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if isAdmitted { return true }
            self.continuation = continuation
            return false
        }

        /// Returns the continuation to resume with success, if not cancelled.
        func admit() -> CheckedContinuation<Bool, Never>? {
            lock.lock()
            defer { lock.unlock() }
            guard !isCancelledFlag else { return nil }
            isAdmitted = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }

        private var isCancelledFlag = false

        /// Marks cancellation; resumes with false unless already admitted.
        /// Returns false when admission already happened.
        func cancelWaiting() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if isAdmitted { return false }
            isCancelledFlag = true
            let continuation = self.continuation
            self.continuation = nil
            continuation?.resume(returning: false)
            return true
        }
    }

    private let lock = NSLock()
    private let limit: Int64
    private var available: Int64
    private var waiters: [Waiter] = []

    init(limit: Int64) {
        self.limit = limit
        self.available = limit
    }

    /// true = reserved (caller MUST release); false = cancelled before admission.
    func acquire(_ amount: Int64) async -> Bool {
        let waiter = Waiter(amount: amount)
        lock.lock()
        if waiters.isEmpty, amount <= available || available == limit {
            available -= amount
            lock.unlock()
            return true
        }
        waiters.append(waiter)
        drainLocked()
        lock.unlock()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if waiter.install(continuation) {
                    continuation.resume(returning: true)
                }
            }
        } onCancel: {
            lock.lock()
            if let index = waiters.firstIndex(where: { $0 === waiter }) {
                waiters.remove(at: index)
            }
            _ = waiter.cancelWaiting()
            drainLocked()
            lock.unlock()
        }
    }

    func release(_ amount: Int64) {
        lock.lock()
        available += amount
        drainLocked()
        lock.unlock()
    }

    /// Reconciles a held reservation with the actual amount consumed. Never
    /// blocks: temp files are already on disk, so overdrawn availability just
    /// delays the next admission until the extra is released.
    func adjust(from old: Int64, to new: Int64) {
        lock.lock()
        available += old - new
        drainLocked()
        lock.unlock()
    }

    /// Caller holds the lock. Admits the queue head only (strict FIFO).
    private func drainLocked() {
        while let first = waiters.first {
            if first.amount <= available || (available == limit && waiters.count == 1) {
                waiters.removeFirst()
                available -= first.amount
                first.admit()?.resume(returning: true)
            } else {
                break
            }
        }
    }
}

enum HashPipelinePolicy {
    /// Runs operations with at most `limit` in flight (FIFO order, bounded
    /// window: one completion admits the next element).
    static func processConcurrently<Element: Sendable>(
        _ elements: [Element],
        limit: Int,
        operation: @escaping @Sendable (Element) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            let limit = max(1, Swift.min(limit, elements.count))
            var index = 0
            var inFlight = 0

            func addNext() {
                guard index < elements.count, inFlight < limit else { return }
                let element = elements[index]
                index += 1
                inFlight += 1
                group.addTask {
                    guard !Task.isCancelled else { return }
                    await operation(element)
                }
            }

            while inFlight < limit, index < elements.count { addNext() }

            while inFlight > 0 {
                _ = await group.next()
                inFlight -= 1
                addNext()
            }
        }
    }

    static func admitIfIdle(
        using state: RunState,
        performSideEffects: (UUID) -> Void
    ) -> UUID? {
        guard let runID = state.beginIfIdle() else { return nil }
        performSideEffects(runID)
        return runID
    }

    final class RunState: @unchecked Sendable {
        private enum Phase {
            case idle
            case running(UUID)
            case stopping
        }

        private let lock = NSLock()
        private var phase = Phase.idle

        func beginIfIdle() -> UUID? {
            let runID = UUID()
            lock.lock()
            defer { lock.unlock() }
            guard case .idle = phase else { return nil }
            phase = .running(runID)
            return runID
        }

        func finish(_ runID: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard case .running(runID) = phase else { return false }
            phase = .idle
            return true
        }

        func beginStopping() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard case .stopping = phase else {
                phase = .stopping
                return true
            }
            return false
        }

        func finishStopping() {
            lock.lock()
            if case .stopping = phase {
                phase = .idle
            }
            lock.unlock()
        }

        func owns(_ runID: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard case .running(runID) = phase else { return false }
            return true
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
    private var isStopping = false
    
    private let checkQueue = DispatchQueue(label: "com.fawenyo.yaiiu.check", qos: .utility)
    
    /// Number of concurrent server checks
    private let checkConcurrency = 5
    /// Assets downloading to temp files at once. Larger than the hash gate so
    /// iCloud downloads always run ahead of hashing.
    private static let downloadWindow = 6
    /// Total bytes allowed in temp files at once. Bounds on-disk footprint
    /// independently of how many downloads are in flight; a resource larger
    /// than the whole budget is admitted alone (see ResourceBudget).
    private static let diskBudgetBytes: Int64 = 1_500 * 1024 * 1024
    /// Assets hashed concurrently. Hashing reads with a fixed buffer, so this
    /// only caps CPU/IO overlap, not memory.
    private static let hashConcurrency = 3
    /// Batch size for server checks
    private let checkBatchSize = 10
    /// Batch size for iCloud ID lookups
    private let iCloudIdBatchSize = 500
    
    private var shouldStop = false
    private var hashTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var matchingTask: Task<Void, Never>?
    private let runState = HashPipelinePolicy.RunState()
    
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
    
    @MainActor
    func startBackgroundProcessing(assets: [PHAsset]) {
        startBackgroundProcessing(
            identifiers: assets.map { $0.localIdentifier },
            assetsToInvalidate: assets
        )
    }

    @MainActor
    func startBackgroundProcessing(identifiers: [String]) {
        startBackgroundProcessing(identifiers: identifiers, assetsToInvalidate: nil)
    }

    @MainActor
    private func startBackgroundProcessing(
        identifiers: [String],
        assetsToInvalidate: [PHAsset]?,
        shouldClearCache: Bool = false
    ) {
        guard !isStopping && !isHashingActive && !isCheckingActive else { return }
        guard let runID = HashPipelinePolicy.admitIfIdle(using: runState, performSideEffects: { _ in
            if shouldClearCache {
                DatabaseManager.shared.clearHashCache()
                syncStatusCache.removeAll()
            }
            if let assetsToInvalidate {
                DatabaseManager.shared.resetCacheForModifiedAssets(assets: assetsToInvalidate)
            }
        }) else { return }
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

                            self.processHashItems(runID: runID)
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
    
    /// Producer-consumer hashing: a download window streams originals to temp
    /// files (admitted by a shared byte budget so the on-disk footprint stays
    /// bounded), while a smaller hash gate consumes finished files and deletes
    /// them right after hashing. Downloads pipeline ahead of hashing instead of
    /// being serialized behind it.
    private func processHashItems(runID: UUID) {
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

            let budget = ResourceBudget(limit: Self.diskBudgetBytes)
            let hashGate = ResourceBudget(limit: Int64(Self.hashConcurrency))
            let registry = PreparedWorkRegistry()
            var streamContinuation: AsyncStream<PreparedHashWork>.Continuation!
            // Unbounded is safe: the producer window plus the byte budget cap
            // how many prepared works can ever be queued; a dropping policy
            // would lose handoffs and leak budget reservations.
            let pending = AsyncStream<PreparedHashWork>(bufferingPolicy: .unbounded) { continuation in
                streamContinuation = continuation
            }

            // Producer and consumer are both children of hashTask so cancelling
            // the run propagates to in-flight downloads, not just hashing.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    guard let self else {
                        streamContinuation.finish()
                        return
                    }
                    await self.downloadHashItems(
                        identifiers: identifiersToProcess,
                        budget: budget,
                        registry: registry,
                        runID: runID,
                        continuation: streamContinuation
                    )
                }
                group.addTask { [weak self] in
                    await self?.consumeHashStream(pending, gate: hashGate, runID: runID)
                }
                await group.waitForAll()
            }
            // A cancelled iterator discards buffered elements; guarantee their
            // temp files and reservations are released.
            registry.sweep()

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

    /// Downloads planned resources within the budget and publishes prepared
    /// temp files to `continuation`; also owns per-asset status UI.
    private func downloadHashItems(
        identifiers: [String],
        budget: ResourceBudget,
        registry: PreparedWorkRegistry,
        runID: UUID,
        continuation: AsyncStream<PreparedHashWork>.Continuation
    ) async {
        await withTaskGroup(of: Void.self) { group in
            let limit = Self.downloadWindow
            var index = 0
            var inFlight = 0

            func addNext() {
                guard index < identifiers.count, inFlight < limit else { return }
                let identifier = identifiers[index]
                index += 1
                inFlight += 1
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.downloadHashItem(
                        identifier: identifier,
                        budget: budget,
                        registry: registry,
                        runID: runID,
                        continuation: continuation
                    )
                }
            }

            while inFlight < limit, index < identifiers.count { addNext() }

            while inFlight > 0 {
                _ = await group.next()
                inFlight -= 1
                addNext()
            }
        }
        continuation.finish()
    }

    private func downloadHashItem(
        identifier: String,
        budget: ResourceBudget,
        registry: PreparedWorkRegistry,
        runID: UUID,
        continuation: AsyncStream<PreparedHashWork>.Continuation
    ) async {
        guard isCurrentRun(runID), !shouldStop, !Task.isCancelled else { return }

        await MainActor.run {
            guard self.isCurrentRun(runID) else { return }
            self.syncStatusCache[identifier] = .processing
            self.objectWillChange.send()
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard isCurrentRun(runID), !shouldStop, !Task.isCancelled else { return }

        guard let asset = fetchResult.firstObject,
              let resources = AssetResourceSelector.select(for: asset) else {
            await MainActor.run {
                guard self.isCurrentRun(runID) else { return }
                self.syncStatusCache[identifier] = .error
                self.processedAssetsCount += 1
                self.objectWillChange.send()
            }
            return
        }

        // Reserve on the size estimate (may be 0 for iCloud-optimised assets;
        // floor of 1 keeps the FIFO honest). Corrected to the actual on-disk
        // size once delivered.
        let estimate = max(resources.plan.estimatedBytes, 1)
        guard await budget.acquire(estimate) else { return }

        let files: AssetTempFiles
        do {
            files = try await HashService.shared.prepare(resources)
        } catch {
            budget.release(estimate)
            if !Task.isCancelled {
                logError("Resource download failed: asset=\(identifier), error=\(error.localizedDescription)", category: .hash)
                await MainActor.run {
                    guard self.isCurrentRun(runID) else { return }
                    self.syncStatusCache[identifier] = .error
                    self.processedAssetsCount += 1
                    self.objectWillChange.send()
                }
            }
            return
        }

        let actual = files.actualBytes
        budget.adjust(from: estimate, to: actual)

        // Hand the files to the consumer; the registry entry lets the run sweep
        // them if the cancelled stream discards the buffered handoff. The
        // reservation stays charged until the consumer completes the work.
        let work = PreparedHashWork(files: files, reservedBytes: actual, budget: budget)
        registry.record(work)
        continuation.yield(work)
    }

    /// Consumer: keeps `hashConcurrency` assets hashing at a time; each item's
    /// disk reservation is released after its files are deleted.
    private func consumeHashStream(
        _ stream: AsyncStream<PreparedHashWork>,
        gate: ResourceBudget,
        runID: UUID
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for await work in stream {
                guard await gate.acquire(1) else {
                    work.complete()
                    for await orphan in stream { orphan.complete() }
                    break
                }
                group.addTask { [weak self] in
                    guard let self else { work.complete(); return }
                    await self.hashPreparedAsset(work, runID: runID)
                    await gate.release(1)
                }
            }
            await group.waitForAll()
        }
    }

    /// Hashes one prepared asset, records status/progress, and releases its
    /// disk reservation once the temp files are gone.
    private func hashPreparedAsset(_ work: PreparedHashWork, runID: UUID) async {
        let files = work.files
        defer { work.complete() }
        let identifier = files.plan.localIdentifier
        let hashStartedAt = Date()

        do {
            let result = try await HashService.shared.hash(files)
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
                modificationDate: files.plan.modificationDate
            )
            guard isCurrentRun(runID) else { return }

            await MainActor.run {
                guard self.isCurrentRun(runID) else { return }
                self.processedAssetsCount += 1
                self.processingProgress = Double(self.processedAssetsCount) / Double(self.totalAssetsToProcess)
                self.statusMessage = "Analyzing photos (\(self.processedAssetsCount)/\(self.totalAssetsToProcess))..."
                self.syncStatusCache[identifier] = .pending
                self.objectWillChange.send()
            }
        } catch {
            guard !Task.isCancelled else { return }
            logError("Hash failed: asset=\(identifier), elapsed=\(String(format: "%.2f", Date().timeIntervalSince(hashStartedAt)))s, error=\(error.localizedDescription)", category: .hash)
            await MainActor.run {
                guard self.isCurrentRun(runID) else { return }
                self.processedAssetsCount += 1
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
        guard runState.finish(runID) else { return }
        isProcessing = false
        isHashingActive = false
        isCheckingActive = false
        isStopping = false
        statusMessage = ""
        processingProgress = 1.0

        loadCachedStatus()
    }
    
    @MainActor
    func stopProcessing() {
        guard runState.beginStopping() else { return }

        shouldStop = true
        isStopping = true
        statusMessage = "Stopping..."

        let tasks = [hashTask, checkTask, matchingTask].compactMap { $0 }
        tasks.forEach { $0.cancel() }

        Task { @MainActor [weak self] in
            for task in tasks {
                await task.value
            }

            guard let self, self.isStopping else { return }
            await self.refreshStatusCacheAsync()
            self.isProcessing = false
            self.isHashingActive = false
            self.isCheckingActive = false
            self.isStopping = false
            self.runState.finishStopping()
            self.statusMessage = ""
        }
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
    
    @MainActor
    func forceReprocess(assets: [PHAsset]) {
        startBackgroundProcessing(
            identifiers: assets.map { $0.localIdentifier },
            assetsToInvalidate: assets,
            shouldClearCache: true
        )
    }
}
