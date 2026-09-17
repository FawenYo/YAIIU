import CoreLocation
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
            return .completed
        }

        var madeProgress = try retryFailedJobs()
        guard !isCancelled else { return .deferred }

        madeProgress = try acknowledgeCompletedJobs() || madeProgress
        guard !isCancelled else { return .deferred }

        madeProgress = cancelRedundantJobs() || madeProgress
        guard !isCancelled else { return .deferred }

        let result = try createNewUploadJobs(interface: currentNetworkInterface())
        reconcileTrackedJobs()
        guard result == .completed else { return result }

        return madeProgress || hasJobsInFlight() ? .scheduled : .completed
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

        let onServer = database.getAllAssetsOnServer()
        let trackedAges = database.getTrackedJobAges()
        let staleCutoff = Date().addingTimeInterval(-staleJobAgeLimit)
        var cancelledAny = false

        for i in 0..<jobs.count where !isCancelled {
            let job = jobs.object(at: i)
            let identity = identity(for: job)
            let key = identity.map { "\($0.assetLocalIdentifier)||\($0.resourceType)" }

            let reason: String
            if let identity {
                if onServer.contains(identity.assetLocalIdentifier)
                    || database.isResourceUploaded(
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

            do {
                try library.performChangesAndWait {
                    guard let request = PHAssetResourceUploadJobChangeRequest(for: job) else { return }
                    request.cancel()
                    cancelledAny = true
                }
                logWarning("Cancelled in-flight job \(job.localIdentifier): \(reason)")
                if let identity {
                    database.markJobStatus(
                        assetId: identity.assetLocalIdentifier,
                        resourceType: identity.resourceType,
                        status: .completed
                    )
                }
            } catch {
                logError("Failed to cancel job \(job.localIdentifier): \(error.localizedDescription)")
            }
        }
        return cancelledAny
    }

    // Drops locally tracked jobs that no longer exist in PhotoKit. Without this, rows
    // left by crashes or library churn keep their assets permanently skipped by
    // fetchPendingResources.
    private func reconcileTrackedJobs() {
        guard #available(iOS 26.5, *) else { return }
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

        var retryResources = [(job: PHAssetResourceUploadJob, resource: PHAssetResource)]()
        for i in 0..<jobs.count where !isCancelled {
            let job = jobs.object(at: i)
            guard let resource = uploadableResource(for: job) else {
                logWarning("Skipping retry for job \(job.localIdentifier): resource unavailable; will acknowledge instead")
                continue
            }
            retryResources.append((job, resource))
        }

        // Rebuild destinations from current settings; job.destination may carry a
        // stale server URL or credential from before a logout/login or server move.
        let timezones = captureTimezones(for: retryResources.map(\.resource))
        guard !isCancelled else { return false }

        for (job, resource) in retryResources where !isCancelled {
            let errorDescription = jobErrorDescription(job)
            logWarning("Retrying failed upload job \(job.localIdentifier): \(errorDescription)")

            guard let destination = buildDestination(
                for: resource,
                timezone: timezones[resource.assetLocalIdentifier] ?? TimeZone.current,
                purpose: .retry
            ) else {
                logWarning("Skipping retry for \(resource.originalFilename): destination unavailable")
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

    private func acknowledgeCompletedJobs() throws -> Bool {
        let library = PHPhotoLibrary.shared()
        let jobs = PHAssetResourceUploadJob.fetchJobs(
            action: .acknowledge,
            options: nil
        )
        if jobs.count > 0 {
            logDebug("Acknowledgeable jobs: \(jobs.count)")
        }

        var acknowledgedAny = false
        for i in 0..<jobs.count where !isCancelled {
            let job = jobs.object(at: i)
            let succeeded = job.state == .succeeded
            let identity = identity(for: job)
            if identity == nil {
                logWarning("Could not resolve identity for completed job \(job.localIdentifier); acknowledging without recording")
            }

            // Acknowledge first: freeing job-limit space must never depend on
            // bookkeeping that can fail for legacy jobs.
            do {
                try library.performChangesAndWait {
                    guard let request = PHAssetResourceUploadJobChangeRequest(for: job) else { return }
                    request.acknowledge()
                }
            } catch {
                logError("Failed to acknowledge job \(job.localIdentifier): \(error.localizedDescription)")
                continue
            }
            acknowledgedAny = true

            guard let identity else { continue }
            if succeeded {
                let immichId: String
                if #available(iOS 26.4, *),
                   let value = job.responseHeaderFields?[immichAssetIDHeader],
                   UUID(uuidString: value) != nil {
                    immichId = value
                } else {
                    immichId = "unknown"
                }
                database.recordUploadedAsset(
                    assetId: identity.assetLocalIdentifier,
                    resourceType: identity.resourceType,
                    filename: identity.filename,
                    immichId: immichId,
                    fileSize: 0,
                    isDuplicate: false
                )
                SharedSettings.shared.lastBackgroundUploadAt = Date()
                log("Acknowledged successful upload: \(identity.filename)")
            } else {
                logWarning("Acknowledged failed upload: \(identity.filename)")
            }
            database.markJobStatus(
                assetId: identity.assetLocalIdentifier,
                resourceType: identity.resourceType,
                status: succeeded ? .completed : .failed
            )
        }
        return acknowledgedAny
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
        let resources = fetchPendingResources()
        logDebug("Found \(resources.count) pending resources for upload")
        guard !resources.isEmpty else { return .completed }

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

        let timezones = captureTimezones(for: resources)
        guard !isCancelled else { return .deferred }

        let capacity = uploadJobCapacity()
        let batch = Array(resources.prefix(capacity))
        guard !batch.isEmpty else {
            logWarning("PhotoKit job limit already reached; waiting for acknowledgements before creating new jobs")
            return .remaining
        }
        if batch.count < resources.count {
            logDebug("Capped new jobs to \(batch.count) of \(resources.count) pending to respect job limit")
        }

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
            }
        }
        return createdAny ? .scheduled : .remaining
    }

    // MARK: - Resource Discovery

    private func fetchPendingResources() -> [PHAssetResource] {
        let skip = database.getAllAssetsOnServer()
        let inflightKeys = database.getInflightJobKeys()

        let opts = PHFetchOptions()
        opts.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ]

        let allAssets = PHAsset.fetchAssets(with: .image, options: opts)
        let allVideos = PHAsset.fetchAssets(with: .video, options: opts)

        var pending = [PHAssetResource]()

        let collect: (PHAsset) -> Void = { asset in
            let resources = PHAssetResource.assetResources(for: asset)
            for r in resources where self.shouldUpload(r) {
                let type = self.resourceTypeString(for: r)
                let key = "\(asset.localIdentifier)||\(type)"
                if inflightKeys.contains(key) { continue }
                if !self.database.isResourceUploaded(
                    assetId: asset.localIdentifier,
                    resourceType: type
                ) {
                    pending.append(r)
                }
            }
        }

        allAssets.enumerateObjects { asset, _, stop in
            if self.isCancelled {
                stop.pointee = true
                return
            }
            guard !skip.contains(asset.localIdentifier) else { return }
            collect(asset)
        }

        allVideos.enumerateObjects { asset, _, stop in
            if self.isCancelled {
                stop.pointee = true
                return
            }
            guard !skip.contains(asset.localIdentifier) else { return }
            collect(asset)
        }
        logDebug("Collected \(pending.count) pending resources")

        return pending
    }


    // MARK: - Server Communication
    private func buildDestination(
        for resource: PHAssetResource,
        timezone: TimeZone,
        purpose: BackgroundUploadPolicy.RequestPurpose = .retry
    ) -> URLRequest? {
        guard !settings.serverURL.isEmpty, !settings.apiKey.isEmpty,
            let url = URL(string: "\(settings.serverURL)/api/assets/background")
        else {
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
        // Format: "<assetLocalIdentifier>-<resourceType>-<filename>" with the asset
        // identifier always ending in PhotoKit's "/L<n>/<nnn>" suffix.
        var best: JobIdentity?
        for token in resourceTypeTokens {
            let separator = "-\(token)-"
            var searchStart = value.startIndex
            while let range = value.range(of: separator, range: searchStart..<value.endIndex) {
                let assetId = String(value[value.startIndex..<range.lowerBound])
                let filename = String(value[range.upperBound...])
                if isPhotoKitIdentifier(assetId), !filename.isEmpty,
                   best == nil || assetId.count > best!.assetLocalIdentifier.count {
                    best = JobIdentity(
                        assetLocalIdentifier: assetId,
                        resourceType: token,
                        filename: filename
                    )
                }
                searchStart = range.upperBound
            }
        }
        return best
    }

    private static func isPhotoKitIdentifier(_ value: String) -> Bool {
        value.range(of: #"/[A-Za-z]\d+/\d{3}$"#, options: .regularExpression) != nil
    }

    private func uploadableResource(for job: PHAssetResourceUploadJob) -> PHAssetResource? {
        if #available(iOS 27.0, *) {
            guard let identity = identity(for: job),
                  let asset = fetchAsset(identifier: identity.assetLocalIdentifier) else { return nil }
            return PHAssetResource.assetResources(for: asset)
                .first { shouldUpload($0) && resourceTypeString(for: $0) == identity.resourceType }
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
        logFileWriter?.appendLine(formatted)
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
            case .completed:
                return .completed
            case .deferred, .remaining, .scheduled:
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
