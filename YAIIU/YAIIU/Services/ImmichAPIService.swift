import Foundation
import Photos
import UIKit

// MARK: - Mobile App Metadata

/// Metadata structure for iOS mobile app uploads.
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
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        // Upload-only session has no use for response caching on disk
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        uploadSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        logInfo("ImmichAPIService initialized with upload session", category: .api)
    }
    
    func uploadAsset(
        fileData: Data,
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
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> UploadResponse {
        let fileSizeMB = Double(fileData.count) / 1024.0 / 1024.0
        let cloudIdInfo = iCloudId != nil ? ", iCloudId: \(iCloudId!.prefix(20))..." : ""
        logInfo("Starting upload: \(filename) (\(String(format: "%.2f", fileSizeMB)) MB), mimeType: \(mimeType), favorite: \(isFavorite)\(cloudIdInfo)", category: .api)
        
        guard let url = URL(string: "\(serverURL)/api/assets") else {
            logError("Invalid upload URL: \(serverURL)/api/assets", category: .api)
            throw ImmichAPIError.invalidURL
        }
        
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        let body = buildMultipartBody(
            boundary: boundary,
            fileData: fileData,
            filename: filename,
            mimeType: mimeType,
            deviceAssetId: deviceAssetId,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            isFavorite: isFavorite,
            timezone: timezone,
            iCloudId: iCloudId,
            latitude: latitude,
            longitude: longitude
        )
        
        return try await withCheckedThrowingContinuation { continuation in
            let taskDelegate = UploadTaskDelegate(
                filename: filename,
                progressHandler: progressHandler,
                completion: { result in
                    switch result {
                    case .success(let response):
                        continuation.resume(returning: response)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            )
            
            let task = uploadSession.uploadTask(with: request, from: body)
            let taskId = task.taskIdentifier
            
            delegateQueue.async(flags: .barrier) {
                self.uploadDelegates[taskId] = taskDelegate
            }
            
            task.resume()
        }
    }
    
    func uploadAssetNonBlocking(
        fileData: Data,
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
        responseHandler: ((Result<UploadResponse, Error>) -> Void)? = nil
    ) async throws {
        let fileSizeMB = Double(fileData.count) / 1024.0 / 1024.0
        let cloudIdInfo = iCloudId != nil ? ", iCloudId: \(iCloudId!.prefix(20))..." : ""
        logInfo("Starting non-blocking upload: \(filename) (\(String(format: "%.2f", fileSizeMB)) MB), mimeType: \(mimeType), favorite: \(isFavorite)\(cloudIdInfo)", category: .api)

        guard let url = URL(string: "\(serverURL)/api/assets") else {
            logError("Invalid upload URL: \(serverURL)/api/assets", category: .api)
            throw ImmichAPIError.invalidURL
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let body = buildMultipartBody(
            boundary: boundary,
            fileData: fileData,
            filename: filename,
            mimeType: mimeType,
            deviceAssetId: deviceAssetId,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            isFavorite: isFavorite,
            timezone: timezone,
            iCloudId: iCloudId,
            latitude: latitude,
            longitude: longitude
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false

            let taskDelegate = UploadTaskDelegate(
                filename: filename,
                progressHandler: progressHandler,
                completion: { result in
                    switch result {
                    case .success:
                        // If upload succeeded but onBytesSent wasn't called (shouldn't happen),
                        // resume here as a safety fallback
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
                    responseHandler?(result)
                }
            )

            taskDelegate.onBytesSent = {
                if !resumed {
                    resumed = true
                    continuation.resume()
                } else {
                    // This should never happen - log for debugging
                    logWarning("onBytesSent called but continuation already resumed for \(filename)", category: .api)
                }
            }

            let task = uploadSession.uploadTask(with: request, from: body)
            let taskId = task.taskIdentifier

            delegateQueue.sync(flags: .barrier) {
                self.uploadDelegates[taskId] = taskDelegate
            }
    
            task.resume()
        }
    }

    func uploadAssetFromFileNonBlocking(
        fileURL: URL,
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
        responseHandler: ((Result<UploadResponse, Error>) -> Void)? = nil
    ) async throws {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        let fileSizeMB = Double(fileSize) / 1024.0 / 1024.0
        let cloudIdInfo = iCloudId != nil ? ", iCloudId: \(iCloudId!.prefix(20))..." : ""
        logInfo("Starting non-blocking file upload: \(filename) (\(String(format: "%.2f", fileSizeMB)) MB)\(cloudIdInfo)", category: .api)

        guard let url = URL(string: "\(serverURL)/api/assets") else {
            logError("Invalid upload URL: \(serverURL)/api/assets", category: .api)
            throw ImmichAPIError.invalidURL
        }

        let boundary = UUID().uuidString

        let multipartFileURL = try buildMultipartFile(
            boundary: boundary,
            sourceFileURL: fileURL,
            filename: filename,
            mimeType: mimeType,
            deviceAssetId: deviceAssetId,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            isFavorite: isFavorite,
            timezone: timezone,
            iCloudId: iCloudId,
            latitude: latitude,
            longitude: longitude
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false

            let taskDelegate = UploadTaskDelegate(
                filename: filename,
                progressHandler: progressHandler,
                completion: { result in
                    // Clean up the temporary multipart file after the upload task is complete
                    defer {
                        try? FileManager.default.removeItem(at: multipartFileURL)
                    }

                    switch result {
                    case .success:
                        // If upload succeeded but onBytesSent wasn't called (shouldn't happen),
                        // resume here as a safety fallback
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
                    responseHandler?(result)
                }
            )

            taskDelegate.onBytesSent = {
                if !resumed {
                    resumed = true
                    continuation.resume()
                } else {
                    // This should never happen - log for debugging
                    logWarning("onBytesSent called but continuation already resumed for \(filename)", category: .api)
                }
            }

            let task = uploadSession.uploadTask(with: request, fromFile: multipartFileURL)
            let taskId = task.taskIdentifier

            delegateQueue.sync(flags: .barrier) {
                self.uploadDelegates[taskId] = taskDelegate
            }
    
            task.resume()
        }
    }

    /// Uploads an asset from a file URL using streaming to avoid memory pressure.
    func uploadAssetFromFile(
        fileURL: URL,
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
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> UploadResponse {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        let fileSizeMB = Double(fileSize) / 1024.0 / 1024.0
        let cloudIdInfo = iCloudId != nil ? ", iCloudId: \(iCloudId!.prefix(20))..." : ""
        logInfo("Starting file-based upload: \(filename) (\(String(format: "%.2f", fileSizeMB)) MB)\(cloudIdInfo)", category: .api)
        
        guard let url = URL(string: "\(serverURL)/api/assets") else {
            logError("Invalid upload URL: \(serverURL)/api/assets", category: .api)
            throw ImmichAPIError.invalidURL
        }
        
        let boundary = UUID().uuidString
        
        // Build multipart body file on disk to avoid memory issues
        let multipartFileURL = try buildMultipartFile(
            boundary: boundary,
            sourceFileURL: fileURL,
            filename: filename,
            mimeType: mimeType,
            deviceAssetId: deviceAssetId,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            isFavorite: isFavorite,
            timezone: timezone,
            iCloudId: iCloudId,
            latitude: latitude,
            longitude: longitude
        )
        
        defer {
            try? FileManager.default.removeItem(at: multipartFileURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        return try await withCheckedThrowingContinuation { continuation in
            let taskDelegate = UploadTaskDelegate(
                filename: filename,
                progressHandler: progressHandler,
                completion: { result in
                    switch result {
                    case .success(let response):
                        continuation.resume(returning: response)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            )
            
            let task = uploadSession.uploadTask(with: request, fromFile: multipartFileURL)
            let taskId = task.taskIdentifier
            
            delegateQueue.async(flags: .barrier) {
                self.uploadDelegates[taskId] = taskDelegate
            }
            
            task.resume()
        }
    }
    
    /// Builds a multipart form file on disk for streaming upload.
    private func buildMultipartFile(
        boundary: String,
        sourceFileURL: URL,
        filename: String,
        mimeType: String,
        deviceAssetId: String,
        createdAt: Date,
        modifiedAt: Date,
        isFavorite: Bool,
        timezone: TimeZone?,
        iCloudId: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let multipartURL = tempDir.appendingPathComponent(UUID().uuidString + "_multipart.tmp")
        
        FileManager.default.createFile(atPath: multipartURL.path, contents: nil)
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: multipartURL)
        } catch {
            logError("Failed to create multipart file handle: \(error.localizedDescription)", category: .api)
            try? FileManager.default.removeItem(at: multipartURL)
            throw error
        }
        
        defer {
            try? handle.close()
        }
        
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        dateFormatter.timeZone = timezone ?? TimeZone.current
        
        // Write form fields
        struct MultipartEncodingError: Error {}

        func writeField(name: String, value: String) throws {
            let fieldData = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
            guard let data = fieldData.data(using: .utf8) else {
                throw MultipartEncodingError()
            }
            try handle.write(contentsOf: data)
        }
        
        try writeField(name: "deviceAssetId", value: deviceAssetId)
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "ios-fawenyo-yaiiu"
        try writeField(name: "deviceId", value: deviceId)
        try writeField(name: "fileCreatedAt", value: dateFormatter.string(from: createdAt))
        try writeField(name: "fileModifiedAt", value: dateFormatter.string(from: modifiedAt))
        try writeField(name: "isFavorite", value: String(isFavorite))
        
        // Include mobile-app metadata with iCloudId if available
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
                try writeField(name: "metadata", value: metadataString)
            }
        }
        
        // Write file header
        let sanitizedFilename = filename.replacingOccurrences(of: "\"", with: "_")
        let fileHeader = "--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(sanitizedFilename)\"\r\nContent-Type: \(mimeType)\r\n\r\n"
        if let headerData = fileHeader.data(using: .utf8) {
            try handle.write(contentsOf: headerData)
        }
        
        // Stream source file content in chunks to avoid loading entire file into memory
        let sourceHandle = try FileHandle(forReadingFrom: sourceFileURL)
        defer {
            try? sourceHandle.close()
        }
        
        let chunkSize = 1024 * 1024 // 1MB chunks
        while true {
            let chunk = sourceHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            try handle.write(contentsOf: chunk)
        }
        
        // Write closing boundary
        let footer = "\r\n--\(boundary)--\r\n"
        if let footerData = footer.data(using: .utf8) {
            try handle.write(contentsOf: footerData)
        }
        
        return multipartURL
    }
    
    private func buildMultipartBody(
        boundary: String,
        fileData: Data,
        filename: String,
        mimeType: String,
        deviceAssetId: String,
        createdAt: Date,
        modifiedAt: Date,
        isFavorite: Bool,
        timezone: TimeZone?,
        iCloudId: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) -> Data {
        var body = Data()
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        dateFormatter.timeZone = timezone ?? TimeZone.current
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"deviceAssetId\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(deviceAssetId)\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"deviceId\"\r\n\r\n".data(using: .utf8)!)
        body.append("ios-fawenyo-yaiiu\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"fileCreatedAt\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(dateFormatter.string(from: createdAt))\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"fileModifiedAt\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(dateFormatter.string(from: modifiedAt))\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"isFavorite\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(isFavorite)\r\n".data(using: .utf8)!)
        
        // Include mobile-app metadata with iCloudId if available
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
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"metadata\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(metadataString)\r\n".data(using: .utf8)!)
            }
        }
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"assetData\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
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
    
    /// Fetches partners who share their library with the current user.
    /// Used for delta sync which requires userIds to include all partner IDs.
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
    
    /// Updates the favorite status of multiple assets on the server.
    /// Uses PUT /api/assets endpoint with ids and isFavorite parameters.
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
    
    /// Updates metadata for multiple assets in bulk using the /api/assets/metadata endpoint.
    /// Used for syncing iCloud IDs to already uploaded assets.
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

/// Represents a single metadata update item for bulk API calls.
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
