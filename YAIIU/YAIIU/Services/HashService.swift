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

/// Result containing hashes for all resources of an asset (JPEG and RAW if present)
struct MultiResourceHashResult {
    let localIdentifier: String
    let primaryHash: String
    let primaryFileSize: Int64
    let rawHash: String?
    let rawFileSize: Int64?
    let hasRAW: Bool
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

private final class CancellableRequestState<RequestID, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var requestID: RequestID?
    private var cancelRequest: ((RequestID) -> Void)?
    private var isCancelled = false
    private var isCompleted = false

    func installContinuation(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func installRequest(_ requestID: RequestID, cancel: @escaping (RequestID) -> Void) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        self.requestID = requestID
        cancelRequest = cancel
        let shouldCancel = isCancelled
        lock.unlock()

        if shouldCancel {
            cancel(requestID)
        }
    }

    func cancel() {
        lock.lock()
        guard !isCompleted, !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let requestID = self.requestID
        let cancelRequest = self.cancelRequest
        lock.unlock()

        if let requestID, let cancelRequest {
            cancelRequest(requestID)
        }
    }

    func complete(_ result: Result<Value, Error>) {
        lock.lock()
        guard !isCompleted, let continuation else {
            lock.unlock()
            return
        }
        isCompleted = true
        self.continuation = nil
        requestID = nil
        cancelRequest = nil
        let isCancelled = self.isCancelled
        lock.unlock()

        if isCancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            continuation.resume(with: result)
        }
    }
}

func withCancellableRequest<RequestID, Value>(
    start: (@escaping (Result<Value, Error>) -> Void) -> RequestID,
    cancel: @escaping (RequestID) -> Void
) async throws -> Value {
    let state = CancellableRequestState<RequestID, Value>()

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            state.installContinuation(continuation)
            let requestID = start { result in
                state.complete(result)
            }
            state.installRequest(requestID, cancel: cancel)
        }
    } onCancel: {
        state.cancel()
    }
}

class HashService {
    static let shared = HashService()
    
    private static let rawIdentifiers: Set<String> = [
        "raw-image", "dng", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2"
    ]
    
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
    
    /// Calculate hashes for both primary (JPEG/HEIC) and RAW resources if present.
    /// For JPEG+RAW assets, both hashes need to be verified against server.
    func calculateMultiResourceHash(for asset: PHAsset) async throws -> MultiResourceHashResult {
        let resources = PHAssetResource.assetResources(for: asset)
        
        var primaryResource: PHAssetResource?
        var rawResource: PHAssetResource?
        
        for resource in resources {
            let isRAW = Self.isRAWResource(resource)
            
            if isRAW {
                if rawResource == nil || resource.type == .alternatePhoto {
                    rawResource = resource
                }
            } else {
                let resourceType = resource.type
                if resourceType == .fullSizePhoto || resourceType == .fullSizeVideo {
                    primaryResource = resource
                } else if resourceType == .photo || resourceType == .video {
                    if primaryResource == nil {
                        primaryResource = resource
                    }
                }
            }
        }
        
        let isRAWOnly = primaryResource == nil
            && resources.first(where: { !Self.isRAWResource($0) }) == nil
            && rawResource != nil

        if isRAWOnly, let raw = rawResource {
            let (hash, size) = try await calculateSHA1Streaming(for: raw)
            return MultiResourceHashResult(
                localIdentifier: asset.localIdentifier,
                primaryHash: hash,
                primaryFileSize: Int64(size),
                rawHash: nil,
                rawFileSize: nil,
                hasRAW: false,
                calculatedAt: Date()
            )
        }

        guard let primary = primaryResource ?? resources.first(where: { !Self.isRAWResource($0) }) else {
            throw HashError.noResourceFound
        }
        
        let (primaryHash, primarySize) = try await calculateSHA1Streaming(for: primary)
        
        var rawHash: String?
        var rawSize: Int64?
        
        if let raw = rawResource {
            let (hash, size) = try await calculateSHA1Streaming(for: raw)
            rawHash = hash
            rawSize = Int64(size)
        }
        
        return MultiResourceHashResult(
            localIdentifier: asset.localIdentifier,
            primaryHash: primaryHash,
            primaryFileSize: Int64(primarySize),
            rawHash: rawHash,
            rawFileSize: rawSize,
            hasRAW: rawResource != nil,
            calculatedAt: Date()
        )
    }
    
    /// Check if the given resource is a RAW format
    private static func isRAWResource(_ resource: PHAssetResource) -> Bool {
        if resource.type == .alternatePhoto {
            return true
        }
        
        let uti = resource.uniformTypeIdentifier.lowercased()
        return rawIdentifiers.contains { uti.contains($0) }
    }
    
    private func calculateSHA1Streaming(for resource: PHAssetResource) async throws -> (String, Int) {
        let manager = PHAssetResourceManager.default()
        let sha1 = StreamingSHA1()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let requestStartedAt = Date()
        logInfo(
            "Resource data request started: type=\(String(describing: resource.type)), networkAllowed=true",
            category: .hash
        )

        return try await withCancellableRequest { completion in
            manager.requestData(for: resource, options: options) { chunk in
                sha1.update(data: chunk)
            } completionHandler: { error in
                if let error {
                    logError(
                        "Resource data request failed: type=\(String(describing: resource.type)), elapsed=\(String(format: "%.2f", Date().timeIntervalSince(requestStartedAt)))s, error=\(error.localizedDescription)",
                        category: .hash
                    )
                    completion(.failure(error))
                } else {
                    let hash = sha1.finalize()
                    logInfo(
                        "Resource data request finished: type=\(String(describing: resource.type)), bytes=\(sha1.totalSize), elapsed=\(String(format: "%.2f", Date().timeIntervalSince(requestStartedAt)))s",
                        category: .hash
                    )
                    completion(.success((hash, sha1.totalSize)))
                }
            }
        } cancel: { requestID in
            manager.cancelDataRequest(requestID)
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
