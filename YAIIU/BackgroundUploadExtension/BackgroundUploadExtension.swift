import CoreLocation
import CryptoKit
import ExtensionFoundation
import MapKit
import Network
import Photos
import UniformTypeIdentifiers
import os.lock

@main
enum BackgroundUploadExtensionEntryPoint {
    static func main() throws {
        if #available(iOS 27.0, *) {
            try BackgroundUploadExtension.main()
        } else {
            try LegacyBackgroundUploadExtension.main()
        }
    }
}

final class BackgroundUploadExtensionCore {
    private let cancelledState = OSAllocatedUnfairLock(initialState: false)
    private let settings = SharedSettings.shared
    private let database = BackgroundUploadDatabase.shared
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "com.yaiiu.background-upload.network")
    private let pathLock = NSLock()
    private var currentPath: NWPath?
    private var hasReceivedInitialPath = false
    private let appGroupID = "group.com.fawenyo.yaiiu"
    private let immichAssetIDHeader = "x-yaiiu-immich-asset-id"

    private var isCancelled: Bool {
        cancelledState.withLock { $0 }
    }
    init() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.pathLock.lock()
            self.currentPath = path
            self.hasReceivedInitialPath = true
            self.pathLock.unlock()
        }
        networkMonitor.start(queue: networkQueue)
        log("Initialized")
    }

    deinit {
        networkMonitor.cancel()
    }

    private func currentNetworkInterface() -> BackgroundUploadNetworkInterface {
        pathLock.lock()
        defer { pathLock.unlock() }
        guard hasReceivedInitialPath else { return .unknown }
        guard let path = currentPath, path.status == .satisfied else { return .unavailable }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        return .other
    }

    // MARK: - Upload Processing

    func process() -> PHBackgroundResourceUploadProcessingResult {
        resetCancellation()
        log("Processing background upload jobs...")
        guard !isCancelled else { return .processing }

        do {
            switch try processUploadJobs() {
            case .deferred, .remaining:
                return .processing
            case .completed, .scheduled:
                return .completed
            }
        } catch let error as NSError
            where error.domain == PHPhotosErrorDomain
            && error.code == PHPhotosError.limitExceeded.rawValue
        {
            logWarning("PhotoKit in-flight job limit exceeded; deferring new work")
            return .processing
        } catch {
            logError("Error: \(error.localizedDescription)")
            return .failure
        }
    }

    func notifyTermination() {
        cancelledState.withLock { $0 = true }
    }

    private func resetCancellation() {
        cancelledState.withLock { $0 = false }
    }

    private func processUploadJobs() throws -> NewUploadJobsResult {
        guard settings.isLoggedIn, settings.backgroundUploadEnabled else {
            logDebug("Skipping run: logged in=\(settings.isLoggedIn), background upload enabled=\(settings.backgroundUploadEnabled)")
            return .completed
        }

        guard let destinationIdentity = currentDestinationIdentity() else {
            logWarning("Skipping run: upload destination is unavailable")
            return .completed
        }
        if try database.ensureDestinationIdentity(destinationIdentity) {
            log("Upload destination identity changed or was initialized; restarting PhotoKit bootstrap discovery")
        }

        // Stage markers: the system can terminate the extension at any point
        // without a crash report; per-stage boundaries show how far a run got.
        var madeProgress = timeStage("reconcile") { reconcileTrackedJobs() > 0 }
        guard !isCancelled else { return .deferred }

        madeProgress = try timeStage("retry") { try retryFailedJobs() } || madeProgress
        guard !isCancelled else { return .deferred }

        let acknowledgement = try timeStage("acknowledge") { try acknowledgeCompletedJobs() }
        madeProgress = acknowledgement.acknowledged || madeProgress
        guard !isCancelled else { return .deferred }

        madeProgress = timeStage("cancel") { cancelRedundantJobs() } || madeProgress
        guard !isCancelled else { return .deferred }

        let result = try timeStage("create") { try createNewUploadJobs(interface: currentNetworkInterface()) }
        guard result == .completed else { return result }

        // Unacknowledged terminal jobs still consume the job limit; request another
        // invocation instead of entering monitoring mode.
        if acknowledgement.pending { return .deferred }

        return madeProgress || hasJobsInFlight() ? .scheduled : .completed
    }

    private func timeStage<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let started = Date()
        defer {
            let elapsed = Date().timeIntervalSince(started)
            let line = "Stage \(name) finished in \(String(format: "%.1f", elapsed))s"
            if elapsed > 1 { log(line) } else { logDebug(line) }
        }
        logDebug("Stage \(name) starting")
        return try body()
    }

    private func hasJobsInFlight() -> Bool {
        guard #available(iOS 26.5, *) else { return false }
        return PHAssetResourceUploadJob.fetchJobs(action: .process, options: nil).count > 0
    }

    // In-flight jobs that are redundant (uploaded through another path), untracked, or
    // stuck since well before this device last had upload conditions occupy the PhotoKit
    // job limit forever if never released. Cancellation auto-acknowledges them, freeing
    // capacity for new work.
    private func cancelRedundantJobs() -> Bool {
        guard #available(iOS 26.5, *) else { return false }
        let library = PHPhotoLibrary.shared()
        let jobs = PHAssetResourceUploadJob.fetchJobs(action: .process, options: nil)
        guard jobs.count > 0 else { return false }

        let trackedAges = database.getTrackedJobAges()
        let staleCutoff = Date().addingTimeInterval(-staleJobAgeLimit)
        var cancelledAny = false

        for i in 0..<jobs.count where !isCancelled {
            let job = jobs.object(at: i)
            let identity = identity(for: job)
            let key = identity.map { "\($0.assetLocalIdentifier)||\($0.resourceType)" }

            let reason: String
            if let identity {
                if !jobTargetsCurrentDestination(job) {
                    reason = "upload destination changed"
                } else if database.isResourceUploaded(
                    assetId: identity.assetLocalIdentifier,
                    resourceType: identity.resourceType
                ) {
                    reason = "already uploaded through another path"
                } else if let createdAt = key.flatMap({ trackedAges[$0] }), createdAt < staleCutoff {
                    reason = "stuck in flight since \(createdAt)"
                } else if let key, !trackedAges.keys.contains(key) {
                    reason = "untracked by the app database"
                } else {
                    continue
                }
            } else {
                reason = "unresolvable identity"
            }

            var requested = false
            var applied = false
            do {
                try library.performChangesAndWait {
                    guard let request = PHAssetResourceUploadJobChangeRequest(for: job) else { return }
                    request.cancel()
                    requested = true
                }
                applied = requested
            } catch {
                logError("Failed to cancel job \(job.localIdentifier): \(error.localizedDescription)")
            }
            guard applied else {
                logWarning("No change request or transaction for job \(job.localIdentifier); leaving bookkeeping intact")
                continue
            }
            cancelledAny = true
            logWarning("Cancelled in-flight job \(job.localIdentifier): \(reason)")
            // Delete the tracking row outright: a completed row would block the
            // replacement job's upsert, and any non-deleted row keeps the resource
            // classified as inflight. Rediscovery (unless genuinely uploaded) then
            // recreates the job.
            if let identity {
                database.deleteTrackedJob(
                    assetId: identity.assetLocalIdentifier,
                    resourceType: identity.resourceType
                )
            }
        }
        return cancelledAny
    }

    // Drops locally tracked jobs that no longer exist in PhotoKit. Without this, rows
    // left by crashes or library churn keep their assets permanently skipped by
    // fetchPendingResources.
    private func reconcileTrackedJobs() -> Int {
        guard #available(iOS 26.5, *) else { return 0 }
        var liveKeys = Set<String>()
        let actions: [PHAssetResourceUploadJob.Action] = [.process, .acknowledge, .retry]
        for action in actions {
            let jobs = PHAssetResourceUploadJob.fetchJobs(action: action, options: nil)
            for i in 0..<jobs.count {
                if let identity = identity(for: jobs.object(at: i)) {
                    liveKeys.insert("\(identity.assetLocalIdentifier)||\(identity.resourceType)")
                }
            }
        }
        let removed = database.pruneTrackedJobs(
            liveKeys: liveKeys,
            createdBefore: Date().addingTimeInterval(-30 * 60)
        )
        if removed > 0 {
            logDebug("Pruned \(removed) tracked jobs absent from PhotoKit")
        }
        return removed
    }


    // MARK: - Job Management

    private func retryFailedJobs() throws -> Bool {
        var retriedAny = false
        let library = PHPhotoLibrary.shared()
        let jobs = PHAssetResourceUploadJob.fetchJobs(
            action: .retry,
            options: nil
        )
        if jobs.count > 0 {
            logDebug("Retryable jobs: \(jobs.count)")
        }

        for i in 0..<jobs.count where !isCancelled {
            let job = jobs.object(at: i)
            let errorDescription = jobErrorDescription(job)
            logWarning("Retrying failed upload job \(job.localIdentifier): \(errorDescription)")

            guard let identity = identity(for: job) else {
                logWarning("Skipping retry for job \(job.localIdentifier): asset identity unavailable")
                continue
            }

            if !jobTargetsCurrentDestination(job) {
                if #available(iOS 26.4, *) {
                    var requested = false
                    var applied = false
                    do {
                        try library.performChangesAndWait {
                            guard let request = PHAssetResourceUploadJobChangeRequest(for: job) else { return }
                            request.cancel()
                            requested = true
                        }
                        applied = requested
                    } catch {
                        logError("Failed to cancel retry job for old destination \(job.localIdentifier): \(error.localizedDescription)")
                    }
                    if applied {
                        database.deleteTrackedJob(
                            assetId: identity.assetLocalIdentifier,
                            resourceType: identity.resourceType
                        )
                        retriedAny = true
                        logWarning("Cancelled retry job \(job.localIdentifier) because upload destination changed")
                    }
                } else {
                    // Early PhotoKit background-upload releases cannot cancel retry
                    // jobs. Redirect the original resource using its original version
                    // metadata; acknowledgement will still reject it as stale if the
                    // PHAsset has been edited since the job was first created.
                    guard let destination = buildRetryDestination(for: job) else {
                        logWarning("Skipping old-destination retry \(job.localIdentifier): destination unavailable")
                        continue
                    }
                    do {
                        try library.performChangesAndWait {
                            guard let request = PHAssetResourceUploadJobChangeRequest(for: job) else { return }
                            request.retry(destination: destination)
                            retriedAny = true
                        }
                    } catch {
                        logError("Failed to redirect retry job \(job.localIdentifier): \(error.localizedDescription)")
                    }
                }
                continue
            }

            // A retry resends PhotoKit's original resource. Preserve the original
            // metadata/version headers and only refresh transport settings; rebuilding
            // from the current PHAsset would make a stale resource look current.
            guard let destination = buildRetryDestination(for: job) else {
                logWarning("Skipping retry for job \(job.localIdentifier): destination unavailable")
                continue
            }

            do {
                try library.performChangesAndWait {
                    guard let request = PHAssetResourceUploadJobChangeRequest(for: job) else { return }
                    request.retry(destination: destination)
                    retriedAny = true
                }
            } catch {
                logError("Failed to retry job \(job.localIdentifier): \(error.localizedDescription)")
            }
        }
        return retriedAny
    }

    private func acknowledgeCompletedJobs() throws -> (acknowledged: Bool, pending: Bool) {
        let library = PHPhotoLibrary.shared()
        let jobs = PHAssetResourceUploadJob.fetchJobs(
            action: .acknowledge,
            options: nil
        )
        if jobs.count > 0 {
            logDebug("Acknowledgeable jobs: \(jobs.count)")
        }

        var appliedCount = 0
        for i in 0..<jobs.count where !isCancelled {
            let job = jobs.object(at: i)
            let succeeded = job.state == .succeeded
            let identity = identity(for: job)
            if identity == nil {
                logWarning("Could not resolve identity for completed job \(job.localIdentifier); acknowledging without recording")
            }

            let currentVersionSucceeded: Bool
            if succeeded, let identity {
                currentVersionSucceeded = jobMatchesCurrentAssetState(job, identity: identity)
                if !currentVersionSucceeded {
                    logWarning("Completed job \(job.localIdentifier) targets an older asset version; acknowledging without recording")
                }
            } else {
                currentVersionSucceeded = false
            }

            // Capture response data before acknowledging; acknowledgement removes the
            // job from PhotoKit tracking and its fields may become unavailable after.
            let immichId: String?
            if currentVersionSucceeded, #available(iOS 26.4, *),
               let value = job.responseHeaderFields?[immichAssetIDHeader],
               UUID(uuidString: value) != nil {
                immichId = value
            } else {
                immichId = currentVersionSucceeded ? "unknown" : nil
            }

            // Persist a successful upload before releasing the PhotoKit job; the write
            // is idempotent, while a termination between commit and record would lose
            // the upload's durable record.
            if currentVersionSucceeded, let identity {
                database.recordUploadedAsset(
                    assetId: identity.assetLocalIdentifier,
                    resourceType: identity.resourceType,
                    filename: identity.filename,
                    immichId: immichId ?? "unknown",
                    fileSize: 0,
                    isDuplicate: false
                )
                SharedSettings.shared.lastBackgroundUploadAt = Date()
            }

            var requested = false
            var applied = false
            do {
                try library.performChangesAndWait {
                    guard let request = PHAssetResourceUploadJobChangeRequest(for: job) else { return }
                    request.acknowledge()
                    requested = true
                }
                applied = requested
            } catch {
                logError("Failed to acknowledge job \(job.localIdentifier): \(error.localizedDescription)")
            }
            guard applied else {
                logWarning("No change request or transaction for job \(job.localIdentifier); leaving it acknowledged later")
                continue
            }
            appliedCount += 1

            guard let identity else { continue }
            if currentVersionSucceeded {
                database.markJobStatus(
                    assetId: identity.assetLocalIdentifier,
                    resourceType: identity.resourceType,
                    status: .completed
                )
                log("Acknowledged successful upload: \(identity.filename)")
            } else {
                // Delete the tracking row so the resource is immediately rediscoverable;
                // this also covers a successful job for an older asset version.
                database.deleteTrackedJob(
                    assetId: identity.assetLocalIdentifier,
                    resourceType: identity.resourceType
                )
                if succeeded {
                    logWarning("Acknowledged stale successful upload: \(identity.filename)")
                } else {
                    logWarning("Acknowledged failed upload: \(identity.filename)")
                }
            }
        }
        return (appliedCount > 0, appliedCount < jobs.count)
    }
    private enum NewUploadJobsResult {
        case completed
        case deferred
        case remaining
        case scheduled
    }

    private func createNewUploadJobs(
        interface: BackgroundUploadNetworkInterface
    ) throws -> NewUploadJobsResult {
        switch interface {
        case .unknown:
            logDebug("Deferring new background upload jobs because network path is unknown")
            return .remaining
        case .cellular where !settings.allowCellularBackgroundUpload:
            logDebug("Deferring new background upload jobs because cellular data is disabled")
            return .remaining
        case .unavailable:
            logDebug("Deferring new background upload jobs because network is unavailable")
            return .remaining
        default:
            guard BackgroundUploadPolicy.canCreateNewJobs(
                allowCellular: settings.allowCellularBackgroundUpload,
                interface: interface
            ) else {
                return .remaining
            }
        }

        let capacity = uploadJobCapacity()
        guard capacity > 0 else {
            logWarning("PhotoKit job limit already reached; waiting for acknowledgements before creating new jobs")
            return .remaining
        }

        let persistentMode: Bool
        var bootstrapTokenData: Data?

        if database.loadChangeToken() != nil {
            switch try ingestPersistentChanges() {
            case .ready:
                persistentMode = true
            case .requiresBootstrap:
                // Apple requires a full re-sync after persistent history expires or
                // can no longer provide complete details. Do that on the next pass.
                return .remaining
            case .cancelled:
                return .deferred
            }
        } else {
            persistentMode = false
            // Keep the original bootstrap checkpoint across every partial scan. Assets
            // edited after an early pass must remain newer than this same checkpoint
            // so persistent history can replay them after the full scan completes.
            if let savedBootstrapToken = try database.loadBootstrapToken() {
                bootstrapTokenData = savedBootstrapToken
            } else {
                let tokenData = try archiveChangeToken(PHPhotoLibrary.shared().currentChangeToken)
                try database.saveBootstrapToken(tokenData)
                bootstrapTokenData = tokenData
                logDebug("Captured durable PhotoKit bootstrap checkpoint")
            }
        }

        let discovery: DiscoveryResult
        if persistentMode {
            discovery = try fetchQueuedResources(limit: max(capacity * 2, 20))
            logDebug("Delta discovery found \(discovery.resources.count) pending resources")
        } else {
            // Initial sync / recovery only. Normal invocations never enumerate the
            // whole photo library once a persistent change token has been established.
            discovery = fetchPendingResources(limit: max(capacity * 2, 20))
            logDebug("Bootstrap discovery found \(discovery.resources.count) pending resources (complete scan: \(discovery.complete))")
        }

        if !persistentMode {
            // Bootstrap candidates must become durable before the persistent change
            // checkpoint is advanced. Include currently tracked in-flight assets too:
            // they may have been created by an earlier build and can later fail or be
            // cancelled after the full scan starts skipping them.
            var bootstrapAssetIds = Set(discovery.resources.map(\.assetLocalIdentifier))
            for key in database.getInflightJobKeys() {
                if let separator = key.range(of: "||") {
                    bootstrapAssetIds.insert(String(key[..<separator.lowerBound]))
                }
            }
            try database.enqueueAssets(bootstrapAssetIds)

            if discovery.complete, let bootstrapTokenData {
                // Every outstanding bootstrap asset is now represented by the durable
                // queue, so it is safe to switch to persistent-delta mode even if job
                // creation below is interrupted or an existing job later fails.
                try database.promoteBootstrapToken(bootstrapTokenData)
                log("Established PhotoKit persistent change checkpoint from the original bootstrap checkpoint")
            }
        }

        guard !discovery.resources.isEmpty else {
            if persistentMode {
                return discovery.complete ? .completed : .remaining
            }
            return discovery.complete ? .completed : .remaining
        }
        let resources = discovery.resources
        // Keep an asset's resources in the same batch: splitting a JPEG/raw asset lets
        // the first success's asset-wide server bookkeeping hide the sibling that was
        // never scheduled.
        var grouped: [[PHAssetResource]] = []
        var groupIndexByAsset: [String: Int] = [:]
        for resource in resources {
            if let index = groupIndexByAsset[resource.assetLocalIdentifier] {
                grouped[index].append(resource)
            } else {
                groupIndexByAsset[resource.assetLocalIdentifier] = grouped.count
                grouped.append([resource])
            }
        }
        var batch: [PHAssetResource] = []
        for group in grouped {
            guard batch.count + group.count <= capacity else {
                // Keep scanning: a later, smaller whole asset may still fit the
                // remaining capacity while the oversized group defers.
                continue
            }
            batch.append(contentsOf: group)
        }
        guard !batch.isEmpty else {
            logWarning("Remaining pending assets need more capacity than available; deferring whole groups")
            return .remaining
        }
        // An incomplete discovery scan (limit or time budget hit) means unscheduled
        // resources remain beyond what this batch was built from.
        let truncated = batch.count < resources.count || !discovery.complete
        if truncated {
            logDebug("Capped new jobs to \(batch.count) of \(resources.count) pending to respect job limit")
        }

        // Resolve timezones only for the capped batch; geocoding the whole pending
        // list per run would repeat library-wide work on every batch.
        let timezones = captureTimezones(for: batch)
        guard !isCancelled else { return .deferred }

        let library = PHPhotoLibrary.shared()
        var createdAny = false
        try library.performChangesAndWait {
            for resource in batch where !self.isCancelled {
                guard let dest = self.buildDestination(
                    for: resource,
                    timezone: timezones[resource.assetLocalIdentifier] ?? TimeZone.current,
                    purpose: .newJob
                ) else {
                    continue
                }
                let resolvedFilename = resource.resolvedFilename()
                self.logDebug("Creating upload job for resource: \(resolvedFilename)")

                if #available(iOS 26.4, *) {

                    PHAssetResourceUploadJobChangeRequest.creationRequestForJob(destination: dest, resource: resource)
                } else {
                    PHAssetResourceUploadJobChangeRequest.createJob(destination: dest, resource: resource)
                }
                createdAny = true

                self.database.createOrUpdateJob(
                    assetId: resource.assetLocalIdentifier,
                    resourceType: self.resourceTypeString(for: resource),
                    filename: resolvedFilename,
                    status: .uploading
                )
                self.database.markResourcePresent(
                    assetId: resource.assetLocalIdentifier,
                    resourceType: self.resourceTypeString(for: resource)
                )
            }
        }
        guard createdAny else { return .remaining }

        // A truncated batch means unscheduled resources remain; the legacy process()
        // path maps .scheduled to .completed, so signal remaining work explicitly.
        return truncated ? .remaining : .scheduled
    }

    // MARK: - Persistent Photo Library Changes

    private enum PersistentChangeIngestionResult {
        case ready
        case requiresBootstrap
        case cancelled
    }

    private func archiveChangeToken(_ token: PHPersistentChangeToken) throws -> Data {
        try NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        )
    }

    private func unarchiveChangeToken(_ data: Data) -> PHPersistentChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: PHPersistentChangeToken.self,
            from: data
        )
    }

    /// Copies PhotoKit's durable change history into our app-group queue. Each
    /// persistent change and its token are committed in one SQLite transaction, so
    /// termination can cause replay but can never cause a skipped asset.
    private func ingestPersistentChanges() throws -> PersistentChangeIngestionResult {
        guard let tokenData = database.loadChangeToken(),
              let token = unarchiveChangeToken(tokenData) else {
            database.clearChangeToken()
            logWarning("Persistent change token could not be decoded; scheduling bootstrap reconciliation")
            return .requiresBootstrap
        }

        let library = PHPhotoLibrary.shared()

        do {
            let changes = try library.fetchPersistentChanges(since: token)
            var changeCount = 0
            var insertedCount = 0
            var updatedCount = 0
            var deletedCount = 0

            for change in changes {
                guard !isCancelled else { return .cancelled }
                let details = try change.changeDetails(for: .asset)
                let inserted = details.insertedLocalIdentifiers
                let deleted = details.deletedLocalIdentifiers
                let updated = details.updatedLocalIdentifiers
                let nextTokenData = try archiveChangeToken(change.changeToken)

                guard database.commitPersistentChange(
                    insertedAssetIds: inserted,
                    updatedAssetIds: updated,
                    deletedAssetIds: deleted,
                    tokenData: nextTokenData
                ) else {
                    throw NSError(
                        domain: "com.fawenyo.yaiiu.background-upload",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Failed to atomically persist PhotoKit change history"
                        ]
                    )
                }

                changeCount += 1
                insertedCount += inserted.count
                updatedCount += updated.count
                deletedCount += deleted.count
            }

            if changeCount > 0 {
                log("Persistent changes: \(changeCount) batch(es), \(insertedCount) inserted, \(updatedCount) updated, \(deletedCount) deleted")
            }
            return isCancelled ? .cancelled : .ready
        } catch let error as NSError
            where error.domain == PHPhotosErrorDomain
            && (
                error.code == PHPhotosError.persistentChangeTokenExpired.rawValue
                || error.code == PHPhotosError.persistentChangeDetailsUnavailable.rawValue
            )
        {
            database.clearChangeToken()
            logWarning("Persistent PhotoKit history is no longer complete; falling back to bootstrap reconciliation")
            return .requiresBootstrap
        }
    }

    // MARK: - Resource Discovery
    private struct DiscoveryResult {
        let resources: [PHAssetResource]
        // False when the scan stopped on the count limit or time budget; the
        // caller must treat work as still pending rather than exhausted.
        let complete: Bool
    }

    // Per-run wall-clock budget for library discovery; the system kills the
    // extension without a crash report when a run overruns its execution budget.
    private let discoveryTimeBudget: TimeInterval = 20

    /// Resolves only assets captured by PhotoKit persistent history. The queue entry
    /// remains until every uploadable resource is confirmed uploaded, making retries
    /// idempotent without returning to a full-library scan.
    private func fetchQueuedResources(limit: Int) throws -> DiscoveryResult {
        let scanLimit = max(limit * 2, 50)
        let queuedIds = try database.getQueuedAssetIds(limit: scanLimit + 1)
        let hasMoreQueuedAssets = queuedIds.count > scanLimit
        let assetIds = Array(queuedIds.prefix(scanLimit))
        guard !assetIds.isEmpty else {
            return DiscoveryResult(resources: [], complete: true)
        }

        let inflightKeys = database.getInflightJobKeys()
        let fullyOnServer = database.getAllAssetsOnServer()
        let partial = database.getPartialServerCopyAssets()
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: nil)

        var foundIds = Set<String>()
        var pending = [PHAssetResource]()
        var stoppedEarly = false
        let deadline = Date().addingTimeInterval(discoveryTimeBudget)

        fetchResult.enumerateObjects { asset, _, stop in
            if self.isCancelled || Date() >= deadline {
                stoppedEarly = true
                stop.pointee = true
                return
            }

            foundIds.insert(asset.localIdentifier)

            guard asset.mediaType == .image || asset.mediaType == .video else {
                self.database.removeQueuedAsset(asset.localIdentifier)
                return
            }

            if fullyOnServer.contains(asset.localIdentifier) {
                self.database.removeQueuedAsset(asset.localIdentifier)
                return
            }

            let resources = PHAssetResource.assetResources(for: asset).filter(self.shouldUpload)
            var assetHasOutstandingWork = false

            for resource in resources {
                let type = self.resourceTypeString(for: resource)
                let key = "\(asset.localIdentifier)||\(type)"

                if inflightKeys.contains(key) {
                    assetHasOutstandingWork = true
                    continue
                }

                let copyOnServer = type == "raw"
                    ? partial.rawConfirmed.contains(asset.localIdentifier)
                    : partial.primaryConfirmed.contains(asset.localIdentifier)
                if copyOnServer {
                    continue
                }

                if self.database.isResourceUploaded(
                    assetId: asset.localIdentifier,
                    resourceType: type
                ) {
                    continue
                }

                assetHasOutstandingWork = true
                pending.append(resource)
            }

            if !assetHasOutstandingWork {
                self.database.removeQueuedAsset(asset.localIdentifier)
            }

            // Finish the current asset so JPEG/RAW siblings stay together, then stop
            // before resolving another queued asset once we have enough candidates.
            if pending.count >= limit {
                stoppedEarly = true
                stop.pointee = true
            }
        }

        // A local identifier can be temporarily unresolvable during iCloud restore
        // or Photos library synchronization. Explicit persistent deletion changes
        // already remove queue rows, so keep unresolved identifiers durable here.
        let unresolvedAssetIds = Set(assetIds).subtracting(foundIds)
        let hasUnresolvedAssets = !unresolvedAssetIds.isEmpty
        if hasUnresolvedAssets {
            try database.deferQueuedAssets(unresolvedAssetIds)
            logDebug("Delta discovery retained and deferred temporarily unresolved queued assets")
        }

        return DiscoveryResult(
            resources: pending,
            // Queue rows covered by live PhotoKit jobs are filtered by the DB query.
            // Unresolved rows remain pending until Photos can resolve them or emits an
            // explicit deletion change.
            complete: !stoppedEarly && !hasMoreQueuedAssets && !hasUnresolvedAssets
        )
    }

    private func fetchPendingResources(limit: Int) -> DiscoveryResult {
        let skip = database.getAllAssetsOnServer()
        let partial = database.getPartialServerCopyAssets()
        let inflightKeys = database.getInflightJobKeys()

        let opts = PHFetchOptions()
        opts.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ]

        let allAssets = PHAsset.fetchAssets(with: .image, options: opts)
        let allVideos = PHAsset.fetchAssets(with: .video, options: opts)
        logDebug("Discovery: \(allAssets.count) image, \(allVideos.count) video assets")

        var pending = [PHAssetResource]()
        var scanned = 0
        var stoppedEarly = false
        let scanStart = Date()
        let scanDeadline = scanStart.addingTimeInterval(discoveryTimeBudget)
        var lastProgressLog = scanStart

        // Logs BEFORE the per-asset PHAssetResource.assetResources call: a hung
        // fetch shows up as progress stopping at a specific scanned count.
        let collect: (PHAsset) -> Void = { asset in
            scanned += 1
            if Date().timeIntervalSince(lastProgressLog) >= 2 {
                lastProgressLog = Date()
                self.log("Discovery progress: scanned \(scanned), found \(pending.count) pending")
            }
            let resources = PHAssetResource.assetResources(for: asset)
            for r in resources where self.shouldUpload(r) {
                let type = self.resourceTypeString(for: r)
                let key = "\(asset.localIdentifier)||\(type)"
                if inflightKeys.contains(key) { continue }
                // Partially-synced assets (e.g. primary confirmed by checksum, raw
                // never uploaded): filter each copy by its own server state so the
                // missing copy is (re)scheduled without reuploading the confirmed one.
                let copyOnServer = type == "raw"
                    ? partial.rawConfirmed.contains(asset.localIdentifier)
                    : partial.primaryConfirmed.contains(asset.localIdentifier)
                if copyOnServer { continue }
                if !self.database.isResourceUploaded(
                    assetId: asset.localIdentifier,
                    resourceType: type
                ) {
                    pending.append(r)
                }
            }
        }

        let enumerate: (PHFetchResult<PHAsset>) -> Void = { fetchResult in
            fetchResult.enumerateObjects { asset, _, stop in
                if self.isCancelled || pending.count >= limit || Date() >= scanDeadline {
                    stoppedEarly = true
                    stop.pointee = true
                    return
                }
                guard !skip.contains(asset.localIdentifier) else { return }
                collect(asset)
            }
        }
        enumerate(allAssets)
        if !stoppedEarly { enumerate(allVideos) }

        let elapsed = Date().timeIntervalSince(scanStart)
        logDebug("Discovery collected \(pending.count) pending resources in \(String(format: "%.1f", elapsed))s (complete: \(!stoppedEarly))")
        return DiscoveryResult(resources: pending, complete: !stoppedEarly)
    }


    // MARK: - Server Communication

    private func currentUploadURL() -> URL? {
        guard !settings.serverURL.isEmpty else { return nil }
        return URL(string: "\(settings.serverURL)/api/assets/background")
    }

    private func currentDestinationIdentity() -> String? {
        guard let url = currentUploadURL(), !settings.apiKey.isEmpty else { return nil }
        let material = "\(url.absoluteString)\u{0}\(settings.apiKey)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func jobTargetsCurrentDestination(_ job: PHAssetResourceUploadJob) -> Bool {
        guard let currentURL = currentUploadURL(),
              let jobURL = job.destination.url,
              jobURL == currentURL else { return false }
        return job.destination.value(forHTTPHeaderField: "Authorization")
            == "Bearer \(settings.apiKey)"
    }

    private func buildRetryDestination(for job: PHAssetResourceUploadJob) -> URLRequest? {
        guard let url = currentUploadURL(), !settings.apiKey.isEmpty else { return nil }
        var request = job.destination
        request.url = url
        request.httpMethod = "POST"
        request.allowsCellularAccess = BackgroundUploadPolicy.allowsCellularAccess(
            for: .retry,
            allowCellular: settings.allowCellularBackgroundUpload
        )
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func buildDestination(
        for resource: PHAssetResource,
        timezone: TimeZone,
        purpose: BackgroundUploadPolicy.RequestPurpose = .retry
    ) -> URLRequest? {
        guard let url = currentUploadURL(), !settings.apiKey.isEmpty else {
            return nil
        }

        guard let asset = fetchAsset(for: resource) else {
            logWarning("Could not fetch asset for resource: \(resource.originalFilename), skipping upload")
            return nil
        }
        let resolvedFilename = resource.resolvedFilename(using: asset)

        let created = asset.creationDate ?? Date()
        let modified = asset.modificationDate ?? Date()
        let isFavorite = asset.isFavorite

        let timezone = timezone
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withTimeZone]
        fmt.timeZone = timezone

        var req = URLRequest(url: url)
        req.allowsCellularAccess = BackgroundUploadPolicy.allowsCellularAccess(
            for: purpose,
            allowCellular: settings.allowCellularBackgroundUpload
        )
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")

        let deviceAssetId =
            "\(resource.assetLocalIdentifier)-\(resourceTypeString(for: resource))-\(resolvedFilename)"
        req.setValue(deviceAssetId, forHTTPHeaderField: "X-Device-Asset-Id")
        req.setValue("ios-fawenyo-yaiiu", forHTTPHeaderField: "X-Device-Id")
        req.setValue(
            fmt.string(from: created),
            forHTTPHeaderField: "X-File-Created-At"
        )
        req.setValue(
            fmt.string(from: modified),
            forHTTPHeaderField: "X-File-Modified-At"
        )
        req.setValue(isFavorite ? "true" : "false", forHTTPHeaderField: "X-Is-Favorite")
        req.setValue(
            resolvedFilename,
            forHTTPHeaderField: "X-Filename"
        )
        req.setValue(
            mimeType(for: resource),
            forHTTPHeaderField: "X-Content-Type"
        )
        req.setValue(
            ImageTimezoneOffsetFormatter.string(for: timezone.secondsFromGMT(for: created)),
            forHTTPHeaderField: "X-Timezone-Offset"
        )
        
        if let iCloudId = getCloudIdentifier(for: asset) {
            req.setValue(iCloudId, forHTTPHeaderField: "X-iCloud-Id")
        }
        
        if let location = asset.location {
            req.setValue(String(location.coordinate.latitude), forHTTPHeaderField: "X-Latitude")
            req.setValue(String(location.coordinate.longitude), forHTTPHeaderField: "X-Longitude")
        }

        return req
    }

    // MARK: - Resource Helpers

    private func shouldUpload(_ resource: PHAssetResource) -> Bool {
        switch resource.type {
        case .photo, .fullSizePhoto, .video, .fullSizeVideo, .alternatePhoto:
            return true
        default:
            return false
        }
    }

    private func resourceTypeString(for resource: PHAssetResource) -> String {
        let uti = resource.uniformTypeIdentifier.lowercased()

        let rawIndicators = [
            "raw-image", "dng", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2",
        ]
        if rawIndicators.contains(where: uti.contains)
            || resource.type == .alternatePhoto
        {
            return "raw"
        }

        if uti.contains("video") || uti.contains("movie") || uti.contains("mp4")
            || uti.contains("quicktime") || resource.type == .video
            || resource.type == .fullSizeVideo
        {
            return "video"
        }

        if resource.type == .photo || resource.type == .fullSizePhoto {
            if uti.contains("heic") || uti.contains("heif") { return "heic" }
            if uti.contains("png") { return "png" }
            return "jpeg"
        }

        return "primary"
    }


    private func mimeType(for resource: PHAssetResource) -> String {
        // Use the system UTI registry for accurate MIME type resolution.
        // Substring matching fails for UTIs like "public.hevc" which contain no
        // recognisable keyword but map to a well-known MIME type.
        if let utType = UTType(resource.uniformTypeIdentifier),
            let mime = utType.preferredMIMEType
        {
            return mime
        }

        // Fallback for unrecognised UTIs
        let uti = resource.uniformTypeIdentifier.lowercased()
        let mapping: [(check: (String) -> Bool, mime: String)] = [
            ({ $0.contains("jpeg") || $0.contains("jpg") }, "image/jpeg"),
            ({ $0.contains("png") }, "image/png"),
            ({ $0.contains("heic") || $0.contains("heif") }, "image/heic"),
            ({ $0.contains("gif") }, "image/gif"),
            ({ $0.contains("raw") || $0.contains("dng") }, "image/dng"),
            ({ $0.contains("hevc") }, "video/mp4"),
            ({ $0.contains("mp4") }, "video/mp4"),
            (
                { $0.contains("quicktime") || $0.contains("mov") },
                "video/quicktime"
            ),
            ({ $0.contains("video") }, "video/mp4"),
            ({ $0.contains("image") }, "image/jpeg"),
        ]

        return mapping.first { $0.check(uti) }?.mime
            ?? "application/octet-stream"
    }
    private func resource(for job: PHAssetResourceUploadJob) -> PHAssetResource? {
        if #available(iOS 27.0, *) {
            return PHAssetResource.assetResource(forUploadJob: job)
        }
        return job.resource
    }

    // In-flight jobs that any YAIIU build created carry their identity in the
    // destination request's X-Device-Asset-Id header. Resolving identity from the
    // header avoids PHAssetResource.assetResource(forUploadJob:), which on iOS 27
    // faults the job's CoreData row and aborts the process (uncatchable ObjC
    // exception) for legacy jobs whose asset row no longer resolves.
    private struct JobIdentity {
        let assetLocalIdentifier: String
        let resourceType: String
        let filename: String
    }

    private func identity(for job: PHAssetResourceUploadJob) -> JobIdentity? {
        if let value = job.destination.value(forHTTPHeaderField: "X-Device-Asset-Id"),
           let identity = Self.parseDeviceAssetId(value) {
            return identity
        }
        if #unavailable(iOS 27.0) {
            let resource = job.resource
            return JobIdentity(
                assetLocalIdentifier: resource.assetLocalIdentifier,
                resourceType: resourceTypeString(for: resource),
                filename: resource.originalFilename
            )
        }
        return nil
    }

    private static let resourceTypeTokens = ["primary", "raw", "video", "heic", "png", "jpeg"]

    private static func parseDeviceAssetId(_ value: String) -> JobIdentity? {
        // Format: "<assetLocalIdentifier>-<resourceType>-<filename>". PhotoKit local
        // identifiers are opaque, so candidate splits are not format-validated; each
        // prefix is checked against the photo library, and only the header's real
        // separator resolves to a live asset.
        var candidates: [(offset: String.Index, identity: JobIdentity)] = []
        for token in resourceTypeTokens {
            let separator = "-\(token)-"
            var searchStart = value.startIndex
            while let range = value.range(of: separator, range: searchStart..<value.endIndex) {
                let assetId = String(value[value.startIndex..<range.lowerBound])
                let filename = String(value[range.upperBound...])
                if !assetId.isEmpty, !filename.isEmpty {
                    candidates.append((
                        range.lowerBound,
                        JobIdentity(
                            assetLocalIdentifier: assetId,
                            resourceType: token,
                            filename: filename
                        )
                    ))
                }
                searchStart = range.upperBound
            }
        }
        for candidate in candidates.sorted(by: { $0.offset < $1.offset }) {
            if Self.assetExists(identifier: candidate.identity.assetLocalIdentifier) {
                return candidate.identity
            }
        }
        return nil
    }

    private static let assetExistenceCache = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    private static let iso8601Formatter = ISO8601DateFormatter()

    private static func assetExists(identifier: String) -> Bool {
        // Cache hits only: an asset can be transiently absent during iCloud
        // restoration or library sync, and a cached miss would strand the job as
        // unresolvable for the rest of the process.
        if assetExistenceCache.withLock({ $0.contains(identifier) }) { return true }
        let exists = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).count > 0
        if exists {
            assetExistenceCache.withLock { _ = $0.insert(identifier) }
        }
        return exists
    }

    private func jobMatchesCurrentAssetState(
        _ job: PHAssetResourceUploadJob,
        identity: JobIdentity
    ) -> Bool {
        guard jobTargetsCurrentDestination(job),
              let asset = fetchAsset(identifier: identity.assetLocalIdentifier) else {
            return false
        }

        if let value = job.destination.value(forHTTPHeaderField: "X-File-Modified-At"),
           let uploadedDate = Self.iso8601Formatter.date(from: value),
           let currentDate = asset.modificationDate,
           abs(uploadedDate.timeIntervalSince(currentDate)) > 1 {
            return false
        }

        if let value = job.destination.value(forHTTPHeaderField: "X-Is-Favorite"),
           value != (asset.isFavorite ? "true" : "false") {
            return false
        }

        if let latitude = job.destination.value(forHTTPHeaderField: "X-Latitude"),
           let longitude = job.destination.value(forHTTPHeaderField: "X-Longitude") {
            guard let oldLat = Double(latitude),
                  let oldLong = Double(longitude),
                  let location = asset.location,
                  abs(oldLat - location.coordinate.latitude) < 0.0000001,
                  abs(oldLong - location.coordinate.longitude) < 0.0000001 else {
                return false
            }
        } else if asset.location != nil {
            // The current asset gained location metadata after this job was created.
            return false
        }

        return true
    }

    private func uploadableResource(for job: PHAssetResourceUploadJob) -> PHAssetResource? {
        if #available(iOS 27.0, *) {
            guard let identity = identity(for: job),
                  let asset = fetchAsset(identifier: identity.assetLocalIdentifier) else { return nil }
            // Edited assets can replace the original resource; matching on anything
            // coarser than the job's filename builds a destination whose metadata
            // describes a different resource than PhotoKit will upload.
            return PHAssetResource.assetResources(for: asset)
                .first { shouldUpload($0) && $0.resolvedFilename(using: asset) == identity.filename }
        }
        return resource(for: job)
    }

    private func uploadJobCapacity() -> Int {
        guard #available(iOS 26.5, *) else { return Int.max }
        let inflight = PHAssetResourceUploadJob.fetchJobs(action: .process, options: nil).count
            + PHAssetResourceUploadJob.fetchJobs(action: .acknowledge, options: nil).count
        let headroom = Swift.max(0, PHAssetResourceUploadJob.jobLimit - inflight)
        logDebug("Upload job capacity: \(headroom) available, \(inflight) unacknowledged, limit \(PHAssetResourceUploadJob.jobLimit)")
        return headroom
    }

    private let staleJobAgeLimit: TimeInterval = 24 * 60 * 60

    private func jobErrorDescription(_ job: PHAssetResourceUploadJob) -> String {
        guard #available(iOS 26.4, *), let error = job.error else {
            return "unknown error"
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }


    private func captureTimezones(for resources: [PHAssetResource]) -> [String: TimeZone] {
        let fallback = TimeZone.current
        let identifiers = Array(Set(resources.map(\.assetLocalIdentifier)))
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        let group = DispatchGroup()
        let lock = NSLock()
        var resolved = Dictionary(uniqueKeysWithValues: identifiers.map { ($0, fallback) })
        var requests = [MKReverseGeocodingRequest]()

        assets.enumerateObjects { asset, _, _ in
            guard let location = asset.location,
                  let request = MKReverseGeocodingRequest(location: location) else {
                return
            }
            requests.append(request)
            group.enter()
            request.getMapItems { mapItems, _ in
                if let timezone = mapItems?.first?.timeZone {
                    lock.lock()
                    resolved[asset.localIdentifier] = timezone
                    lock.unlock()
                }
                group.leave()
            }
        }

        if group.wait(timeout: .now() + 3) == .timedOut {
            for request in requests {
                request.cancel()
            }
        }
        lock.lock()
        let snapshot = resolved
        lock.unlock()
        return snapshot
    }

    private func fetchAsset(for resource: PHAssetResource) -> PHAsset? {
        fetchAsset(identifier: resource.assetLocalIdentifier)
    }

    private func fetchAsset(identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }
    
    // MARK: - iCloud Identifier
    
    private func getCloudIdentifier(for asset: PHAsset) -> String? {
        guard #available(iOS 16, *) else {
            return nil
        }
        
        let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [asset.localIdentifier])
        
        guard let result = mappings[asset.localIdentifier] else {
            return nil
        }
        
        switch result {
        case .success(let cloudIdentifier):
            let cloudId = cloudIdentifier.stringValue
            // Skip invalid cloud IDs (format: "GUID:ID:" without hash suffix)
            if cloudId.hasSuffix(":") {
                logDebug("Invalid cloud ID format for asset \(asset.localIdentifier)")
                return nil
            }
            return cloudId
        case .failure(let error):
            logDebug("Failed to get cloud ID for asset \(asset.localIdentifier): \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Logging
    
    private static let logCategory = LogCategory.backgroundUpload.rawValue
    
    private lazy var logFileWriter: LogFileWriter? = {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return nil
        }
        let logURL = container.appendingPathComponent("background_upload.log")
        return LogFileWriter(
            fileURL: logURL,
            queueLabel: "com.fawenyo.yaiiu.bgupload.log"
        )
    }()
    
    private func log(_ message: String, level: LogLevel = .info) {
        let formatted = LogFormatter.formatLogEntry(
            timestamp: Date(),
            level: level,
            category: Self.logCategory,
            message: message
        )
        print(formatted)
        // Synchronous write: the system kills this process without warning, and an
        // async queue would drop the very lines that record how far a run got.
        logFileWriter?.appendSync(timestamp: Date(), level: level, category: Self.logCategory, message: message)
    }
    
    private func logDebug(_ message: String) {
        log(message, level: .debug)
    }
    
    private func logWarning(_ message: String) {
        log(message, level: .warning)
    }
    
    private func logError(_ message: String) {
        log(message, level: .error)
    }
}
@available(iOS 27.0, *)
extension BackgroundUploadExtensionCore {
    func processJobs() async -> PHBackgroundResourceUploadProcessingResult {
        resetCancellation()
        log("Processing background upload jobs...")
        guard !isCancelled else { return .processing }

        do {
            switch try processUploadJobs() {
            case .completed, .scheduled:
                return .completed
            case .deferred, .remaining:
                return .processing
            }
        } catch let error as NSError
            where error.domain == PHPhotosErrorDomain
            && error.code == PHPhotosError.limitExceeded.rawValue
        {
            logWarning("PhotoKit in-flight job limit exceeded; deferring new work")
            return .processing
        } catch {
            logError("Error: \(error.localizedDescription)")
            return .failure
        }
    }
}

@available(iOS 27.0, *)
final class BackgroundUploadExtension: PHBackgroundResourceUploadJobExtension {
    private let core = BackgroundUploadExtensionCore()

    required init() {}

    func processJobs() async -> PHBackgroundResourceUploadProcessingResult {
        await core.processJobs()
    }

    func willTerminate() async {
        core.notifyTermination()
    }
}

@available(iOS, introduced: 26.1, obsoleted: 27.0)
final class LegacyBackgroundUploadExtension: PHBackgroundResourceUploadExtension {
    private let core = BackgroundUploadExtensionCore()

    required init() {}

    func process() -> PHBackgroundResourceUploadProcessingResult {
        core.process()
    }

    func notifyTermination() {
        core.notifyTermination()
    }
}

private enum ImageTimezoneOffsetFormatter {
    static func string(for secondsFromGMT: Int) -> String {
        let sign = secondsFromGMT < 0 ? "-" : "+"
        let absoluteSeconds = abs(secondsFromGMT)
        return String(format: "%@%02d:%02d", sign, absoluteSeconds / 3600, (absoluteSeconds % 3600) / 60)
    }
}
