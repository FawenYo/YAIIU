import Photos
import ExtensionFoundation
import os.lock
import CommonCrypto

/// BackgroundUploadExtension - iOS 26.1 Background Resource Upload Extension
/// Implements PHBackgroundResourceUploadExtension protocol to handle background photo uploads to Immich server
/// via the immich-proxy server which converts raw photo data to multipart/form-data format
@main
class BackgroundUploadExtension: PHBackgroundResourceUploadExtension {
    
    // MARK: - Properties
    
    /// Use OSAllocatedUnfairLock for thread-safe cancellation state handling
    private let isCancelledLock = OSAllocatedUnfairLock(initialState: false)
    
    /// Shared settings
    private let settings = SharedSettings.shared
    
    /// Shared database
    private let database = BackgroundUploadDatabase.shared
    
    /// Maximum retry count
    private let maxRetryCount = 3
    
    /// URL session for API requests
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()
    
    // MARK: - Initialization
    
    required init() {
        log("BackgroundUploadExtension initialized")
    }
    
    // MARK: - PHBackgroundResourceUploadExtension Protocol
    
    /// Process upload tasks
    /// System calls this method when there are upload jobs to process
    func process() -> PHBackgroundResourceUploadProcessingResult {
        log("process() called")
        
        // Check if cancelled
        if isCancelledLock.withLock({ $0 }) {
            log("Process cancelled, returning .processing")
            return .processing
        }
        
        // Check if logged in
        guard settings.isLoggedIn else {
            log("Not logged in, returning .completed")
            return .completed
        }
        
        // Check if background upload is enabled
        guard settings.backgroundUploadEnabled else {
            log("Background upload disabled, returning .completed")
            return .completed
        }
        
        do {
            // 1. Retry failed jobs
            try retryFailedJobs()
            
            // Check cancellation state
            if isCancelledLock.withLock({ $0 }) {
                return .processing
            }
            
            // 2. Acknowledge completed jobs (release in-flight job limit)
            try acknowledgeCompletedJobs()
            
            // Check cancellation state
            if isCancelledLock.withLock({ $0 }) {
                return .processing
            }
            
            // 3. Create new upload jobs
            try createNewUploadJobs()
            
            log("process() completed successfully")
            return .completed
            
        } catch let error as NSError {
            if error.domain == PHPhotosErrorDomain &&
               error.code == PHPhotosError.limitExceeded.rawValue {
                // Reached in-flight job limit, return .processing to let system call again later
                log("Limit exceeded, returning .processing")
                return .processing
            }
            // Other errors
            log("Process error: \(error.localizedDescription)")
            return .failure
        } catch {
            log("Process error: \(error.localizedDescription)")
            return .failure
        }
    }
    
    /// Notify termination
    /// System calls this method before terminating the extension
    func notifyTermination() {
        log("notifyTermination() called")
        
        // Set cancellation flag to let process() exit as soon as possible
        isCancelledLock.withLock { $0 = true }
        
        // Perform necessary cleanup
        // Note: Time is limited here, only do essential cleanup
    }
    
    // MARK: - Retry Failed Jobs
    
    /// Retry failed jobs
    private func retryFailedJobs() throws {
        log("Retrying failed jobs...")
        
        let library = PHPhotoLibrary.shared()
        let retryableJobs = PHAssetResourceUploadJob.fetchJobs(action: .retry, options: nil)
        
        log("Found \(retryableJobs.count) retryable jobs")
        
        for i in 0..<retryableJobs.count {
            // Check cancellation state
            if isCancelledLock.withLock({ $0 }) {
                log("Retry cancelled")
                return
            }
            
            let job = retryableJobs.object(at: i)
            
            try library.performChangesAndWait {
                guard let request = PHAssetResourceUploadJobChangeRequest(for: job) else {
                    return
                }
                
                // Retry with original destination, or create new destination URL if needed
                // We may need to refresh auth token, so create new destination
                if let newDestination = self.buildDestination(for: job.resource) {
                    request.retry(destination: newDestination)
                } else {
                    request.retry(destination: nil)
                }
            }
            
            log("Retried job for resource: \(job.resource.originalFilename)")
        }
    }
    
    // MARK: - Acknowledge Completed Jobs
    
    /// Acknowledge completed jobs
    private func acknowledgeCompletedJobs() throws {
        log("Acknowledging completed jobs...")
        
        let library = PHPhotoLibrary.shared()
        let completedJobs = PHAssetResourceUploadJob.fetchJobs(action: .acknowledge, options: nil)
        
        log("Found \(completedJobs.count) jobs to acknowledge")
        
        for i in 0..<completedJobs.count {
            // Check cancellation state
            if isCancelledLock.withLock({ $0 }) {
                log("Acknowledge cancelled")
                return
            }
            
            let job = completedJobs.object(at: i)
            let resource = job.resource
            let assetIdentifier = resource.assetLocalIdentifier
            
            // Jobs fetched with .acknowledge action are completed (either success or failure)
            // Record upload result to local database
            // Since we're acknowledging, we assume the upload was successful
            // (failed jobs that exceeded retry limit will also appear here)
            let immichId = extractImmichIdFromJob(job)
            
            database.recordUploadedAsset(
                assetLocalIdentifier: assetIdentifier,
                resourceType: getResourceType(for: resource),
                filename: resource.originalFilename,
                immichId: immichId ?? "unknown",
                fileSize: 0,  // Actual size is not available here
                isDuplicate: false
            )
            
            log("Recorded upload for: \(resource.originalFilename)")
            
            try library.performChangesAndWait {
                guard let request = PHAssetResourceUploadJobChangeRequest(for: job) else {
                    return
                }
                request.acknowledge()
            }
            
            log("Acknowledged job: \(resource.originalFilename)")
        }
    }
    
    // MARK: - Create New Upload Jobs
    
    /// Create new upload jobs
    private func createNewUploadJobs() throws {
        log("Creating new upload jobs...")
        
        let library = PHPhotoLibrary.shared()
        
        // Get unprocessed resources
        let resources = getUnprocessedResources(from: library)
        
        guard !resources.isEmpty else {
            log("No unprocessed resources found")
            return
        }
        
        log("Found \(resources.count) unprocessed resources")
        
        try library.performChangesAndWait {
            for resource in resources {
                // Check cancellation state
                if self.isCancelledLock.withLock({ $0 }) {
                    self.log("Job creation cancelled")
                    return
                }
                
                // Build destination URL request
                guard let destination = self.buildDestination(for: resource) else {
                    self.log("Failed to build destination for: \(resource.originalFilename)")
                    continue
                }
                
                // Create upload job
                PHAssetResourceUploadJobChangeRequest.createJob(
                    destination: destination,
                    resource: resource
                )
                
                // Mark as processed
                self.markAsProcessed(resource.assetLocalIdentifier, resourceType: self.getResourceType(for: resource))
                
                self.log("Created job for: \(resource.originalFilename)")
            }
        }
    }
    
    // MARK: - Helper Methods
    
    /// Get unprocessed resources that need to be uploaded
    /// This method uses a smart batching strategy to process all assets efficiently:
    /// 1. Fetches assets in batches without a hard limit
    /// 2. Skips already processed assets using local database cache
    /// 3. Performs hash checking only for new candidates
    /// 4. Continues processing until all assets are checked or resource limit is reached
    private func getUnprocessedResources(from library: PHPhotoLibrary) -> [PHAssetResource] {
        var unprocessedResources: [PHAssetResource] = []
        
        // Get already uploaded asset identifiers from the extension's upload history
        let uploadedIdentifiers = database.getAllUploadedAssetIdentifiers()
        
        // Get assets that are already on the server (synced from main app's SQLite import)
        let assetsOnServer = database.getAllAssetsOnServer()
        
        // Get assets that have been hash-checked and confirmed on server
        let hashCheckedOnServer = database.getAssetsConfirmedOnServer()
        
        log("Found \(uploadedIdentifiers.count) uploaded, \(assetsOnServer.count) synced from main app, \(hashCheckedOnServer.count) hash-checked on server")
        
        // Combine all sets to get assets that should be skipped
        let skipIdentifiers = uploadedIdentifiers.union(assetsOnServer).union(hashCheckedOnServer)
        
        log("Total assets to skip: \(skipIdentifiers.count)")
        
        // Fetch all photos and videos without limit
        // We'll process them in batches but won't miss any
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // Remove fetchLimit to get all assets
        
        let allAssets = PHAsset.fetchAssets(with: fetchOptions)
        let totalAssetCount = allAssets.count
        
        log("Total assets in photo library: \(totalAssetCount)")
        
        // Process assets in batches to avoid memory issues
        let batchSize = 100
        var processedCount = 0
        var candidateAssets: [PHAsset] = []
        
        // Enumerate all assets and collect candidates
        allAssets.enumerateObjects { (asset, index, stop) in
            // Check cancellation state
            if self.isCancelledLock.withLock({ $0 }) {
                stop.pointee = true
                return
            }
            
            // Skip assets that are already uploaded or confirmed on server
            if skipIdentifiers.contains(asset.localIdentifier) {
                return
            }
            
            candidateAssets.append(asset)
            processedCount += 1
            
            // Process in batches to avoid memory issues
            // But continue until we have enough resources or checked all assets
            if candidateAssets.count >= batchSize {
                // Process this batch
                let batchResources = self.processCandidateBatch(candidateAssets)
                unprocessedResources.append(contentsOf: batchResources)
                candidateAssets.removeAll()
                
                // If we have enough resources to upload, stop early
                if unprocessedResources.count >= 50 {
                    stop.pointee = true
                    return
                }
            }
        }
        
        // Process remaining candidates
        if !candidateAssets.isEmpty && unprocessedResources.count < 50 {
            let batchResources = processCandidateBatch(candidateAssets)
            unprocessedResources.append(contentsOf: batchResources)
        }
        
        log("Processed \(processedCount) assets, found \(unprocessedResources.count) unprocessed resources to upload")
        
        return unprocessedResources
    }
    
    /// Process a batch of candidate assets and return resources that need uploading
    private func processCandidateBatch(_ candidates: [PHAsset]) -> [PHAssetResource] {
        var resources: [PHAssetResource] = []
        
        for asset in candidates {
            // Check cancellation state
            if isCancelledLock.withLock({ $0 }) {
                break
            }
            
            // Get resources for this asset
            let assetResources = PHAssetResource.assetResources(for: asset)
            
            // Find primary resource to calculate hash
            guard let primaryResource = getPrimaryResource(from: assetResources) else {
                continue
            }
            
            // Check if we already have a hash for this asset
            if let cachedHash = database.getHashForAsset(assetLocalIdentifier: asset.localIdentifier) {
                // Check server with cached hash
                if checkAssetExistsOnServer(checksum: cachedHash) {
                    log("Asset \(asset.localIdentifier) already on server (cached hash check)")
                    database.recordHashCheckedAsset(assetLocalIdentifier: asset.localIdentifier, sha1Hash: cachedHash, isOnServer: true)
                    continue
                }
            } else {
                // Calculate hash for this resource
                if let hash = calculateSHA1Hash(for: primaryResource) {
                    // Save hash to database
                    database.saveAssetHash(assetLocalIdentifier: asset.localIdentifier, sha1Hash: hash)
                    
                    // Check if asset exists on server
                    if checkAssetExistsOnServer(checksum: hash) {
                        log("Asset \(asset.localIdentifier) already on server (live hash check)")
                        database.recordHashCheckedAsset(assetLocalIdentifier: asset.localIdentifier, sha1Hash: hash, isOnServer: true)
                        continue
                    }
                    
                    // Record that we checked but asset is not on server
                    database.recordHashCheckedAsset(assetLocalIdentifier: asset.localIdentifier, sha1Hash: hash, isOnServer: false)
                }
            }
            
            // Asset is not on server, add its resources for upload
            for resource in assetResources {
                if self.shouldUploadResource(resource) {
                    let resourceType = self.getResourceType(for: resource)
                    
                    // Check if this specific resource type has been uploaded
                    if !self.database.isResourceUploaded(
                        assetLocalIdentifier: asset.localIdentifier,
                        resourceType: resourceType
                    ) {
                        resources.append(resource)
                    }
                }
            }
            
            // Limit total resources to process per batch
            if resources.count >= 50 {
                break
            }
        }
        
        return resources
    }
    
    /// Get primary resource from asset resources for hash calculation
    private func getPrimaryResource(from resources: [PHAssetResource]) -> PHAssetResource? {
        // Prefer fullSizePhoto/fullSizeVideo for accurate hash
        for resource in resources {
            if resource.type == .fullSizePhoto || resource.type == .fullSizeVideo {
                return resource
            }
        }
        
        // Fallback to photo/video
        for resource in resources {
            if resource.type == .photo || resource.type == .video {
                return resource
            }
        }
        
        return resources.first
    }
    
    /// Calculate SHA1 hash for a resource (synchronous for background extension)
    private func calculateSHA1Hash(for resource: PHAssetResource) -> String? {
        var hashResult: String?
        let semaphore = DispatchSemaphore(value: 0)
        
        var context = CC_SHA1_CTX()
        CC_SHA1_Init(&context)
        
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false  // Don't download from iCloud in background
        
        var hasError = false
        
        PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
            chunk.withUnsafeBytes { buffer in
                _ = CC_SHA1_Update(&context, buffer.baseAddress, CC_LONG(chunk.count))
            }
        } completionHandler: { error in
            if error == nil {
                var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
                CC_SHA1_Final(&digest, &context)
                hashResult = digest.map { String(format: "%02x", $0) }.joined()
            } else {
                hasError = true
            }
            semaphore.signal()
        }
        
        // Wait with timeout to prevent blocking forever
        let timeout = DispatchTime.now() + .seconds(60)
        if semaphore.wait(timeout: timeout) == .timedOut {
            log("Hash calculation timed out for resource: \(resource.originalFilename)")
            return nil
        }
        
        if hasError {
            log("Hash calculation failed for resource: \(resource.originalFilename)")
            return nil
        }
        
        return hashResult
    }
    
    /// Check if asset exists on Immich server by checksum
    private func checkAssetExistsOnServer(checksum: String) -> Bool {
        let serverURL = settings.serverURL
        let apiKey = settings.apiKey
        
        guard !serverURL.isEmpty, !apiKey.isEmpty else {
            log("Server URL or API key is empty, skipping server check")
            return false
        }
        
        guard let url = URL(string: "\(serverURL)/api/search/metadata") else {
            log("Invalid server URL for asset check")
            return false
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 15
        
        let body: [String: Any] = ["checksum": checksum]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            log("Failed to serialize request body: \(error.localizedDescription)")
            return false
        }
        
        var result = false
        let semaphore = DispatchSemaphore(value: 0)
        
        let task = urlSession.dataTask(with: request) { [weak self] data, response, error in
            defer { semaphore.signal() }
            
            guard let self = self else { return }
            
            if let error = error {
                self.log("Server check error: \(error.localizedDescription)")
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data else {
                return
            }
            
            // Parse response to check if asset exists
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let assets = json["assets"] as? [String: Any],
                   let items = assets["items"] as? [[String: Any]] {
                    result = !items.isEmpty
                }
            } catch {
                self.log("Failed to parse server response: \(error.localizedDescription)")
            }
        }
        
        task.resume()
        
        // Wait with timeout
        let timeout = DispatchTime.now() + .seconds(15)
        _ = semaphore.wait(timeout: timeout)
        
        return result
    }
    
    /// Determine if the resource should be uploaded
    private func shouldUploadResource(_ resource: PHAssetResource) -> Bool {
        switch resource.type {
        case .photo, .fullSizePhoto, .video, .fullSizeVideo, .alternatePhoto:
            return true
        default:
            return false
        }
    }
    
    /// Build upload destination URLRequest
    /// Note: For PHBackgroundResourceUploadExtension, the system replaces httpBody with raw photo data
    /// We pass metadata via HTTP headers, and the proxy server will convert it to multipart/form-data
    private func buildDestination(for resource: PHAssetResource) -> URLRequest? {
        let serverURL = settings.serverURL
        let apiKey = settings.apiKey
        
        guard !serverURL.isEmpty, !apiKey.isEmpty else {
            log("Server URL or API key is empty")
            return nil
        }
        
        // Get date information from resource
        let createdAt = getCreationDate(for: resource) ?? Date()
        let modifiedAt = getModificationDate(for: resource) ?? Date()
        
        // Get MIME type
        let mimeType = getMimeType(for: resource)
        
        // Build device asset ID
        let deviceAssetId = "\(resource.assetLocalIdentifier)-\(getResourceType(for: resource))-\(resource.originalFilename)"
        
        // Build URL for proxy server's background upload endpoint
        guard let url = URL(string: "\(serverURL)/api/assets/background") else {
            log("Invalid server URL: \(serverURL)")
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let dateFormatter = ISO8601DateFormatter()
        
        // Request Headers - these will be read by the proxy server
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        
        // Pass metadata via custom headers (proxy server will read these)
        request.setValue(deviceAssetId, forHTTPHeaderField: "X-Device-Asset-Id")
        request.setValue("ios-fawenyo-yaiiu", forHTTPHeaderField: "X-Device-Id")
        request.setValue(dateFormatter.string(from: createdAt), forHTTPHeaderField: "X-File-Created-At")
        request.setValue(dateFormatter.string(from: modifiedAt), forHTTPHeaderField: "X-File-Modified-At")
        request.setValue("false", forHTTPHeaderField: "X-Is-Favorite")
        request.setValue(resource.originalFilename, forHTTPHeaderField: "X-Filename")
        request.setValue(mimeType, forHTTPHeaderField: "X-Content-Type")
        
        // Note: httpBody will be replaced by the system with raw photo data
        // The proxy server expects raw binary data in the body
        
        return request
    }
    
    /// Get resource creation date
    private func getCreationDate(for resource: PHAssetResource) -> Date? {
        // Try to get date from associated PHAsset
        let assetIdentifier = resource.assetLocalIdentifier
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
        return fetchResult.firstObject?.creationDate
    }
    
    /// Get resource modification date
    private func getModificationDate(for resource: PHAssetResource) -> Date? {
        // Try to get date from associated PHAsset
        let assetIdentifier = resource.assetLocalIdentifier
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
        return fetchResult.firstObject?.modificationDate
    }
    
    /// Get resource MIME type
    private func getMimeType(for resource: PHAssetResource) -> String {
        let uti = resource.uniformTypeIdentifier.lowercased()
        
        // Return corresponding MIME type based on UTI
        if uti.contains("jpeg") || uti.contains("jpg") {
            return "image/jpeg"
        } else if uti.contains("png") {
            return "image/png"
        } else if uti.contains("heic") || uti.contains("heif") {
            return "image/heic"
        } else if uti.contains("gif") {
            return "image/gif"
        } else if uti.contains("raw") || uti.contains("dng") {
            return "image/dng"
        } else if uti.contains("mp4") {
            return "video/mp4"
        } else if uti.contains("quicktime") || uti.contains("mov") {
            return "video/quicktime"
        } else if uti.contains("video") {
            return "video/mp4"
        } else if uti.contains("image") {
            return "image/jpeg"
        }
        
        return "application/octet-stream"
    }
    
    /// Extract Immich ID from job (if available)
    private func extractImmichIdFromJob(_ job: PHAssetResourceUploadJob) -> String? {
        // Note: Actual response handling may need adjustment based on Immich API response format
        // Assuming job provides server response somehow
        // Currently PhotoKit API may not directly provide this, need alternative approach
        return nil
    }
    
    /// Get resource type string
    private func getResourceType(for resource: PHAssetResource) -> String {
        let uti = resource.uniformTypeIdentifier.lowercased()
        
        // RAW formats
        if uti.contains("raw-image") ||
           uti.contains("dng") ||
           uti.contains("arw") ||
           uti.contains("cr2") ||
           uti.contains("cr3") ||
           uti.contains("nef") ||
           uti.contains("raf") ||
           uti.contains("orf") ||
           uti.contains("rw2") {
            return "raw"
        }
        
        if resource.type == .alternatePhoto {
            return "raw"
        }
        
        // Video formats
        if uti.contains("video") || uti.contains("movie") ||
           uti.contains("mp4") || uti.contains("quicktime") ||
           resource.type == .video || resource.type == .fullSizeVideo {
            return "video"
        }
        
        // Photo formats
        if resource.type == .photo || resource.type == .fullSizePhoto {
            if uti.contains("heic") || uti.contains("heif") {
                return "heic"
            } else if uti.contains("jpeg") || uti.contains("jpg") {
                return "jpeg"
            } else if uti.contains("png") {
                return "png"
            }
            return "jpeg"
        }
        
        return "primary"
    }
    
    /// Mark resource as processed
    private func markAsProcessed(_ assetIdentifier: String, resourceType: String) {
        database.createOrUpdateUploadJob(
            assetLocalIdentifier: assetIdentifier,
            resourceType: resourceType,
            filename: "",
            status: .uploading
        )
    }
    
    /// Log message
    private func log(_ message: String) {
        print("[BackgroundUploadExtension] \(message)")
        
        // Also write to shared log file
        logToSharedFile(message)
    }
    
    /// Write to shared log file
    private func logToSharedFile(_ message: String) {
        let appGroupIdentifier = "group.com.fawenyo.yaiiu"
        
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return
        }
        
        let logFileURL = containerURL.appendingPathComponent("background_upload.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logEntry = "[\(timestamp)] \(message)\n"
        
        if let data = logEntry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }
}
