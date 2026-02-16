import Foundation
import Photos
import UIKit

// MARK: - Mobile App Metadata

struct MobileAppMetadata: Encodable {
    let iCloudId: String?
    let createdAt: String?
    let adjustmentTime: String?
    let latitude: String?
    let longitude: String?
    
    init(iCloudId: String?, createdAt: Date?, adjustmentTime: Date? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.iCloudId = iCloudId
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        self.createdAt = createdAt.map { formatter.string(from: $0) }
        self.adjustmentTime = adjustmentTime.map { formatter.string(from: $0) }
        self.latitude = latitude.map { String($0) }
        self.longitude = longitude.map { String($0) }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let iCloudId = iCloudId { try container.encode(iCloudId, forKey: .iCloudId) }
        if let createdAt = createdAt { try container.encode(createdAt, forKey: .createdAt) }
        if let adjustmentTime = adjustmentTime { try container.encode(adjustmentTime, forKey: .adjustmentTime) }
        if let latitude = latitude { try container.encode(latitude, forKey: .latitude) }
        if let longitude = longitude { try container.encode(longitude, forKey: .longitude) }
    }
    
    private enum CodingKeys: String, CodingKey {
        case iCloudId, createdAt, adjustmentTime, latitude, longitude
    }
}

struct RemoteAssetMetadataItem: Encodable {
    let key: String
    let value: MobileAppMetadata
    
    static let mobileAppKey = "yaiiu-app"
}

class ImmichAPIService: NSObject {
    static let shared = ImmichAPIService()
    
    private var uploadSession: URLSession!
    private var uploadDelegates: [Int: UploadTaskDelegate] = [:]
    private let delegateQueue = DispatchQueue(label: "com.yaiiu.upload.delegate", attributes: .concurrent)
    
    override private init() {
        super.init()
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 1800  // 30 minutes
        config.timeoutIntervalForResource = 7200  // 2 hours total per upload
        // Upload-only session has no use for response caching on disk
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        uploadSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        logInfo("ImmichAPIService initialized with upload session", category: .api)
    }
    
    func uploadResourceNonBlocking(
        resource: PHAssetResource,
        filename: String,
        mimeType: String,
        deviceAssetId: String,
        createdAt: Date,
        modifiedAt: Date,
        isFavorite: Bool,
        serverURL: String,
        apiKey: String,
        timezone: TimeZone? = nil,
        iCloudId: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        progressHandler: ((Double) -> Void)? = nil,
        responseHandler: ((Result<UploadResponse, Error>, Int64) -> Void)? = nil
    ) async throws -> Int64 {
        guard let url = URL(string: "\(serverURL)/api/assets") else {
            logError("Invalid upload URL: \(serverURL)/api/assets", category: .api)
            throw ImmichAPIError.invalidURL
        }

        let boundary = UUID().uuidString

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        dateFormatter.timeZone = timezone ?? TimeZone.current

        let preambleData = Self.buildMultipartPreamble(
            boundary: boundary,
            filename: filename,
            mimeType: mimeType,
            deviceAssetId: deviceAssetId,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            isFavorite: isFavorite,
            dateFormatter: dateFormatter,
            iCloudId: iCloudId,
            latitude: latitude,
            longitude: longitude
        )
        let epilogueData = "\r\n--\(boundary)--\r\n".data(using: .utf8)!

        let assetFileSize: Int64 = (resource.value(forKey: "fileSize") as? CLong).map(Int64.init) ?? 0
        let totalContentLength = Int64(preambleData.count) + assetFileSize + Int64(epilogueData.count)

        let fileSizeMB = Double(assetFileSize) / 1024.0 / 1024.0
        let cloudIdInfo = iCloudId != nil ? ", iCloudId: \(iCloudId!.prefix(20))..." : ""
        logInfo("Starting streaming upload: \(filename) (\(String(format: "%.2f", fileSizeMB)) MB)\(cloudIdInfo)", category: .api)

        let streamBufferSize = 16 * 1024 * 1024
        var readStream: InputStream?
        var writeStream: OutputStream?
        Stream.getBoundStreams(withBufferSize: streamBufferSize, inputStream: &readStream, outputStream: &writeStream)

        guard let inputStream = readStream, let outputStream = writeStream else {
            throw ImmichAPIError.uploadFailed(reason: "Failed to create bound streams for \(filename)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if assetFileSize > 0 {
            request.setValue(String(totalContentLength), forHTTPHeaderField: "Content-Length")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false

            let taskDelegate = UploadTaskDelegate(
                filename: filename,
                progressHandler: progressHandler,
                completion: { result in
                    switch result {
                    case .success:
                        if !resumed {
                            resumed = true
                            continuation.resume()
                            logWarning("Upload succeeded but onBytesSent was not called for \(filename)", category: .api)
                        }
                    case .failure(let error):
                        if !resumed {
                            resumed = true
                            continuation.resume(throwing: error)
                        }
                    }
                    responseHandler?(result, assetFileSize)
                }
            )

            taskDelegate.onBytesSent = {
                if !resumed {
                    resumed = true
                    continuation.resume()
                } else {
                    logWarning("onBytesSent called but continuation already resumed for \(filename)", category: .api)
                }
            }

            let task = uploadSession.uploadTask(withStreamedRequest: request)
            let taskId = task.taskIdentifier

            taskDelegate.bodyStream = inputStream

            delegateQueue.sync(flags: .barrier) {
                self.uploadDelegates[taskId] = taskDelegate
            }

            task.resume()

            self.pumpAssetData(
                resource: resource,
                preamble: preambleData,
                epilogue: epilogueData,
                into: outputStream,
                filename: filename
            )
        }

        return assetFileSize
    }

    private func pumpAssetData(
        resource: PHAssetResource,
        preamble: Data,
        epilogue: Data,
        into outputStream: OutputStream,
        filename: String
    ) {
        let pumpQueue = DispatchQueue(label: "com.yaiiu.upload.pump.\(filename)", qos: .userInitiated)
        pumpQueue.async {
            outputStream.open()

            func writeAll(_ data: Data) -> Bool {
                var offset = 0
                while offset < data.count {
                    let written = data.withUnsafeBytes { rawBuffer -> Int in
                        guard let base = rawBuffer.baseAddress else { return -1 }
                        let ptr = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                        return outputStream.write(ptr, maxLength: data.count - offset)
                    }
                    if written <= 0 {
                        logError("OutputStream write failed for \(filename): \(outputStream.streamError?.localizedDescription ?? "unknown")", category: .api)
                        return false
                    }
                    offset += written
                }
                return true
            }

            guard writeAll(preamble) else {
                outputStream.close()
                return
            }

            let chunkQueue = DispatchQueue(label: "com.yaiiu.upload.chunk.\(filename)")
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            let semaphore = DispatchSemaphore(value: 0)
            var streamError: Error?

            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options
            ) { chunk in
                chunkQueue.sync {
                    guard streamError == nil else { return }
                    if !writeAll(chunk) {
                        streamError = outputStream.streamError ?? ImmichAPIError.uploadFailed(reason: "Stream write failed")
                    }
                }
            } completionHandler: { error in
                if let error = error {
                    chunkQueue.sync {
                        streamError = error
                    }
                    logError("PHAssetResourceManager requestData failed for \(filename): \(error.localizedDescription)", category: .api)
                }
                semaphore.signal()
            }

            semaphore.wait()

            if streamError == nil {
                _ = writeAll(epilogue)
            }

            outputStream.close()
        }
    }

    private static func buildMultipartPreamble(
        boundary: String,
        filename: String,
        mimeType: String,
        deviceAssetId: String,
        createdAt: Date,
        modifiedAt: Date,
        isFavorite: Bool,
        dateFormatter: ISO8601DateFormatter,
        iCloudId: String?,
        latitude: Double?,
        longitude: Double?
    ) -> Data {
        var body = Data()

        func appendField(name: String, value: String) {
            let field = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
            body.append(field.data(using: .utf8)!)
        }

        appendField(name: "deviceAssetId", value: deviceAssetId)
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "ios-fawenyo-yaiiu"
        appendField(name: "deviceId", value: deviceId)
        appendField(name: "fileCreatedAt", value: dateFormatter.string(from: createdAt))
        appendField(name: "fileModifiedAt", value: dateFormatter.string(from: modifiedAt))
        appendField(name: "isFavorite", value: String(isFavorite))

        if let iCloudId = iCloudId {
            let metadata = MobileAppMetadata(
                iCloudId: iCloudId,
                createdAt: createdAt,
                latitude: latitude,
                longitude: longitude
            )
            let item = RemoteAssetMetadataItem(key: RemoteAssetMetadataItem.mobileAppKey, value: metadata)
            if let metadataJSON = try? JSONEncoder().encode([item]),
               let metadataString = String(data: metadataJSON, encoding: .utf8) {
                appendField(name: "metadata", value: metadataString)
            }
        }

        let sanitizedFilename = filename.replacingOccurrences(of: "\"", with: "_")
        let fileHeader = "--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(sanitizedFilename)\"\r\nContent-Type: \(mimeType)\r\n\r\n"
        body.append(fileHeader.data(using: .utf8)!)

        return body
    }

    
    func getUploadDelegate(for taskId: Int) -> UploadTaskDelegate? {
        var delegate: UploadTaskDelegate?
        delegateQueue.sync {
            delegate = uploadDelegates[taskId]
        }
        return delegate
    }
    
    func removeUploadDelegate(for taskId: Int) {
        delegateQueue.async(flags: .barrier) {
            self.uploadDelegates.removeValue(forKey: taskId)
        }
    }
    
    func checkAssetExists(checksum: String, serverURL: String, apiKey: String) async throws -> Bool {
        logDebug("Checking if asset exists with checksum: \(checksum.prefix(16))...", category: .api)
        
        guard let url = URL(string: "\(serverURL)/api/search/metadata") else {
            logError("Invalid URL for checkAssetExists", category: .api)
            throw ImmichAPIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 15
        
        let body: [String: Any] = ["checksum": checksum]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                logError("Invalid response when checking asset existence", category: .api)
                throw ImmichAPIError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                logError("Check asset failed: HTTP \(httpResponse.statusCode) - \(errorMessage)", category: .api)
                throw ImmichAPIError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
            }
            
            do {
                let searchResponse = try JSONDecoder().decode(SearchMetadataResponse.self, from: data)
                let exists = !searchResponse.assets.items.isEmpty
                logDebug("Asset check result: \(exists ? "exists" : "not found")", category: .api)
                return exists
            } catch {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let assets = json["assets"] as? [String: Any],
                       let items = assets["items"] as? [[String: Any]] {
                        let exists = !items.isEmpty
                        logDebug("Asset check result (fallback): \(exists ? "exists" : "not found")", category: .api)
                        return exists
                    }
                }
                logDebug("Asset check result: not found (parse failed)", category: .api)
                return false
            }
        } catch let error as ImmichAPIError {
            throw error
        } catch {
            logError("Check asset failed: \(error.localizedDescription)", category: .api)
            throw error
        }
    }
    
    func getCurrentUser(serverURL: String, apiKey: String) async throws -> UserInfo {
        logInfo("Fetching current user info", category: .api)
        
        guard let url = URL(string: "\(serverURL)/api/users/me") else {
            logError("Invalid URL for getCurrentUser", category: .api)
            throw ImmichAPIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 15
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                logError("Invalid response when fetching user info", category: .api)
                throw ImmichAPIError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                logError("Get user failed: HTTP \(httpResponse.statusCode) - \(errorMessage)", category: .api)
                throw ImmichAPIError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
            }
            
            let userInfo = try JSONDecoder().decode(UserInfo.self, from: data)
            logInfo("User info fetched: \(userInfo.email)", category: .api)
            return userInfo
        } catch let error as ImmichAPIError {
            throw error
        } catch {
            logError("Get user failed: \(error.localizedDescription)", category: .api)
            throw error
        }
    }
    
    func fetchFullSync(userId: String, limit: Int = 10000, lastId: String? = nil, updatedUntil: Date? = nil, serverURL: String, apiKey: String) async throws -> [ServerAsset] {
        logDebug("Fetching full sync: userId=\(userId), limit=\(limit), lastId=\(lastId ?? "nil")", category: .api)
        
        guard let url = URL(string: "\(serverURL)/api/sync/full-sync") else {
            logError("Invalid URL for full-sync", category: .api)
            throw ImmichAPIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 60
        
        var body: [String: Any] = [
            "userId": userId,
            "limit": limit
        ]
        
        if let lastId = lastId {
            body["lastId"] = lastId
        }
        
        if let updatedUntil = updatedUntil {
            let formatter = ISO8601DateFormatter()
            body["updatedUntil"] = formatter.string(from: updatedUntil)
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                logError("Invalid response during full-sync", category: .api)
                throw ImmichAPIError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                logError("Full-sync failed: HTTP \(httpResponse.statusCode) - \(errorMessage)", category: .api)
                throw ImmichAPIError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
            }
            
            let assets = try JSONDecoder().decode([ServerAsset].self, from: data)
            logDebug("Full-sync returned \(assets.count) assets", category: .api)
            return assets
        } catch let error as ImmichAPIError {
            throw error
        } catch {
            logError("Full-sync failed: \(error.localizedDescription)", category: .api)
            throw error
        }
    }
    
    func fetchDeltaSync(updatedAfter: Date, userIds: [String], serverURL: String, apiKey: String) async throws -> DeltaSyncResponse {
        logDebug("Fetching delta sync: updatedAfter=\(updatedAfter), userIds=\(userIds)", category: .api)
        
        guard let url = URL(string: "\(serverURL)/api/sync/delta-sync") else {
            logError("Invalid URL for delta-sync", category: .api)
            throw ImmichAPIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 60
        
        let formatter = ISO8601DateFormatter()
        let body: [String: Any] = [
            "updatedAfter": formatter.string(from: updatedAfter),
            "userIds": userIds
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                logError("Invalid response during delta-sync", category: .api)
                throw ImmichAPIError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                logError("Delta-sync failed: HTTP \(httpResponse.statusCode) - \(errorMessage)", category: .api)
                throw ImmichAPIError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
            }
            
            let deltaResponse = try JSONDecoder().decode(DeltaSyncResponse.self, from: data)
            logDebug("Delta-sync returned: upserted=\(deltaResponse.upserted.count), deleted=\(deltaResponse.deleted.count), needsFullSync=\(deltaResponse.needsFullSync)", category: .api)
            return deltaResponse
        } catch let error as ImmichAPIError {
            throw error
        } catch {
            logError("Delta-sync failed: \(error.localizedDescription)", category: .api)
            throw error
        }
    }
    
    func batchCheckAssets(checksums: [(String, String)], serverURL: String, apiKey: String) async throws -> [(String, Bool)] {
        logInfo("Batch checking \(checksums.count) assets", category: .api)
        var results: [(String, Bool)] = []
        var existsCount = 0
        
        for (localIdentifier, checksum) in checksums {
            do {
                let exists = try await checkAssetExists(checksum: checksum, serverURL: serverURL, apiKey: apiKey)
                results.append((localIdentifier, exists))
                if exists { existsCount += 1 }
            } catch {
                logWarning("Failed to check asset \(localIdentifier): \(error.localizedDescription)", category: .api)
                results.append((localIdentifier, false))
            }
        }
        
        logInfo("Batch check complete: \(existsCount)/\(checksums.count) assets exist on server", category: .api)
        return results
    }
    
    /// Used by delta sync — requires partner userIds.
    func fetchPartners(serverURL: String, apiKey: String) async throws -> [PartnerInfo] {
        logDebug("Fetching partners (shared-with)", category: .api)
        
        guard let url = URL(string: "\(serverURL)/api/partners?direction=shared-with") else {
            logError("Invalid URL for fetchPartners", category: .api)
            throw ImmichAPIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 15
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                logError("Invalid response when fetching partners", category: .api)
                throw ImmichAPIError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                logError("Fetch partners failed: HTTP \(httpResponse.statusCode) - \(errorMessage)", category: .api)
                throw ImmichAPIError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
            }
            
            let partners = try JSONDecoder().decode([PartnerInfo].self, from: data)
            logDebug("Fetched \(partners.count) partners", category: .api)
            return partners
        } catch let error as ImmichAPIError {
            throw error
        } catch {
            logError("Fetch partners failed: \(error.localizedDescription)", category: .api)
            throw error
        }
    }
    
    func updateAssetsFavorite(assetIds: [String], isFavorite: Bool, serverURL: String, apiKey: String) async throws {
        guard !assetIds.isEmpty else {
            logDebug("No assets to update favorite status", category: .api)
            return
        }
        
        logInfo("Updating favorite status for \(assetIds.count) assets to \(isFavorite)", category: .api)
        
        guard let url = URL(string: "\(serverURL)/api/assets") else {
            logError("Invalid URL for updateAssetsFavorite", category: .api)
            throw ImmichAPIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 30
        
        let body: [String: Any] = [
            "ids": assetIds,
            "isFavorite": isFavorite
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                logError("Invalid response when updating assets favorite", category: .api)
                throw ImmichAPIError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 || httpResponse.statusCode == 204 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                logError("Update assets favorite failed: HTTP \(httpResponse.statusCode) - \(errorMessage)", category: .api)
                throw ImmichAPIError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
            }
            
            logInfo("Successfully updated favorite status for \(assetIds.count) assets", category: .api)
        } catch let error as ImmichAPIError {
            throw error
        } catch {
            logError("Update assets favorite failed: \(error.localizedDescription)", category: .api)
            throw error
        }
    }
    
    /// Syncs iCloud IDs to already-uploaded assets in bulk.
    func updateBulkAssetMetadata(items: [MetadataUpdateItem], serverURL: String, apiKey: String) async throws {
        guard !items.isEmpty else {
            logDebug("No metadata items to update", category: .api)
            return
        }
        
        logInfo("Updating metadata for \(items.count) assets", category: .api)
        
        guard let url = URL(string: "\(serverURL)/api/assets/metadata") else {
            logError("Invalid URL for updateBulkAssetMetadata", category: .api)
            throw ImmichAPIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 60
        
        let body: [String: Any] = [
            "items": items.map { $0.toDictionary() }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                logError("Invalid response when updating bulk metadata", category: .api)
                throw ImmichAPIError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                logError("Bulk metadata update failed: HTTP \(httpResponse.statusCode) - \(errorMessage)", category: .api)
                throw ImmichAPIError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
            }
            
            logInfo("Successfully updated metadata for \(items.count) assets", category: .api)
        } catch let error as ImmichAPIError {
            throw error
        } catch {
            logError("Bulk metadata update failed: \(error.localizedDescription)", category: .api)
            throw error
        }
    }
}

struct MetadataUpdateItem {
    let assetId: String
    let key: String
    let value: MobileAppMetadata
    
    func toDictionary() -> [String: Any] {
        var valueDict: [String: Any] = [:]
        if let iCloudId = value.iCloudId { valueDict["iCloudId"] = iCloudId }
        if let createdAt = value.createdAt { valueDict["createdAt"] = createdAt }
        if let adjustmentTime = value.adjustmentTime { valueDict["adjustmentTime"] = adjustmentTime }
        if let latitude = value.latitude { valueDict["latitude"] = latitude }
        if let longitude = value.longitude { valueDict["longitude"] = longitude }
        
        return [
            "assetId": assetId,
            "key": key,
            "value": valueDict
        ]
    }
}

// MARK: - Error Types

enum ImmichAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case serverError(statusCode: Int, message: String)
    case uploadFailed(reason: String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid server response"
        case .serverError(let statusCode, let message):
            return "Server error (\(statusCode)): \(message)"
        case .uploadFailed(let reason):
            return "Upload failed: \(reason)"
        }
    }
}

// MARK: - Response Types

struct UploadResponse: Codable {
    let id: String
    let duplicate: Bool?
    
    enum CodingKeys: String, CodingKey {
        case id
        case duplicate
    }
}

struct UserInfo: Codable {
    let id: String
    let email: String
    let name: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case email
        case name
    }
}

struct ServerAsset: Codable {
    let id: String
    let checksum: String
    let originalFileName: String?
    let type: String?
    let updatedAt: String?
    let metadata: [RemoteAssetMetadata]?
    
    enum CodingKeys: String, CodingKey {
        case id
        case checksum
        case originalFileName
        case type
        case updatedAt
        case metadata
    }
    
    var iCloudId: String? {
        guard let metadata = metadata else { return nil }
        for item in metadata {
            if item.key == RemoteAssetMetadataItem.mobileAppKey {
                return item.value?.iCloudId
            }
        }
        return nil
    }
}

struct RemoteAssetMetadata: Codable {
    let key: String
    let value: RemoteAssetMetadataValue?
}

struct RemoteAssetMetadataValue: Codable {
    let iCloudId: String?
    let createdAt: String?
    let adjustmentTime: String?
    let latitude: String?
    let longitude: String?
}

struct DeltaSyncResponse: Codable {
    let upserted: [ServerAsset]
    let deleted: [String]
    let needsFullSync: Bool
    
    enum CodingKeys: String, CodingKey {
        case upserted
        case deleted
        case needsFullSync
    }
}

struct PartnerInfo: Codable {
    let id: String
    let email: String
    let name: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case email
        case name
    }
}

struct SearchMetadataResponse: Codable {
    let assets: AssetSearchResult
    
    struct AssetSearchResult: Codable {
        let items: [AssetItem]
        let total: Int?
        let count: Int?
        
        enum CodingKeys: String, CodingKey {
            case items
            case total
            case count
        }
    }
    
    struct AssetItem: Codable {
        let id: String
        let checksum: String?
        
        enum CodingKeys: String, CodingKey {
            case id
            case checksum
        }
    }
}

// MARK: - Upload Task Delegate

class UploadTaskDelegate {
    let filename: String
    let progressHandler: ((Double) -> Void)?
    let completion: (Result<UploadResponse, Error>) -> Void

    var responseData = Data()
    var onBytesSent: (() -> Void)?
    var bytesSentCallbackFired = false
    var bodyStream: InputStream?

    init(
        filename: String,
        progressHandler: ((Double) -> Void)?,
        completion: @escaping (Result<UploadResponse, Error>) -> Void
    ) {
        self.filename = filename
        self.progressHandler = progressHandler
        self.completion = completion
    }
}

// MARK: - URLSessionTaskDelegate

extension ImmichAPIService: URLSessionTaskDelegate, URLSessionDataDelegate {

    // MARK: Streamed upload body provider

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void
    ) {
        guard let delegate = getUploadDelegate(for: task.taskIdentifier) else {
            completionHandler(nil)
            return
        }
        completionHandler(delegate.bodyStream)
    }

    // MARK: Upload progress

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let delegate = getUploadDelegate(for: task.taskIdentifier) else { return }
    
        guard totalBytesExpectedToSend > 0 else { return }
    
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
    
        DispatchQueue.main.async {
            delegate.progressHandler?(progress)
        }

        if !delegate.bytesSentCallbackFired && totalBytesExpectedToSend > 0 && totalBytesSent >= totalBytesExpectedToSend {
            delegate.bytesSentCallbackFired = true
            logDebug("Upload bytes fully sent for \(delegate.filename)", category: .api)
            delegate.onBytesSent?()
        }
    }
    
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let delegate = getUploadDelegate(for: dataTask.taskIdentifier) else { return }
        delegate.responseData.append(data)
    }
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskId = task.taskIdentifier
        guard let delegate = getUploadDelegate(for: taskId) else { return }
        
        defer {
            removeUploadDelegate(for: taskId)
        }
        
        if let error = error {
            logError("Upload failed for \(delegate.filename): \(error.localizedDescription)", category: .api)
            delegate.completion(.failure(error))
            return
        }
        
        guard let httpResponse = task.response as? HTTPURLResponse else {
            logError("Invalid response during upload of \(delegate.filename)", category: .api)
            delegate.completion(.failure(ImmichAPIError.invalidResponse))
            return
        }
        
        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            let errorMessage = String(data: delegate.responseData, encoding: .utf8) ?? "Unknown error"
            logError("Upload failed for \(delegate.filename): HTTP \(httpResponse.statusCode) - \(errorMessage)", category: .api)
            delegate.completion(.failure(ImmichAPIError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)))
            return
        }
        
        do {
            let uploadResponse = try JSONDecoder().decode(UploadResponse.self, from: delegate.responseData)
            
            if uploadResponse.duplicate == true {
                logInfo("Upload completed (duplicate): \(delegate.filename), immichId: \(uploadResponse.id)", category: .api)
            } else {
                logInfo("Upload completed: \(delegate.filename), immichId: \(uploadResponse.id)", category: .api)
            }
            
            delegate.completion(.success(uploadResponse))
        } catch {
            logError("Failed to parse upload response for \(delegate.filename): \(error.localizedDescription)", category: .api)
            delegate.completion(.failure(error))
        }
    }
}
