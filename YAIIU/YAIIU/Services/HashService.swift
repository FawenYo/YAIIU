import Foundation
import Photos
import CommonCrypto
import CryptoKit

enum PhotoSyncStatus: String {
    case pending = "pending"
    case processing = "processing"
    case notUploaded = "not_uploaded"
    case uploaded = "uploaded"
    case checking = "checking"
    case error = "error"
}

/// Result containing hashes for all resources of an asset (JPEG and RAW if present)
struct MultiResourceHashResult: Sendable {
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

/// Sendable descriptor of an asset's hashing plan: which logical resources to
/// hash and how much disk they are expected to need. Selection itself happens
/// once in `AssetResourceSelector.select(for:)`; the descriptor then crosses
/// task boundaries between the download and hash stages.
struct AssetResourcePlan: Sendable {
    let localIdentifier: String
    /// RAW-only libraries hash the RAW as the primary, with no separate RAW slot.
    let isRAWOnly: Bool
    let modificationDate: Date?
    /// Sum of KVC size estimates for resources whose sizes are known.
    let estimatedBytes: Int64
    /// True when any selected resource has no usable PhotoKit size estimate.
    let hasUnknownResourceSize: Bool
}

/// Resources selected for an asset: the primary (JPEG/video) and optional RAW.
/// `PHAssetResource` is not Sendable, so this stays on the selecting thread;
/// only `plan` is handed between stages.
struct AssetResources {
    let plan: AssetResourcePlan
    /// For RAW-only assets the RAW itself is the primary.
    let primaryResource: PHAssetResource
    let rawResource: PHAssetResource?
}

enum AssetResourceSelector {
    static func select(for asset: PHAsset) -> AssetResources? {
        let resources = PHAssetResource.assetResources(for: asset)

        var primaryResource: PHAssetResource?
        var rawResource: PHAssetResource?

        for resource in resources {
            let isRAW = HashService.isRAWResource(resource)

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
            && resources.first(where: { !HashService.isRAWResource($0) }) == nil
            && rawResource != nil

        if isRAWOnly, let raw = rawResource {
            let estimate = sizeEstimate(of: [raw])
            let plan = AssetResourcePlan(
                localIdentifier: asset.localIdentifier,
                isRAWOnly: true,
                modificationDate: asset.modificationDate,
                estimatedBytes: estimate.bytes,
                hasUnknownResourceSize: estimate.hasUnknown
            )
            return AssetResources(plan: plan, primaryResource: raw, rawResource: nil)
        }

        guard let primary = primaryResource ?? resources.first(where: { !HashService.isRAWResource($0) }) else {
            return nil
        }

        let selectedResources = [primary] + (rawResource.map { [$0] } ?? [])
        let estimate = sizeEstimate(of: selectedResources)
        let plan = AssetResourcePlan(
            localIdentifier: asset.localIdentifier,
            isRAWOnly: false,
            modificationDate: asset.modificationDate,
            estimatedBytes: estimate.bytes,
            hasUnknownResourceSize: estimate.hasUnknown
        )
        return AssetResources(plan: plan, primaryResource: primary, rawResource: rawResource)
    }

    private static func sizeEstimate(of resources: [PHAssetResource]) -> (bytes: Int64, hasUnknown: Bool) {
        var bytes: Int64 = 0
        var hasUnknown = false

        for resource in resources {
            let size = (resource.value(forKey: "fileSize") as? CLong).map(Int64.init) ?? 0
            if size > 0 {
                bytes += size
            } else {
                hasUnknown = true
            }
        }
        return (bytes, hasUnknown)
    }
}

final class RequestDataHashAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var hasher = Insecure.SHA1()
    private var totalBytes = 0

    func append(_ data: Data) {
        lock.lock()
        totalBytes += data.count
        hasher.update(data: data)
        lock.unlock()
    }

    func finalize() -> (hash: String, size: Int64) {
        lock.lock()
        let digest = Data(hasher.finalize())
        let bytes = totalBytes
        lock.unlock()

        return (
            digest.map { String(format: "%02x", $0) }.joined(),
            Int64(bytes)
        )
    }
}

/// Pre-downloaded temp files for one asset's planned resources.
struct AssetTempFiles: Sendable {
    let plan: AssetResourcePlan
    let primaryFileURL: URL

    let rawFileURL: URL?

    var actualBytes: Int64 {
        ResourceFileAccess.size(of: primaryFileURL) + (rawFileURL.map { ResourceFileAccess.size(of: $0) } ?? 0)
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: primaryFileURL)
        if let rawFileURL {
            try? FileManager.default.removeItem(at: rawFileURL)
        }
    }
}

/// One prepared asset handed from the download stage to the hash consumer.
/// Its `reservedBytes` stay charged to the disk budget until `complete()`
/// deletes the temp files and releases the reservation. Completion is
/// exactly-once: whichever path reaches it first (hash, discard, run sweep)
/// wins; the rest are no-ops.
final class PreparedHashWork: @unchecked Sendable {
    let files: AssetTempFiles
    let reservedBytes: Int64
    private let budget: ResourceBudget
    private let lock = NSLock()
    private var isCompleted = false
    private var completionHandler: (@Sendable () -> Void)?

    init(files: AssetTempFiles, reservedBytes: Int64, budget: ResourceBudget) {
        self.files = files
        self.reservedBytes = reservedBytes
        self.budget = budget
    }

    func onCompletion(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if isCompleted {
            lock.unlock()
            handler()
            return
        }
        completionHandler = handler
        lock.unlock()
    }

    func complete() {
        lock.lock()
        if isCompleted {
            lock.unlock()
            return
        }
        isCompleted = true
        let handler = completionHandler
        completionHandler = nil
        lock.unlock()
        files.removeAll()
        budget.release(reservedBytes)
        handler?()
    }
}

/// Tracks works handed to the stream. A cancelled `AsyncStream` iterator with
/// an unbounded policy terminates immediately and discards buffered elements,
/// so the run sweeps this registry when it ends to guarantee every temp file
/// is deleted and every reservation released. `complete()` is exactly-once.
final class PreparedWorkRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var works: [PreparedHashWork] = []

    func record(_ work: PreparedHashWork) {
        lock.lock()
        works.append(work)
        lock.unlock()
    }

    func remove(_ work: PreparedHashWork) {
        lock.lock()
        works.removeAll { $0 === work }
        lock.unlock()
    }

    func sweep() {
        lock.lock()
        let pending = works
        works = []
        lock.unlock()
        for work in pending {
            work.complete()
        }
    }
}


/// Result of hashing the same primary/RAW resource set YAIIU uses for upload.
/// A result is only complete when the primary and, when present, RAW companion
/// have both been hashed successfully.
struct RequestDataHashItem: Sendable {
    let localIdentifier: String
    let primaryHash: String?
    let primaryFileSize: Int64
    let rawHash: String?
    let rawFileSize: Int64?
    let hasRAW: Bool
    let modificationDate: Date?
    let errorDescription: String?

    var totalFileSize: Int64 {
        primaryFileSize + (rawFileSize ?? 0)
    }

    var isComplete: Bool {
        primaryHash != nil && (!hasRAW || rawHash != nil) && errorDescription == nil
    }
}

class HashService {
    static let shared = HashService()

    private final class HashCancellationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    /// Blocking FileHandle reads must not run on Swift's cooperative executor.
    /// The outer hash gate also limits work to three assets, while this queue
    /// provides a global cap across cancellation/restart boundaries.
    private static let hashWorkerQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.yaiiu.hash-workers"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 3
        return queue
    }()

    private static let slowQueueDelayThreshold: TimeInterval = 1.0

    private static let rawIdentifiers: Set<String> = [
        "raw-image", "dng", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2"
    ]

    private init() {}

    static func isRAWResource(_ resource: PHAssetResource) -> Bool {
        if resource.type == .alternatePhoto {
            return true
        }

        let uti = resource.uniformTypeIdentifier.lowercased()
        return rawIdentifiers.contains { uti.contains($0) }
    }

    private final class RequestDataRequestRef: @unchecked Sendable {
        private let lock = NSLock()
        private var id: PHAssetResourceDataRequestID?
        private var cancelled = false

        func install(_ id: PHAssetResourceDataRequestID) {
            lock.lock()
            if cancelled {
                lock.unlock()
                PHAssetResourceManager.default().cancelDataRequest(id)
                return
            }
            self.id = id
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let requestID = id
            id = nil
            lock.unlock()

            if let requestID {
                PHAssetResourceManager.default().cancelDataRequest(requestID)
            }
        }
    }

    /// Hashes one finite batch using YAIIU's production resource selection.
    /// Both the primary resource and a RAW companion (when present) are streamed
    /// through requestData, avoiding the old writeData/temp-file RAW path.
    func hashBatchWithRequestData(
        assetIds: [String],
        allowNetworkAccess: Bool
    ) async -> [RequestDataHashItem] {
        guard !assetIds.isEmpty else { return [] }

        let nativeTask = Task.detached(
            priority: .userInitiated
        ) { [weak self] () -> [RequestDataHashItem] in
            guard let self else { return [] }
            return await self.hashBatchWithRequestDataImpl(
                assetIds: assetIds,
                allowNetworkAccess: allowNetworkAccess
            )
        }

        return await withTaskCancellationHandler {
            await nativeTask.value
        } onCancel: {
            nativeTask.cancel()
        }
    }

    private func hashBatchWithRequestDataImpl(
        assetIds: [String],
        allowNetworkAccess: Bool
    ) async -> [RequestDataHashItem] {
        var missingAssetIds = Set(assetIds)
        var assets: [PHAsset] = []
        assets.reserveCapacity(assetIds.count)

        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: assetIds,
            options: nil
        )
        fetchResult.enumerateObjects { asset, _, stop in
            if Task.isCancelled {
                stop.pointee = true
                return
            }
            missingAssetIds.remove(asset.localIdentifier)
            assets.append(asset)
        }

        guard !Task.isCancelled else { return [] }

        var items = await withTaskGroup(
            of: RequestDataHashItem?.self,
            returning: [RequestDataHashItem].self
        ) { group in
            var results: [RequestDataHashItem] = []
            results.reserveCapacity(assetIds.count)

            for asset in assets {
                if Task.isCancelled { break }
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    return await self.hashAssetWithRequestData(
                        asset,
                        allowNetworkAccess: allowNetworkAccess
                    )
                }
            }

            for await item in group {
                if let item {
                    results.append(item)
                }
            }
            return results
        }

        guard !Task.isCancelled else { return [] }

        for missing in missingAssetIds {
            items.append(
                RequestDataHashItem(
                    localIdentifier: missing,
                    primaryHash: nil,
                    primaryFileSize: 0,
                    rawHash: nil,
                    rawFileSize: nil,
                    hasRAW: false,
                    modificationDate: nil,
                    errorDescription: "Asset not found in library"
                )
            )
        }

        return items
    }

    private func hashAssetWithRequestData(
        _ asset: PHAsset,
        allowNetworkAccess: Bool
    ) async -> RequestDataHashItem? {
        guard !Task.isCancelled else { return nil }

        guard let resources = AssetResourceSelector.select(for: asset) else {
            return RequestDataHashItem(
                localIdentifier: asset.localIdentifier,
                primaryHash: nil,
                primaryFileSize: 0,
                rawHash: nil,
                rawFileSize: nil,
                hasRAW: false,
                modificationDate: asset.modificationDate,
                errorDescription: "Cannot get production asset resources"
            )
        }

        let hasRAW = !resources.plan.isRAWOnly && resources.rawResource != nil
        let primaryLabel = resources.plan.isRAWOnly ? "raw-primary" : "primary"

        let primary = await hashResourceWithRequestData(
            resources.primaryResource,
            assetIdentifier: asset.localIdentifier,
            resourceLabel: primaryLabel,
            allowNetworkAccess: allowNetworkAccess
        )

        guard !Task.isCancelled else { return nil }

        guard let primaryHash = primary.hash else {
            return RequestDataHashItem(
                localIdentifier: asset.localIdentifier,
                primaryHash: nil,
                primaryFileSize: 0,
                rawHash: nil,
                rawFileSize: nil,
                hasRAW: hasRAW,
                modificationDate: asset.modificationDate,
                errorDescription: "\(primaryLabel): \(primary.error ?? "requestData failed")"
            )
        }

        var rawHash: String?
        var rawSize: Int64?

        if hasRAW, let rawResource = resources.rawResource {
            let raw = await hashResourceWithRequestData(
                rawResource,
                assetIdentifier: asset.localIdentifier,
                resourceLabel: "raw",
                allowNetworkAccess: allowNetworkAccess
            )

            guard !Task.isCancelled else { return nil }

            guard let completedRawHash = raw.hash else {
                return RequestDataHashItem(
                    localIdentifier: asset.localIdentifier,
                    primaryHash: primaryHash,
                    primaryFileSize: primary.size,
                    rawHash: nil,
                    rawFileSize: nil,
                    hasRAW: true,
                    modificationDate: asset.modificationDate,
                    errorDescription: "raw: \(raw.error ?? "requestData failed")"
                )
            }

            rawHash = completedRawHash
            rawSize = raw.size
        }

        return RequestDataHashItem(
            localIdentifier: asset.localIdentifier,
            primaryHash: primaryHash,
            primaryFileSize: primary.size,
            rawHash: rawHash,
            rawFileSize: rawSize,
            hasRAW: hasRAW,
            modificationDate: asset.modificationDate,
            errorDescription: nil
        )
    }

    private func hashResourceWithRequestData(
        _ resource: PHAssetResource,
        assetIdentifier: String,
        resourceLabel: String,
        allowNetworkAccess: Bool
    ) async -> (hash: String?, size: Int64, error: String?) {
        let requestRef = RequestDataRequestRef()

        return await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                return (nil, 0, "Task cancelled")
            }

            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = allowNetworkAccess
            let startedAt = ProcessInfo.processInfo.systemUptime

            let result: (hash: String?, size: Int64, error: String?) =
                await withCheckedContinuation { continuation in
                    let accumulator = RequestDataHashAccumulator()

                    let requestID = PHAssetResourceManager.default().requestData(
                        for: resource,
                        options: options,
                        dataReceivedHandler: { data in
                            accumulator.append(data)
                        },
                        completionHandler: { error in
                            switch error {
                            case let photosError as PHPhotosError
                                where photosError.code == .userCancelled:
                                continuation.resume(
                                    returning: (nil, 0, "PhotoKit request cancelled")
                                )
                            case let error?:
                                continuation.resume(
                                    returning: (nil, 0, error.localizedDescription)
                                )
                            case nil:
                                let finalized = accumulator.finalize()
                                continuation.resume(
                                    returning: (finalized.hash, finalized.size, nil)
                                )
                            }
                        }
                    )
                    requestRef.install(requestID)
                }

            guard !Task.isCancelled else {
                return (nil, 0, "Task cancelled")
            }

            if let hash = result.hash {
                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                let mebibytes = Double(result.size) / (1024.0 * 1024.0)
                let throughput = elapsed > 0 ? mebibytes / elapsed : 0

                logDebug(
                    "requestData resource finished: asset=\(assetIdentifier), resource=\(resourceLabel), bytes=\(result.size), elapsed=\(String(format: "%.3f", elapsed))s, throughput=\(String(format: "%.1f", throughput))MiB/s",
                    category: .hash
                )
                return (hash, result.size, nil)
            }

            return result
        } onCancel: {
            requestRef.cancel()
        }
    }

    /// Downloads both planned resources to temp files (bounded by the caller's    /// Downloads both planned resources to temp files (bounded by the caller's
    /// byte budget). The caller owns the files and must delete them.
    func prepare(_ resources: AssetResources) async throws -> AssetTempFiles {
        let primaryFileURL = try await ResourceFileAccess.tempFile(for: resources.primaryResource)
        do {
            let rawFileURL: URL?
            if let rawResource = resources.rawResource {
                rawFileURL = try await ResourceFileAccess.tempFile(for: rawResource)
            } else {
                rawFileURL = nil
            }
            return AssetTempFiles(plan: resources.plan, primaryFileURL: primaryFileURL, rawFileURL: rawFileURL)
        } catch {
            try? FileManager.default.removeItem(at: primaryFileURL)
            throw error
        }
    }

    /// Hashes prepared temp files with a bounded read buffer and deletes them.
    /// Blocking reads run on the dedicated hash worker queue.
    func hash(_ files: AssetTempFiles) async throws -> MultiResourceHashResult {
        defer { files.removeAll() }

        let plan = files.plan
        let (primaryHash, primarySize) = try await Self.readFileHash(
            files.primaryFileURL,
            assetIdentifier: plan.localIdentifier,
            resourceLabel: plan.isRAWOnly ? "raw-primary" : "primary"
        )

        var rawHash: String?
        var rawSize: Int64?

        if !plan.isRAWOnly, let rawFileURL = files.rawFileURL {
            let (hash, size) = try await Self.readFileHash(
                rawFileURL,
                assetIdentifier: plan.localIdentifier,
                resourceLabel: "raw"
            )
            rawHash = hash
            rawSize = Int64(size)
        }

        return MultiResourceHashResult(
            localIdentifier: plan.localIdentifier,
            primaryHash: primaryHash,
            primaryFileSize: Int64(primarySize),
            rawHash: plan.isRAWOnly ? nil : rawHash,
            rawFileSize: plan.isRAWOnly ? nil : rawSize,
            hasRAW: !plan.isRAWOnly && files.rawFileURL != nil,
            calculatedAt: Date()
        )
    }

    /// Runs blocking file I/O + SHA1 on a dedicated bounded worker queue rather
    /// than Swift's cooperative executor. Cancellation is checked between file
    /// chunks so stopped runs leave the queue promptly.
    private static func readFileHash(
        _ url: URL,
        assetIdentifier: String,
        resourceLabel: String
    ) async throws -> (hash: String, size: Int) {
        let cancellation = HashCancellationToken()

        logDebug(
            "Hash resource scheduled: asset=\(assetIdentifier), resource=\(resourceLabel)",
            category: .hash
        )
        let scheduledAt = ProcessInfo.processInfo.systemUptime

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                hashWorkerQueue.addOperation {
                    let workerStartedAt = ProcessInfo.processInfo.systemUptime
                    let queueDelay = workerStartedAt - scheduledAt

                    if queueDelay >= slowQueueDelayThreshold {
                        logInfo(
                            "Hash worker delayed: asset=\(assetIdentifier), resource=\(resourceLabel), queueDelay=\(String(format: "%.3f", queueDelay))s",
                            category: .hash
                        )
                    } else {
                        logDebug(
                            "Hash worker started: asset=\(assetIdentifier), resource=\(resourceLabel), queueDelay=\(String(format: "%.3f", queueDelay))s",
                            category: .hash
                        )
                    }

                    do {
                        if cancellation.isCancelled {
                            throw CancellationError()
                        }

                        let hashStartedAt = ProcessInfo.processInfo.systemUptime
                        let result = try FileHasher.sha1Hex(
                            ofFileAt: url,
                            shouldCancel: { cancellation.isCancelled }
                        )
                        let hashElapsed = ProcessInfo.processInfo.systemUptime - hashStartedAt
                        let mebibytes = Double(result.size) / (1024.0 * 1024.0)
                        let throughput = hashElapsed > 0 ? mebibytes / hashElapsed : 0

                        logDebug(
                            "Hash resource finished: asset=\(assetIdentifier), resource=\(resourceLabel), bytes=\(result.size), queueDelay=\(String(format: "%.3f", queueDelay))s, hashElapsed=\(String(format: "%.3f", hashElapsed))s, throughput=\(String(format: "%.1f", throughput))MiB/s",
                            category: .hash
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
