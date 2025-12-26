import Foundation

class ImmichAPIService {
    static let shared = ImmichAPIService()
    
    private init() {
        logInfo("ImmichAPIService initialized", category: .api)
    }
    
    func validateConnection(serverURL: String, apiKey: String) async throws -> Bool {
        logInfo("Validating connection to server: \(serverURL)", category: .api)
        
        guard let url = URL(string: "\(serverURL)/api/users/me") else {
            logError("Invalid URL: \(serverURL)/api/users/me", category: .api)
            throw ImmichAPIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 15
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                logError("Invalid response from server", category: .api)
                throw ImmichAPIError.invalidResponse
            }
            
            if httpResponse.statusCode == 200 {
                logInfo("Connection validated successfully", category: .api)
                return true
            } else {
                logWarning("Connection validation failed with status code: \(httpResponse.statusCode)", category: .api)
                return false
            }
        } catch let error as ImmichAPIError {
            throw error
        } catch {
            logError("Connection validation failed: \(error.localizedDescription)", category: .api)
            throw error
        }
    }
    
    func uploadAsset(
        fileData: Data,
        filename: String,
        mimeType: String,
        deviceAssetId: String,
        createdAt: Date,
        modifiedAt: Date,
        serverURL: String,
        apiKey: String,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> UploadResponse {
        let fileSizeKB = Double(fileData.count) / 1024.0
        logInfo("Starting upload: \(filename) (\(String(format: "%.1f", fileSizeKB)) KB), mimeType: \(mimeType)", category: .api)
        
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
        
        var body = Data()
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"deviceAssetId\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(deviceAssetId)\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"deviceId\"\r\n\r\n".data(using: .utf8)!)
        body.append("ios-fawenyo-yaiiu\r\n".data(using: .utf8)!)
        
        let dateFormatter = ISO8601DateFormatter()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"fileCreatedAt\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(dateFormatter.string(from: createdAt))\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"fileModifiedAt\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(dateFormatter.string(from: modifiedAt))\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"isFavorite\"\r\n\r\n".data(using: .utf8)!)
        body.append("false\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"assetData\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                logError("Invalid response during upload of \(filename)", category: .api)
                throw ImmichAPIError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                logError("Upload failed for \(filename): HTTP \(httpResponse.statusCode) - \(errorMessage)", category: .api)
                throw ImmichAPIError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
            }
            
            let decoder = JSONDecoder()
            let uploadResponse = try decoder.decode(UploadResponse.self, from: data)
            
            if uploadResponse.duplicate == true {
                logInfo("Upload completed (duplicate): \(filename), immichId: \(uploadResponse.id)", category: .api)
            } else {
                logInfo("Upload completed: \(filename), immichId: \(uploadResponse.id)", category: .api)
            }
            
            return uploadResponse
        } catch let error as ImmichAPIError {
            throw error
        } catch {
            logError("Upload failed for \(filename): \(error.localizedDescription)", category: .api)
            throw error
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
