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
    /// Keep PhotoKit writes below the previous six-request fan-out. Even though
    /// hashing itself uses fixed-size buffers, writeData can put substantial
    /// pressure on framework and file-cache memory when many originals arrive
    /// at once.
    static let photoKitDownloadWindow = 3

    /// Bounds the whole producer/consumer pipeline, not just active downloads.
    /// With three hash workers, six outstanding items still allow downloads to
    /// stay ahead without accumulating an arbitrarily deep prepared-file queue.
    static let outstandingWorkLimit: Int64 = 6

    /// Keep prepared temp-file backlog well below the old 1.5 GB ceiling that
    /// was observed immediately before repeated iOS memory warnings.
    static let diskBudgetBytes: Int64 = 512 * 1024 * 1024

    /// Proactively pace PhotoKit instead of waiting for a memory warning.
    /// Recent device logs showed warnings near ~58 MiB/s sustained resource
    /// delivery, while post-warning serialization still arrived too late to
    /// recover. Start conservatively at 24 MiB/s and tune upward only after
    /// long runs stay below memory pressure.
    static let photoKitTargetBytesPerSecond: Int64 = 24 * 1024 * 1024
    static let photoKitUnknownResourceChargeBytes: Int64 = 64 * 1024 * 1024

    static func photoKitRateLimitChargeBytes(
        estimatedBytes: Int64,
        hasUnknownResourceSize: Bool
    ) -> Int64 {
        if hasUnknownResourceSize {
            return max(estimatedBytes, photoKitUnknownResourceChargeBytes)
        }
        return max(estimatedBytes, 1)
    }

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

/// Long-term admission pacing for PhotoKit writes. This controls how quickly
/// new assets may enter `writeData` while still allowing an in-flight write
/// to overlap the next one when it naturally takes longer than the spacing.
final class PhotoKitRateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let bytesPerSecond: Double
    private var nextAdmissionUptime: TimeInterval = 0

    init(bytesPerSecond: Int64) {
        self.bytesPerSecond = Double(max(1, bytesPerSecond))
    }

    func waitForAdmission(bytes: Int64) async -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let spacing = Double(max(1, bytes)) / bytesPerSecond

        lock.lock()
        let scheduled = max(now, nextAdmissionUptime)
        nextAdmissionUptime = scheduled + spacing
        lock.unlock()

        let delay = scheduled - now
        guard delay > 0 else { return !Task.isCancelled }

        logDebug(
            "PhotoKit rate limit: delaying next asset by \(String(format: "%.2f", delay))s for \(bytes) estimated bytes",
            category: .hash
        )

        do {
            try await Task.sleep(
                nanoseconds: UInt64(delay * 1_000_000_000)
            )
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

/// Leaves the normal hash pipeline fast, but applies emergency backpressure
/// after iOS reports memory pressure. Once tripped for a run, new PhotoKit
/// writes pause briefly and then serialize so framework/native caches get time
/// to drain instead of continuing at full throughput toward Jetsam.
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
    private static let hashDiskBudget = ResourceBudget(limit: HashPipelinePolicy.diskBudgetBytes)
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
    private let photoKitRateLimiter = PhotoKitRateLimiter(
        bytesPerSecond: HashPipelinePolicy.photoKitTargetBytesPerSecond
    )
    private let memoryPressureThrottle = HashMemoryPressureThrottle()
    private var memoryWarningObserver: NSObjectProtocol?

    @MainActor
    private lazy var statusRefresh = CoalescingRefresh<[String: PhotoSyncStatus]>(
        load: { completion in
            DatabaseManager.shared.getAllSyncStatusAsync(completion: completion)
        },
        publish: { [weak self] statusMap in
            guard let self, !self.isProcessing else { return }
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
        Task { @MainActor [weak self] in
            self?.statusRefresh.refresh()
        }
    }

    @MainActor
    private func applyStatusSnapshot(_ statusMap: [String: PhotoSyncStatus]) {
        guard statusMap != syncStatusCache else { return }
        syncStatusCache = statusMap
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
        snapshotsToInvalidate: [PhotoAssetSnapshot]?,
        shouldClearCache: Bool = false
    ) {
        guard !isStopping && !isHashingActive && !isCheckingActive else { return }
        guard let runID = HashPipelinePolicy.admitIfIdle(using: runState, performSideEffects: { _ in
            if shouldClearCache {
                DatabaseManager.shared.clearHashCache()
                syncStatusCache.removeAll()
            }
            if let snapshotsToInvalidate {
                DatabaseManager.shared.resetCacheForModifiedAssets(
                    snapshots: snapshotsToInvalidate,
                    pruneOrphans: PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
                )
            }
        }) else { return }
        shouldStop = false
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

            let budget = Self.hashDiskBudget
            let hashGate = ResourceBudget(limit: Int64(Self.hashConcurrency))
            let outstandingGate = ResourceBudget(limit: HashPipelinePolicy.outstandingWorkLimit)
            let registry = PreparedWorkRegistry()
            var streamContinuation: AsyncStream<PreparedHashWork>.Continuation!
            // Unbounded handoff is safe because the outstanding-work gate and
            // byte budget cap how many prepared works can exist at once. A
            // dropping policy would lose handoffs and leak reservations.
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
                        outstandingGate: outstandingGate,
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

            // Only the still-current run may clear emergency pressure mode.
            // A stopped/stale run can have uncancellable PhotoKit writes draining
            // while a replacement run starts; keeping the throttle global prevents
            // that replacement from immediately restoring three-way writeData.
            if self.isCurrentRun(runID) {
                self.memoryPressureThrottle.reset()
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

    /// Downloads planned resources within the budget and publishes prepared
    /// temp files to `continuation`; also owns per-asset status UI.
    private func downloadHashItems(
        identifiers: [String],
        budget: ResourceBudget,
        outstandingGate: ResourceBudget,
        registry: PreparedWorkRegistry,
        runID: UUID,
        continuation: AsyncStream<PreparedHashWork>.Continuation
    ) async {
        await withTaskGroup(of: Void.self) { group in
            let limit = HashPipelinePolicy.photoKitDownloadWindow
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
                        outstandingGate: outstandingGate,
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
                guard !Task.isCancelled else {
                    group.cancelAll()
                    continue
                }
                addNext()
            }
        }
        continuation.finish()
    }

    private func downloadHashItem(
        identifier: String,
        budget: ResourceBudget,
        outstandingGate: ResourceBudget,
        registry: PreparedWorkRegistry,
        runID: UUID,
        continuation: AsyncStream<PreparedHashWork>.Continuation
    ) async {
        guard isCurrentRun(runID), !shouldStop, !Task.isCancelled else { return }
        guard await outstandingGate.acquire(1) else { return }

        var ownsOutstandingSlot = true
        defer {
            if ownsOutstandingSlot {
                outstandingGate.release(1)
            }
        }

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

        // Keep PhotoKit's estimated size for proactive rate limiting, but not
        // for temp-file budget reservations: it is not an upper bound on
        // delivery or native PhotoKit memory usage. Serializing prepared work
        // leaves headroom for the rest of the app even on large libraries.
        let rateLimitCharge = HashPipelinePolicy.photoKitRateLimitChargeBytes(
            estimatedBytes: resources.plan.estimatedBytes,
            hasUnknownResourceSize: resources.plan.hasUnknownResourceSize
        )
        guard await photoKitRateLimiter.waitForAdmission(bytes: rateLimitCharge) else { return }

        let reservation = HashPipelinePolicy.diskBudgetBytes
        guard await budget.acquire(reservation) else { return }

        guard let pressurePermitHeld = await memoryPressureThrottle.acquireIfNeeded() else {
            budget.release(reservation)
            return
        }

        let files: AssetTempFiles
        do {
            files = try await HashService.shared.prepare(resources)
            memoryPressureThrottle.releaseIfNeeded(pressurePermitHeld)
        } catch {
            memoryPressureThrottle.releaseIfNeeded(pressurePermitHeld)
            budget.release(reservation)
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

        let charged = max(reservation, files.actualBytes)
        budget.adjust(from: reservation, to: charged)

        // Hand the files to the consumer; the registry entry lets the run sweep
        // them if the cancelled stream discards the buffered handoff. The
        // reservation stays charged until the consumer completes the work.
        let work = PreparedHashWork(files: files, reservedBytes: charged, budget: budget)
        registry.record(work)
        work.onCompletion { [weak registry, weak work] in
            outstandingGate.release(1)
            guard let work else { return }
            registry?.remove(work)
        }
        ownsOutstandingSlot = false
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
                    defer { gate.release(1) }
                    guard let self else {
                        work.complete()
                        return
                    }
                    await self.hashPreparedAsset(work, runID: runID)
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
        guard isCurrentRun(runID), !shouldStop, !Task.isCancelled else { return }

        do {
            let result = try await HashService.shared.hash(files)
            guard isCurrentRun(runID), !shouldStop else { return }
            logDebug(
                "Hash finished: asset=\(identifier), primaryBytes=\(result.primaryFileSize), rawBytes=\(result.rawFileSize ?? 0), hasRAW=\(result.hasRAW), elapsed=\(String(format: "%.2f", Date().timeIntervalSince(hashStartedAt)))s",
                category: .hash
            )

            // Only associate a hash with the version observed while selecting its
            // source resources. A date read after hashing could describe an edit
            // made after the temporary files were captured.
            if files.plan.modificationDate == nil {
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

        loadCachedStatus()
    }
    
    @MainActor
    func stopProcessing() {
        guard runState.beginStopping() else { return }

        shouldStop = true
        isStopping = true
        let tasks = [hashTask, checkTask, matchingTask].compactMap { $0 }
        tasks.forEach { $0.cancel() }

        // PhotoKit writes cannot be cancelled. Let their detached run cleanup
        // finish later while immediately retiring this run from the UI. The
        // shared disk budget keeps a replacement run behind those writes.
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
        await withCheckedContinuation { continuation in
            statusRefresh.refresh { [self] statusMap in
                // Explicit pull-to-refresh also applies the snapshot while a
                // pipeline is active, preserving its existing await contract.
                applyStatusSnapshot(statusMap)
                continuation.resume()
            }
        }
    }
    
    @MainActor
    func forceReprocess(assets: [PHAsset]) {
        let snapshots = assets.map {
            PhotoAssetSnapshot(localIdentifier: $0.localIdentifier, modificationDate: $0.modificationDate)
        }
        startBackgroundProcessing(
            identifiers: snapshots.map { $0.localIdentifier },
            snapshotsToInvalidate: snapshots,
            shouldClearCache: true
        )
    }
}
