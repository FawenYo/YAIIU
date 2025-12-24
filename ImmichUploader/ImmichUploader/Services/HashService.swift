import Foundation
import Photos
import CommonCrypto

enum PhotoSyncStatus: String {
    case pending = "pending"
    case processing = "processing"
    case notUploaded = "not_uploaded"
    case uploaded = "uploaded"
    case checking = "checking"
    case error = "error"
}

struct HashResult {
    let localIdentifier: String
    let sha1Hash: String
    let fileSize: Int64
    let calculatedAt: Date
}

class StreamingSHA1 {
    private var context = CC_SHA1_CTX()
    private(set) var totalSize: Int = 0
    
    init() {
        CC_SHA1_Init(&context)
    }
    
    func update(data: Data) {
        totalSize += data.count
        data.withUnsafeBytes { buffer in
            _ = CC_SHA1_Update(&context, buffer.baseAddress, CC_LONG(data.count))
        }
    }
    
    func finalize() -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

class HashService {
    static let shared = HashService()
    
    private init() {}
    
    func calculateHash(for asset: PHAsset) async throws -> HashResult {
        let resources = PHAssetResource.assetResources(for: asset)
        
        var primaryResource: PHAssetResource?
        
        for resource in resources {
            let resourceType = resource.type
            
            if resourceType == .fullSizePhoto || resourceType == .fullSizeVideo {
                primaryResource = resource
                break
            }
            
            if resourceType == .photo || resourceType == .video {
                if primaryResource == nil {
                    primaryResource = resource
                }
            }
        }
        
        guard let resource = primaryResource ?? resources.first else {
            throw HashError.noResourceFound
        }
        
        let (hash, size) = try await calculateSHA1Streaming(for: resource)
        
        return HashResult(
            localIdentifier: asset.localIdentifier,
            sha1Hash: hash,
            fileSize: Int64(size),
            calculatedAt: Date()
        )
    }
    
    private func calculateSHA1Streaming(for resource: PHAssetResource) async throws -> (String, Int) {
        return try await withCheckedThrowingContinuation { continuation in
            let sha1 = StreamingSHA1()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            
            PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                sha1.update(data: chunk)
            } completionHandler: { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    let hash = sha1.finalize()
                    continuation.resume(returning: (hash, sha1.totalSize))
                }
            }
        }
    }
}

enum HashError: LocalizedError {
    case noResourceFound
    case calculationFailed(reason: String)
    
    var errorDescription: String? {
        switch self {
        case .noResourceFound:
            return "No available photo resource found"
        case .calculationFailed(let reason):
            return "Hash calculation failed: \(reason)"
        }
    }
}
