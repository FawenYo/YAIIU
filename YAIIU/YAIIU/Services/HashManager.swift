import Foundation
import Photos
import Combine
import UIKit

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
            if isAdmitted {
                lock.unlock()
                return true
            }
            if isCancelledFlag {
                lock.unlock()
                continuation.resume(returning: false)
                return false
            }
            self.continuation = continuation
            lock.unlock()
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

    /// Caller holds the lock. Admits the queue head only (strict FIFO).
    private func drainLocked() {
        while let first = waiters.first {
            if first.amount <= available || available == limit {
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
    /// Concurrent PhotoKit `requestData` requests. Streamed hashing holds only
    /// in-flight chunks, so memory is bounded by this count rather than by
    /// delivery throughput; three overlaps iCloud downloads without saturating
    /// PhotoKit's daemons.
    static let photoKitRequestWindow = 3

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
                guard !Task.isCancelled else {
                    group.cancelAll()
                    continue
                }
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

        var isRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            if case .running = phase { return true }
            return false
        }

        func owns(_ runID: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard case .running(runID) = phase else { return false }
            return true
        }
    }
}

/// Leaves the normal hash pipeline fast, but applies emergency backpressure
/// after iOS reports memory pressure. Once tripped for a run, new PhotoKit
/// requests pause briefly and then serialize so framework/native caches get
/// time to drain instead of continuing at full throughput toward Jetsam.
final class HashMemoryPressureThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let serializedGate = ResourceBudget(limit: 1)
    private var throttled = false
    private var resumeUptime: TimeInterval = 0

    func reset() {
        lock.lock()
        throttled = false
        resumeUptime = 0
        lock.unlock()
    }

    func signal(cooldown: TimeInterval = 10) {
        lock.lock()
        throttled = true
        resumeUptime = max(
            resumeUptime,
            ProcessInfo.processInfo.systemUptime + max(0, cooldown)
        )
        lock.unlock()
    }

    /// nil = cancelled before admission; false = normal fast path;
    /// true = caller holds the serialized pressure-mode permit.
    func acquireIfNeeded() async -> Bool? {
        lock.lock()
        let shouldThrottle = throttled
        lock.unlock()

        guard shouldThrottle else { return false }
        guard await serializedGate.acquire(1) else { return nil }

        while true {
            lock.lock()
            let delay = resumeUptime - ProcessInfo.processInfo.systemUptime
            lock.unlock()

            if delay <= 0 {
                return true
            }

            do {
                try await Task.sleep(
                    nanoseconds: UInt64(min(delay, 1.0) * 1_000_000_000)
                )
            } catch {
                serializedGate.release(1)
                return nil
            }
        }
    }

    func releaseIfNeeded(_ held: Bool) {
        if held {
            serializedGate.release(1)
        }
    }

    var isThrottled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return throttled
    }
}

/// Whole-run hashing totals. Per-asset timings mix iCloud download latency
/// with local work, so delivery strategies are compared on run throughput.
final class HashRunStats: @unchecked Sendable {
    struct Summary {
        let hashedAssets: Int
        let failedAssets: Int
        let bytes: Int64
        let elapsed: TimeInterval

        var mebibytesPerSecond: Double {
            elapsed > 0 ? Double(bytes) / (1024 * 1024) / elapsed : 0
        }
    }

    /// Large libraries rarely finish in one profiling session, so throughput
    /// is also reported periodically during the run.
    static let progressInterval = 50

    private let lock = NSLock()
    private let startedAt: TimeInterval
    private var hashedAssets = 0
    private var failedAssets = 0
    private var bytes: Int64 = 0

    init(startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.startedAt = startedAt
    }

    /// Returns a summary each time the hashed count reaches a multiple of
    /// `progressInterval`.
    @discardableResult
    func recordHashed(
        bytes: Int64,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Summary? {
        lock.lock()
        defer { lock.unlock() }
        hashedAssets += 1
        self.bytes += bytes
        return hashedAssets % Self.progressInterval == 0 ? summaryLocked(now: now) : nil
    }

    func recordFailed() {
        lock.lock()
        failedAssets += 1
        lock.unlock()
    }

    func summary(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Summary {
        lock.lock()
        defer { lock.unlock() }
        return summaryLocked(now: now)
    }

    private func summaryLocked(now: TimeInterval) -> Summary {
        Summary(
            hashedAssets: hashedAssets,
            failedAssets: failedAssets,
            bytes: bytes,
            elapsed: max(0, now - startedAt)
        )
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
    /// Bumped only when `syncStatusCache` may change uploaded membership.
    /// Hash-phase transitions (processing/pending/error) do not.
    @Published private(set) var countAffectingStatusGeneration = 0
    /// An empty dictionary before the initial SQLite read is not a valid count source.
    @Published private(set) var isSyncStatusCacheReady = false
    /// A first SQLite snapshot may be displayed as provisional filtering
    /// evidence while the migration/hash pipeline is still running.
    @Published private(set) var hasLoadedSyncStatusCache = false
    private var provisionalStatusDestination: String?
    private var suppressProvisionalStatusUntilNewRunCompletes = false
    
    @Published var iCloudIdMatchCount: Int = 0

    /// Assets that were found on server by checksum but have no iCloudId recorded.
    /// Consumers should read this after isProcessing becomes false and push updates to the server.
    /// The source checksum is carried so metadata PUTs (which replace the whole
    /// mobile-app value server-side) never drop it.
    @Published var pendingICloudIdUpdates: [(localIdentifier: String, immichId: String, iCloudId: String, sourceChecksum: String?)] = []
    
    private var processingQueue: [String] = []
    private var isHashingActive = false
    private var isCheckingActive = false
    private var isStopping = false
    
    private let checkQueue = DispatchQueue(label: "com.fawenyo.yaiiu.check", qos: .utility)
    
    /// Number of concurrent server checks
    private let checkConcurrency = 5
    /// Process-wide so cancelled requests from a stopped run, which hold their
    /// slot until PhotoKit completes, still count against a replacement run.
    private static let photoKitRequestSlots = ResourceBudget(
        limit: Int64(HashPipelinePolicy.photoKitRequestWindow)
    )
    /// Batch size for server checks
    private let checkBatchSize = 10
    /// Batch size for iCloud ID lookups
    private let iCloudIdBatchSize = 500
    
    private var shouldStop = false
    private var hashTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var matchingTask: Task<Void, Never>?
    private let runState = HashPipelinePolicy.RunState()
    private let memoryPressureThrottle = HashMemoryPressureThrottle()
    private var memoryWarningObserver: NSObjectProtocol?

    /// Per-asset hash statuses and progress are coalesced: every write to the
    /// published map copies it and re-renders every observing cell.
    private var bufferedStatuses: [String: PhotoSyncStatus] = [:]
    private var bufferedProcessedCount: Int?
    private var bufferRunID: UUID?
    private var statusFlushTask: Task<Void, Never>?

    @MainActor
    private lazy var statusRefresh = CoalescingRefresh<[String: PhotoSyncStatus]>(
        load: { completion in
            DatabaseManager.shared.getAllSyncStatusAsync(completion: completion)
        },
        publish: { [weak self] statusMap in
            guard let self, !self.suppressProvisionalStatusUntilNewRunCompletes else { return }
            // Publish only the initial snapshot during active processing;
            // later refreshes must not overwrite new hash/receipt updates.
            if !self.hasLoadedSyncStatusCache {
                self.replaceSyncStatusCache(statusMap)
                self.hasLoadedSyncStatusCache = true
            }
            guard !self.isProcessing else { return }
            self.applyStatusSnapshot(statusMap)
        }
    )
    
    private init() {
        loadCachedStatus()
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isHashingActive else { return }
            self.memoryPressureThrottle.signal()
            logWarning(
                "Hash pipeline memory pressure: pausing new PhotoKit writes for 10s and serializing downloads for the remainder of this run",
                category: .hash
            )
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }
    
    /// 'Preparing...' is only a UI placeholder. A real hash run owns a
    /// RunState UUID; distinguishing the two avoids deadlocking the handoff
    /// from the foreground PhotoKit change loader.
    @MainActor
    var hasActivePipeline: Bool {
        runState.isRunning
    }

    /// Bind the filter's provisional snapshot to the actual Immich login,
    /// never allowing a prior server/account to mark photos uploaded.
    @MainActor
    func bindProvisionalSyncStatus(to destination: String) {
        if PhotoLibraryStatusCount.destinationChanged(
            previous: provisionalStatusDestination, current: destination
        ) {
            suppressProvisionalStatusUntilNewRunCompletes = true
            hasLoadedSyncStatusCache = false
            isSyncStatusCacheReady = false
            replaceSyncStatusCache([:])
            pendingICloudIdUpdates.removeAll()
            if hasActivePipeline { stopProcessing() }
        }
        provisionalStatusDestination = destination
    }

    @MainActor
    func setPreparingState() {
        guard !isProcessing else { return }
        isSyncStatusCacheReady = false
        isProcessing = true
        statusMessage = "Preparing..."
        processingProgress = 0
        processedAssetsCount = 0
        totalAssetsToProcess = 0
    }
    
    @MainActor
    func clearPreparingState() {
        isProcessing = false
        if !isSyncStatusCacheReady { loadCachedStatus() }
        statusMessage = ""
        processingProgress = 0
        processedAssetsCount = 0
        totalAssetsToProcess = 0
    }
    
    private func loadCachedStatus() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Invalidate the badge while SQLite is being reloaded. The old
            // in-memory map is still available for thumbnails, not for counts.
            self.isSyncStatusCacheReady = false
            self.statusRefresh.refresh()
        }
    }

    @MainActor
    private func applyStatusSnapshot(_ statusMap: [String: PhotoSyncStatus]) {
        hasLoadedSyncStatusCache = true
        isSyncStatusCacheReady = true
        guard statusMap != syncStatusCache else {
            bufferedStatuses.removeAll()
            return
        }
        replaceSyncStatusCache(statusMap)
    }

    /// Wholesale replacements are authoritative: buffered per-asset statuses
    /// must not be merged on top of them.
    private func replaceSyncStatusCache(_ statusMap: [String: PhotoSyncStatus]) {
        bufferedStatuses.removeAll()
        syncStatusCache = statusMap
        countAffectingStatusGeneration &+= 1
    }

    private func bufferHashUpdate(_ status: PhotoSyncStatus, for identifier: String, runID: UUID, processed: Bool) {
        guard isCurrentRun(runID) else { return }
        if bufferRunID != runID {
            discardBufferedHashUpdates()
            bufferRunID = runID
        }
        bufferedStatuses[identifier] = status
        if processed {
            bufferedProcessedCount = (bufferedProcessedCount ?? processedAssetsCount) + 1
        }
        guard statusFlushTask == nil else { return }
        statusFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.flushHashUpdates()
        }
    }

    private func flushHashUpdates() {
        let runID = bufferRunID
        let statuses = bufferedStatuses
        let processed = bufferedProcessedCount
        discardBufferedHashUpdates()
        guard let runID, isCurrentRun(runID) else { return }
        if !statuses.isEmpty {
            let cache = syncStatusCache
            let replacesUploaded = statuses.keys.contains { cache[$0] == .uploaded }
            syncStatusCache.merge(statuses) { $1 }
            if replacesUploaded { countAffectingStatusGeneration &+= 1 }
        }
        if let processed {
            processedAssetsCount = processed
            processingProgress = Double(processed) / Double(totalAssetsToProcess)
            statusMessage = "Analyzing photos (\(processed)/\(totalAssetsToProcess))..."
        }
    }

    private func discardBufferedHashUpdates() {
        statusFlushTask?.cancel()
        statusFlushTask = nil
        bufferedStatuses.removeAll()
        bufferedProcessedCount = nil
        bufferRunID = nil
    }
    
    @MainActor
    func startBackgroundProcessing(snapshots: [PhotoAssetSnapshot]) {
        startBackgroundProcessing(
            identifiers: PhotoAssetSnapshot.visibleIdentifiers(in: snapshots),
            snapshotsToInvalidate: snapshots
        )
    }

    @MainActor
    func startBackgroundProcessing(identifiers: [String]) {
        startBackgroundProcessing(identifiers: identifiers, snapshotsToInvalidate: nil)
    }

    @MainActor
    private func startBackgroundProcessing(
        identifiers: [String],
        snapshotsToInvalidate: [PhotoAssetSnapshot]?
    ) {
        guard !isStopping && !isHashingActive && !isCheckingActive else { return }
        guard let runID = HashPipelinePolicy.admitIfIdle(using: runState, performSideEffects: { _ in
            if let snapshotsToInvalidate {
                DatabaseManager.shared.resetCacheForModifiedAssets(
                    snapshots: snapshotsToInvalidate,
                    pruneOrphans: PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
                )
            }
        }) else { return }
        shouldStop = false
        isSyncStatusCacheReady = false
        isProcessing = true
        iCloudIdMatchCount = 0
        // A stopped run can leave candidates published but not yet handed
        // off to metadata sync. Do not silently discard their last chance
        // to be discovered again when the next run starts.
        if !pendingICloudIdUpdates.isEmpty {
            let undelivered = pendingICloudIdUpdates.map(\.localIdentifier)
            if DatabaseManager.shared.invalidateHashChecksForLocalIdentifiers(undelivered) {
                pendingICloudIdUpdates = []
            } else {
                logWarning("Could not requeue pending metadata; preserving candidates for retry", category: .hash)
            }
        }
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
    
    /// A stable iCloud ID identifies a PhotoKit asset, not the current bytes.
    /// A previously uploaded checksum may belong to an older edit of that asset;
    /// do not cache it or mark the current version uploaded without hashing.
    private func tryICloudIdMatching(identifiers: [String], runID: UUID, completion: @escaping ([String]) -> Void) {
        guard isCurrentRun(runID), !shouldStop else { return }
        logInfo(
            "iCloud ID checksum shortcut skipped: verifying local resources for \(identifiers.count) asset(s)",
            category: .hash
        )
        completion(identifiers)
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

            logInfo("Hash run started: assets=\(identifiersToProcess.count)", category: .hash)
            let stats = HashRunStats()
            await HashPipelinePolicy.processConcurrently(
                identifiersToProcess,
                limit: HashPipelinePolicy.photoKitRequestWindow
            ) { [weak self] identifier in
                await self?.hashItem(identifier: identifier, stats: stats, runID: runID)
            }

            let summary = stats.summary()
            logInfo(
                "Hash run finished: hashed=\(summary.hashedAssets), failed=\(summary.failedAssets), bytes=\(summary.bytes), elapsed=\(String(format: "%.1f", summary.elapsed))s, throughput=\(String(format: "%.2f", summary.mebibytesPerSecond))MiB/s, cancelled=\(Task.isCancelled || self.shouldStop)",
                category: .hash
            )

            // Only the still-current run may clear emergency pressure mode.
            // A stopped/stale run can have PhotoKit requests draining while a
            // replacement run starts; keeping the throttle global prevents that
            // replacement from immediately restoring concurrent requests.
            if self.isCurrentRun(runID) {
                self.memoryPressureThrottle.reset()
            }

            await MainActor.run {
                self.flushHashUpdates()
                if self.isCurrentRun(runID), !self.shouldStop, !Task.isCancelled {
                    self.statusMessage = "Checking cloud status..."
                    self.startServerCheck(runID: runID)
                } else {
                    self.finishProcessing(runID: runID)
                }
            }
        }
    }

    /// Streams one asset's resources through SHA1 and records the result.
    /// A PhotoKit request slot is held only while bytes are being delivered.
    private func hashItem(identifier: String, stats: HashRunStats, runID: UUID) async {
        guard isCurrentRun(runID), !shouldStop, !Task.isCancelled else { return }

        await MainActor.run {
            self.bufferHashUpdate(.processing, for: identifier, runID: runID, processed: false)
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard isCurrentRun(runID), !shouldStop, !Task.isCancelled else { return }

        guard let asset = fetchResult.firstObject,
              let resources = AssetResourceSelector.select(for: asset) else {
            stats.recordFailed()
            await markHashFailed(identifier, runID: runID)
            return
        }

        let slots = Self.photoKitRequestSlots
        guard await slots.acquire(1) else { return }
        guard let pressurePermitHeld = await memoryPressureThrottle.acquireIfNeeded() else {
            slots.release(1)
            return
        }

        let hashStartedAt = Date()
        let result: MultiResourceHashResult
        do {
            result = try await HashService.shared.streamHash(resources)
            memoryPressureThrottle.releaseIfNeeded(pressurePermitHeld)
            slots.release(1)
        } catch {
            memoryPressureThrottle.releaseIfNeeded(pressurePermitHeld)
            slots.release(1)
            guard !Task.isCancelled else { return }
            stats.recordFailed()
            logError("Hash failed: asset=\(identifier), elapsed=\(String(format: "%.2f", Date().timeIntervalSince(hashStartedAt)))s, error=\(error.localizedDescription)", category: .hash)
            await markHashFailed(identifier, runID: runID)
            return
        }

        // Counts delivered bytes for throughput, including results later
        // discarded because the asset was edited during hashing.
        let progress = stats.recordHashed(bytes: result.primaryFileSize + (result.rawFileSize ?? 0))
        guard isCurrentRun(runID), !shouldStop else { return }
        if let progress {
            logInfo(
                "Hash run progress: hashed=\(progress.hashedAssets), failed=\(progress.failedAssets), bytes=\(progress.bytes), elapsed=\(String(format: "%.1f", progress.elapsed))s, throughput=\(String(format: "%.2f", progress.mebibytesPerSecond))MiB/s",
                category: .hash
            )
        }
        logDebug(
            "Hash finished: asset=\(identifier), primaryBytes=\(result.primaryFileSize), rawBytes=\(result.rawFileSize ?? 0), hasRAW=\(result.hasRAW), elapsed=\(String(format: "%.2f", Date().timeIntervalSince(hashStartedAt)))s",
            category: .hash
        )

        await persistHashResult(result, plan: resources.plan, runID: runID)
    }

    private func persistHashResult(
        _ result: MultiResourceHashResult,
        plan: AssetResourcePlan,
        runID: UUID
    ) async {
        let identifier = plan.localIdentifier

        // The asset may be edited while its resources are being hashed.
        // Never persist a hash or clear pending work for a superseded version.
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        let currentAsset = PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier], options: options
        ).firstObject
        let currentSnapshot = currentAsset.map {
            PhotoAssetSnapshot(asset: $0, includeAdjustmentVersion: true)
        }
        guard currentSnapshot?.adjustmentVersion == plan.adjustmentVersion else {
            if let currentSnapshot {
                DatabaseManager.shared.resetCacheForModifiedAssets(
                    snapshots: [currentSnapshot]
                )
            }
            logWarning(
                "Hash result discarded because the PhotoKit adjustment version changed during hashing: asset=\(identifier)",
                category: .hash
            )
            return
        }

        // Only associate a hash with the version observed while selecting its
        // source resources. A date read after hashing could describe an edit
        // made after the bytes were delivered.
        if plan.modificationDate == nil {
            logWarning(
                "Hash cache version unavailable at resource selection: asset=\(identifier); a later PhotoKit update may require rehashing",
                category: .hash
            )
        }
        DatabaseManager.shared.saveMultiResourceHashCache(
            localIdentifier: result.localIdentifier,
            primaryHash: result.primaryHash,
            rawHash: result.rawHash,
            hasRAW: result.hasRAW,
            modificationDate: plan.modificationDate,
            adjustmentVersion: plan.adjustmentVersion
        )
        guard isCurrentRun(runID) else { return }

        await MainActor.run {
            self.bufferHashUpdate(.pending, for: identifier, runID: runID, processed: true)
        }
    }

    private func markHashFailed(_ identifier: String, runID: UUID) async {
        await MainActor.run {
            self.bufferHashUpdate(.error, for: identifier, runID: runID, processed: true)
        }
    }

        private func startServerCheck(runID: UUID) {
        guard isCurrentRun(runID), !shouldStop else {
            finishProcessing(runID: runID)
            return
        }

        isCheckingActive = true
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            // Protect the entire read/verification/write cycle against an
            // Immich delta mutating the cache concurrently. Acquire the gate
            // BEFORE selecting unchecked records to include the latest delta.
            await ServerAssetVerificationGate.shared.acquire()
            defer {
                Task { await ServerAssetVerificationGate.shared.release() }
            }
            guard let self, self.isCurrentRun(runID), !Task.isCancelled else { return }

            // No authoritative negative results until a server baseline exists.
            guard DatabaseManager.shared.getSyncMetadata()?.lastSyncTime != nil else {
                await MainActor.run { self.finishProcessing(runID: runID) }
                return
            }

            let records: [MultiResourceHashRecord] = await withCheckedContinuation { continuation in
                DatabaseManager.shared.getMultiResourceHashesNotFullyOnServerAsync {
                    continuation.resume(returning: $0)
                }
            }
            guard self.isCurrentRun(runID), !Task.isCancelled, !self.shouldStop else { return }
            guard !records.isEmpty else {
                await MainActor.run { self.finishProcessing(runID: runID) }
                return
            }

            await MainActor.run {
                guard self.isCurrentRun(runID) else { return }
                self.totalAssetsToProcess = records.count
                self.processedAssetsCount = 0
                self.statusMessage = "Checking cloud status (0/\(records.count))..."
            }
            await self.checkMultiResourceHashesAgainstCache(records: records, runID: runID)
        }
    }

    private func checkMultiResourceHashesAgainstCache(records: [MultiResourceHashRecord], runID: UUID) async {
        guard isCurrentRun(runID), !shouldStop, !Task.isCancelled else { return }
        guard !records.isEmpty else {
            await MainActor.run { self.finishProcessing(runID: runID) }
            return
        }

        // Only visible, accessible PhotoKit assets can be verified. Missing
        // fetch results are NOT deletions (iCloud/hidden/Limited Photos).
        let allIdentifiers = records.map(\.assetId)
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: allIdentifiers, options: nil)
        var accessible = Set<String>()
        fetched.enumerateObjects { asset, _, _ in
            accessible.insert(asset.localIdentifier)
        }
        let validRecords = records.filter { accessible.contains($0.assetId) }
        guard isCurrentRun(runID), !shouldStop, !Task.isCancelled else { return }
        guard !validRecords.isEmpty else {
            await MainActor.run { self.finishProcessing(runID: runID) }
            return
        }

        let currentUserId = DatabaseManager.shared.getSyncMetadata()?.userId
        await MainActor.run {
            guard self.isCurrentRun(runID) else { return }
            self.totalAssetsToProcess = validRecords.count
            self.processedAssetsCount = 0
            self.processingProgress = 0
            self.statusMessage = "Checking cloud status (0/\(validRecords.count))..."
        }
        let startedAt = Date()
        let batchSize = 400
        var queuedMetadata = Set<String>()
        var queuedCount = 0

        // Read and update only bounded batches; do not allocate a 100k-entry
        // cloud-ID mapping or send 100k individual MainActor notifications.
        for start in stride(from: 0, to: validRecords.count, by: batchSize) {
            guard isCurrentRun(runID), !shouldStop, !Task.isCancelled else { return }
            let batch = validRecords[start..<min(start + batchSize, validRecords.count)]
            let ids = batch.map(\.assetId)

            guard let candidates = DatabaseManager.shared.verifyHashCacheBatch(
                identifiers: ids, ownerId: currentUserId
            ) else {
                logError("Cloud verification batch failed at offset \(start); remaining checks retained", category: .database)
                await MainActor.run { self.finishProcessing(runID: runID) }
                return
            }
            // verifyHashCacheBatch has already committed checked_at.
            // Cancellation or a superseding run must restore the full batch
            // to unchecked unless metadata candidates are safely published.
            var published = false
            defer {
                if !published {
                    let restored = DatabaseManager.shared.invalidateHashChecksForLocalIdentifiers(ids)
                    if !restored {
                        logError("Could not restore abandoned cloud verification batch at offset \(start)", category: .database)
                    }
                }
            }
            guard isCurrentRun(runID), !shouldStop, !Task.isCancelled else { return }

            var metadataUpdates: [(localIdentifier: String, immichId: String, iCloudId: String, sourceChecksum: String?)] = []
            if #available(iOS 16, *), !candidates.isEmpty {
                let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(
                    forLocalIdentifiers: candidates.map(\.assetId)
                )
                for candidate in candidates {
                    guard let result = mappings[candidate.assetId],
                          let cloudId = try? result.get(),
                          !cloudId.stringValue.hasSuffix(":"),
                          candidate.serverICloudId != cloudId.stringValue,
                          queuedMetadata.insert(candidate.immichId).inserted else { continue }
                    metadataUpdates.append((
                        localIdentifier: candidate.assetId,
                        immichId: candidate.immichId,
                        iCloudId: cloudId.stringValue,
                        sourceChecksum: candidate.sourceChecksum
                    ))
                }
            }
            queuedCount += metadataUpdates.count

            // Progress and published state change once per 400 assets rather
            // than once per asset; final status icons reload from SQLite.
            let didPublish = await MainActor.run { () -> Bool in
                guard self.isCurrentRun(runID), !self.shouldStop, !Task.isCancelled else { return false }
                self.pendingICloudIdUpdates.append(contentsOf: metadataUpdates)
                self.processedAssetsCount = start + batch.count
                self.processingProgress = Double(self.processedAssetsCount) / Double(validRecords.count)
                self.statusMessage = "Checking cloud status (\(self.processedAssetsCount)/\(validRecords.count))..."
                return true
            }
            guard didPublish else { return }
            published = true
        }
        logInfo(
            "Cloud verification completed: checked=\(validRecords.count), metadataQueued=\(queuedCount), "
                + "elapsed=\(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s",
            category: .hash
        )
        await MainActor.run { self.finishProcessing(runID: runID, shouldSyncAlbums: true) }
    }

    private func finishProcessing(runID: UUID, shouldSyncAlbums: Bool = false) {
        // Publish this run's last buffered statuses before it stops being current.
        flushHashUpdates()
        guard runState.finish(runID) else { return }
        if shouldSyncAlbums {
            Task { await AlbumSyncService.shared.syncIfEnabled() }
        }
        isProcessing = false
        isHashingActive = false
        isCheckingActive = false
        isStopping = false
        statusMessage = ""
        processingProgress = 1.0

        // After new-account verification, the refreshed SQLite view can be
        // adopted again. Previously loaded snapshots remain suppressed.
        suppressProvisionalStatusUntilNewRunCompletes = false
        loadCachedStatus()
    }
    
    @MainActor
    func stopProcessing() {
        flushHashUpdates()
        guard runState.beginStopping() else { return }

        shouldStop = true
        isStopping = true
        let tasks = [hashTask, checkTask, matchingTask].compactMap { $0 }
        tasks.forEach { $0.cancel() }

        // Cancelled PhotoKit requests finish draining asynchronously. Retire
        // this run from the UI immediately; the process-wide request slots
        // keep a replacement run behind requests that are still draining.
        isProcessing = false
        isHashingActive = false
        isCheckingActive = false
        isStopping = false
        runState.finishStopping()
        statusMessage = ""
        loadCachedStatus()
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
        isSyncStatusCacheReady = false
        await withCheckedContinuation { continuation in
            statusRefresh.refresh { [self] statusMap in
                // Explicit pull-to-refresh also applies the snapshot while a
                // pipeline is active, preserving its existing await contract.
                applyStatusSnapshot(statusMap)
                continuation.resume()
            }
        }
    }
}
