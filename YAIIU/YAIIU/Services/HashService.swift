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

    /// Downloads both planned resources to temp files (bounded by the caller's
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
