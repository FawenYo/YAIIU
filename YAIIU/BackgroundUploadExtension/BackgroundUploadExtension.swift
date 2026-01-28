import CommonCrypto
import CoreLocation
import ExtensionFoundation
import Photos
import os.lock

@main
final class BackgroundUploadExtension: PHBackgroundResourceUploadExtension {

    private let cancelledState = OSAllocatedUnfairLock(initialState: false)
    private let settings = SharedSettings.shared
    private let database = BackgroundUploadDatabase.shared
    private let appGroupID = "group.com.fawenyo.yaiiu"

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    private var isCancelled: Bool {
        cancelledState.withLock { $0 }
    }

    required init() {
        log("Initialized")
    }

    // MARK: - PHBackgroundResourceUploadExtension

    func process() -> PHBackgroundResourceUploadProcessingResult {
        log("Processing background upload jobs...")
        guard !isCancelled else { return .processing }
        guard settings.isLoggedIn, settings.backgroundUploadEnabled else {
            return .completed
        }

        do {
            try retryFailedJobs()
            guard !isCancelled else { return .processing }

            try acknowledgeCompletedJobs()
            guard !isCancelled else { return .processing }

            try createNewUploadJobs()
            return .completed

        } catch let error as NSError
            where error.domain == PHPhotosErrorDomain
            && error.code == PHPhotosError.limitExceeded.rawValue
        {
            return .processing
        } catch {
            logError("Error: \(error.localizedDescription)")
            return .failure
        }
    }

    func notifyTermination() {
        cancelledState.withLock { $0 = true }
    }

    // MARK: - Job Management

    private func retryFailedJobs() throws {
        let library = PHPhotoLibrary.shared()
        let jobs = PHAssetResourceUploadJob.fetchJobs(
            action: .retry,
            options: nil
        )

        for i in 0..<jobs.count where !isCancelled {
            let job = jobs.object(at: i)
            try library.performChangesAndWait {
                guard let req = PHAssetResourceUploadJobChangeRequest(for: job)
                else { return }
                // Rebuild destination to refresh auth token if needed
                req.retry(destination: self.buildDestination(for: job.resource))
            }
        }
    }

    private func acknowledgeCompletedJobs() throws {
        let library = PHPhotoLibrary.shared()
        let jobs = PHAssetResourceUploadJob.fetchJobs(
            action: .acknowledge,
            options: nil
        )

        for i in 0..<jobs.count where !isCancelled {
            let job = jobs.object(at: i)
            let resource = job.resource

            database.recordUploadedAsset(
                assetId: resource.assetLocalIdentifier,
                resourceType: resourceTypeString(for: resource),
                filename: resource.originalFilename,
                immichId: "unknown",
                fileSize: 0,
                isDuplicate: false
            )

            try library.performChangesAndWait {
                PHAssetResourceUploadJobChangeRequest(for: job)?.acknowledge()
            }
        }
    }

    private func createNewUploadJobs() throws {
        let library = PHPhotoLibrary.shared()
        let resources = fetchPendingResources()
        logDebug("Found \(resources.count) pending resources for upload")
        guard !resources.isEmpty else { return }

        try library.performChangesAndWait {
            for resource in resources where !self.isCancelled {
                guard let dest = self.buildDestination(for: resource) else {
                    continue
                }
                self.logDebug("Creating upload job for resource: \(resource.originalFilename)")

                PHAssetResourceUploadJobChangeRequest.createJob(
                    destination: dest,
                    resource: resource
                )
                self.database.createOrUpdateJob(
                    assetId: resource.assetLocalIdentifier,
                    resourceType: self.resourceTypeString(for: resource),
                    filename: resource.originalFilename,
                    status: .uploading
                )
            }
        }
    }

    // MARK: - Resource Discovery

    private func fetchPendingResources() -> [PHAssetResource] {
        let uploaded = database.getAllUploadedAssetIds()
        let synced = database.getAllAssetsOnServer()
        let hashConfirmed = database.getAssetsConfirmedOnServer()
        let skip = uploaded.union(synced).union(hashConfirmed)

        let opts = PHFetchOptions()
        opts.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ]
        
        let allAssets = PHAsset.fetchAssets(with: .image, options: opts)
        let allVideos = PHAsset.fetchAssets(with: .video, options: opts)

        var pending = [PHAssetResource]()
        var candidates = [PHAsset]()
        let batchSize = 100
        let maxPending = 50

        // Process photos
        allAssets.enumerateObjects { asset, _, stop in
            if self.isCancelled {
                stop.pointee = true
                return
            }
            guard !skip.contains(asset.localIdentifier) else { return }

            candidates.append(asset)

            if candidates.count >= batchSize {
                pending.append(contentsOf: self.filterCandidates(candidates))
                candidates.removeAll()
                if pending.count >= maxPending { stop.pointee = true }
            }
        }

        // Process videos if we haven't reached the limit
        if pending.count < maxPending {
            allVideos.enumerateObjects { asset, _, stop in
                if self.isCancelled {
                    stop.pointee = true
                    return
                }
                guard !skip.contains(asset.localIdentifier) else { return }

                candidates.append(asset)

                if candidates.count >= batchSize {
                    pending.append(contentsOf: self.filterCandidates(candidates))
                    candidates.removeAll()
                    if pending.count >= maxPending { stop.pointee = true }
                }
            }
        }

        // Process remaining candidates
        if !candidates.isEmpty && pending.count < maxPending {
            pending.append(contentsOf: filterCandidates(candidates))
        }

        return Array(pending.prefix(maxPending))
    }

    private func filterCandidates(_ candidates: [PHAsset]) -> [PHAssetResource]
    {
        var result = [PHAssetResource]()

        for asset in candidates where !isCancelled {
            let resources = PHAssetResource.assetResources(for: asset)
            guard let primary = selectPrimaryResource(from: resources) else {
                continue
            }

            if isAssetOnServer(asset: asset, resource: primary) { continue }

            for r in resources where shouldUpload(r) {
                let type = resourceTypeString(for: r)
                if !database.isResourceUploaded(
                    assetId: asset.localIdentifier,
                    resourceType: type
                ) {
                    result.append(r)
                }
            }

            if result.count >= 50 { break }
        }

        return result
    }

    private func isAssetOnServer(asset: PHAsset, resource: PHAssetResource)
        -> Bool
    {
        let id = asset.localIdentifier

        if let cached = database.getHashForAsset(assetId: id) {
            if checkServerForChecksum(cached) {
                database.recordHashChecked(assetId: id, sha1Hash: cached, isOnServer: true)
                return true
            }
            return false
        }

        guard let hash = computeSHA1(for: resource) else { return false }
        database.saveAssetHash(assetId: id, sha1Hash: hash)

        let exists = checkServerForChecksum(hash)
        database.recordHashChecked(assetId: id, sha1Hash: hash, isOnServer: exists)
        return exists
    }

    // MARK: - Server Communication

    private func checkServerForChecksum(_ checksum: String) -> Bool {
        guard !settings.serverURL.isEmpty, !settings.apiKey.isEmpty,
            let url = URL(string: "\(settings.serverURL)/api/search/metadata")
        else {
            return false
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "checksum": checksum
        ])

        var found = false
        let sema = DispatchSemaphore(value: 0)

        urlSession.dataTask(with: req) { data, resp, _ in
            defer { sema.signal() }
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                let data = data,
                let json = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let assets = json["assets"] as? [String: Any],
                let items = assets["items"] as? [[String: Any]]
            else { return }
            found = !items.isEmpty
        }.resume()

        _ = sema.wait(timeout: .now() + 15)
        return found
    }

    private func buildDestination(for resource: PHAssetResource) -> URLRequest?
    {
        guard !settings.serverURL.isEmpty, !settings.apiKey.isEmpty,
            let url = URL(string: "\(settings.serverURL)/api/assets/background")
        else {
            return nil
        }

        // Ensure we can fetch the asset; skip if not found to avoid incorrect metadata
        guard let asset = fetchAsset(for: resource) else {
            logWarning("Could not fetch asset for resource: \(resource.originalFilename), skipping upload")
            return nil
        }
        
        let created = asset.creationDate ?? Date()
        let modified = asset.modificationDate ?? Date()
        let isFavorite = asset.isFavorite
        
        // Use device's current timezone for background extension
        // Note: We cannot use CLGeocoder in background extension due to strict execution time limits
        // The system may terminate the extension if we block for network calls
        let timezone = TimeZone.current
        
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withTimeZone]
        fmt.timeZone = timezone

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")

        // Metadata passed via headers for proxy server conversion
        let deviceAssetId =
            "\(resource.assetLocalIdentifier)-\(resourceTypeString(for: resource))-\(resource.originalFilename)"
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
            resource.originalFilename,
            forHTTPHeaderField: "X-Filename"
        )
        req.setValue(
            mimeType(for: resource),
            forHTTPHeaderField: "X-Content-Type"
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

    // MARK: - Hash Computation

    private func computeSHA1(for resource: PHAssetResource) -> String? {
        var ctx = CC_SHA1_CTX()
        CC_SHA1_Init(&ctx)

        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = false

        var result: String?
        let sema = DispatchSemaphore(value: 0)

        PHAssetResourceManager.default().requestData(
            for: resource,
            options: opts
        ) { chunk in
            chunk.withUnsafeBytes { buf in
                _ = CC_SHA1_Update(&ctx, buf.baseAddress, CC_LONG(chunk.count))
            }
        } completionHandler: { error in
            if error == nil {
                var digest = [UInt8](
                    repeating: 0,
                    count: Int(CC_SHA1_DIGEST_LENGTH)
                )
                CC_SHA1_Final(&digest, &ctx)
                result = digest.map { String(format: "%02x", $0) }.joined()
            }
            sema.signal()
        }

        guard sema.wait(timeout: .now() + 60) == .success else { return nil }
        return result
    }

    // MARK: - Resource Helpers

    private func selectPrimaryResource(from resources: [PHAssetResource])
        -> PHAssetResource?
    {
        resources.first {
            $0.type == .fullSizePhoto || $0.type == .fullSizeVideo
        }
            ?? resources.first { $0.type == .photo || $0.type == .video }
            ?? resources.first
    }

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
        let uti = resource.uniformTypeIdentifier.lowercased()

        let mapping: [(check: (String) -> Bool, mime: String)] = [
            ({ $0.contains("jpeg") || $0.contains("jpg") }, "image/jpeg"),
            ({ $0.contains("png") }, "image/png"),
            ({ $0.contains("heic") || $0.contains("heif") }, "image/heic"),
            ({ $0.contains("gif") }, "image/gif"),
            ({ $0.contains("raw") || $0.contains("dng") }, "image/dng"),
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

    private func fetchAsset(for resource: PHAssetResource) -> PHAsset? {
        PHAsset.fetchAssets(
            withLocalIdentifiers: [resource.assetLocalIdentifier],
            options: nil
        ).firstObject
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
