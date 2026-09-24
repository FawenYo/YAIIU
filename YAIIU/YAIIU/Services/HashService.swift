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
    /// A JPEG/HEIC primary has a separate RAW companion that may be hashed lazily.
    let hasRAWCompanion: Bool
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
    /// Match Immich iOS resource selection for the primary hash:
    /// 1. media resources valid for the PHAsset media type
    /// 2. the only resource when there is one
    /// 3. the resource whose private `isCurrent` flag is true
    /// 4. full-size photo/video fallback
    ///
    /// YAIIU additionally remembers a paired RAW companion for lazy RAW
    /// verification/upload, but does not hash that companion in the normal pass.
    static func select(for asset: PHAsset) -> AssetResources? {
        let allResources = PHAssetResource.assetResources(for: asset)
        let validResources = allResources.filter {
            isMediaResource($0) && isValidResourceType($0.type, mediaType: asset.mediaType)
        }

        guard !validResources.isEmpty else { return nil }

        let primary: PHAssetResource?
        if validResources.count == 1 {
            primary = validResources.first
        } else if let current = validResources.first(where: { isCurrent($0) }) {
            primary = current
        } else {
            primary = validResources.first(where: {
                isFullSizeResourceType($0.type, mediaType: asset.mediaType)
            })
        }

        guard let primary else { return nil }

        let rawResources = allResources.filter { HashService.isRAWResource($0) }
        let hasNonRAW = allResources.contains { !HashService.isRAWResource($0) }
        let primaryIsRAW = HashService.isRAWResource(primary)
        let isRAWOnly = primaryIsRAW && !hasNonRAW
        let rawCompanion = rawResources.first(where: { $0 !== primary })
            ?? (primaryIsRAW ? nil : rawResources.first)

        let estimate = sizeEstimate(of: [primary])
        let plan = AssetResourcePlan(
            localIdentifier: asset.localIdentifier,
            isRAWOnly: isRAWOnly,
            hasRAWCompanion: !isRAWOnly && rawCompanion != nil,
            modificationDate: asset.modificationDate,
            estimatedBytes: estimate.bytes,
            hasUnknownResourceSize: estimate.hasUnknown
        )

        logDebug(
            "Immich-style resource selected: asset=\(asset.localIdentifier), mediaType=\(asset.mediaType.rawValue), type=\(primary.type.rawValue), isCurrent=\(isCurrent(primary)), isRAW=\(primaryIsRAW), hasRAWCompanion=\(plan.hasRAWCompanion), estimatedBytes=\(estimate.bytes)",
            category: .hash
        )

        return AssetResources(
            plan: plan,
            primaryResource: primary,
            rawResource: rawCompanion
        )
    }

    private static func isCurrent(_ resource: PHAssetResource) -> Bool {
        resource.value(forKey: "isCurrent") as? Bool ?? false
    }

    private static func isMediaResource(_ resource: PHAssetResource) -> Bool {
        var isMedia = resource.type != .adjustmentData
        if #available(iOS 17, *) {
            isMedia = isMedia && resource.type != .photoProxy
        }
        return isMedia
    }

    private static func isValidResourceType(
        _ type: PHAssetResourceType,
        mediaType: PHAssetMediaType
    ) -> Bool {
        switch mediaType {
        case .image:
            return [.photo, .alternatePhoto, .fullSizePhoto].contains(type)
        case .video:
            return [.video, .fullSizeVideo, .fullSizePairedVideo].contains(type)
        default:
            return false
        }
    }

    private static func isFullSizeResourceType(
        _ type: PHAssetResourceType,
        mediaType: PHAssetMediaType
    ) -> Bool {
        switch mediaType {
        case .image:
            return type == .fullSizePhoto
        case .video:
            return type == .fullSizeVideo
        default:
            return false
        }
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


struct PrimaryHashBatchItem: Sendable {
    let localIdentifier: String
    let result: MultiResourceHashResult?
    let modificationDate: Date?
    let errorDescription: String?
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

    /// Mirrors Immich's iOS native hashing call: fetch the supplied asset IDs
    /// once, add every PHAsset in this finite call to one TaskGroup, await all
    /// requestData hashes, then return. HashManager invokes this with 32 IDs and
    /// does not create the next call until this method has fully returned.
    func hashPrimaryBatch(
        assetIds: [String],
        allowNetworkAccess: Bool,
        requestDataEnabled: Bool = true
    ) async -> [PrimaryHashBatchItem] {
        guard !assetIds.isEmpty else { return [] }

        // Immich creates a fresh unstructured native hash Task for every Pigeon
        // hashAssets call. YAIIU's caller is one long-lived pipeline Task, so
        // explicitly create and retire a separate task per 32-asset call rather
        // than only creating a new TaskGroup inside that long-lived task.
        let nativeTask: Task<[PrimaryHashBatchItem], Never> = Task.detached(
            priority: .userInitiated
        ) { [weak self] in
            guard let self else { return [PrimaryHashBatchItem]() }
            return await self.hashPrimaryBatchImpl(
                assetIds: assetIds,
                allowNetworkAccess: allowNetworkAccess,
                requestDataEnabled: requestDataEnabled
            )
        }

        return await withTaskCancellationHandler {
            await nativeTask.value
        } onCancel: {
            nativeTask.cancel()
        }
    }

    private func hashPrimaryBatchImpl(
        assetIds: [String],
        allowNetworkAccess: Bool,
        requestDataEnabled: Bool
    ) async -> [PrimaryHashBatchItem] {
        guard !assetIds.isEmpty else { return [] }

        logDebug(
            "Immich-style native hash task started: assets=\(assetIds.count)",
            category: .hash
        )

        defer {
            logDebug(
                "Immich-style native hash task returning: assets=\(assetIds.count)",
                category: .hash
            )
        }

        var missingAssetIds = Set(assetIds)
        var assets: [PHAsset] = []
        assets.reserveCapacity(assetIds.count)

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: nil)
        fetchResult.enumerateObjects { asset, _, stop in
            if Task.isCancelled {
                stop.pointee = true
                return
            }
            missingAssetIds.remove(asset.localIdentifier)
            assets.append(asset)
        }

        if Task.isCancelled { return [] }

        let activeBytesBudget = ResourceBudget(
            limit: HashPipelinePolicy.requestDataActiveBytesLimit
        )

        return await withTaskGroup(of: PrimaryHashBatchItem?.self) { taskGroup in
            var items: [PrimaryHashBatchItem] = []
            items.reserveCapacity(assetIds.count)

            // Keep all 32 tasks in the finite batch, but gate the actual
            // requestData streams by estimated active bytes.
            for asset in assets {
                if Task.isCancelled { break }
                taskGroup.addTask { [weak self] in
                    guard let self else { return nil }
                    return await self.hashPrimaryAssetImmichStyle(
                        asset,
                        allowNetworkAccess: allowNetworkAccess,
                        requestDataEnabled: requestDataEnabled,
                        activeBytesBudget: activeBytesBudget
                    )
                }
            }

            for await item in taskGroup {
                guard let item else { continue }
                items.append(item)
            }

            for missing in missingAssetIds {
                items.append(
                    PrimaryHashBatchItem(
                        localIdentifier: missing,
                        result: nil,
                        modificationDate: nil,
                        errorDescription: "Asset not found in library"
                    )
                )
            }
            return items
        }
    }

    /// Deliberately follows Immich's `hashAsset` implementation shape:
    /// local RequestRef, local CryptoKit SHA1 state, requestData callbacks, and
    /// cancellation via cancelDataRequest. No shared wrapper/lock/hash object is
    /// retained across assets.
    private func hashPrimaryAssetImmichStyle(
        _ asset: PHAsset,
        allowNetworkAccess: Bool,
        requestDataEnabled: Bool,
        activeBytesBudget: ResourceBudget
    ) async -> PrimaryHashBatchItem? {
        final class RequestRef: @unchecked Sendable {
            var id: PHAssetResourceDataRequestID?
        }

        let requestRef = RequestRef()
        return await withTaskCancellationHandler {
            if Task.isCancelled { return nil }

            guard let resources = AssetResourceSelector.select(for: asset) else {
                return PrimaryHashBatchItem(
                    localIdentifier: asset.localIdentifier,
                    result: nil,
                    modificationDate: asset.modificationDate,
                    errorDescription: "Cannot get asset resource"
                )
            }

            if Task.isCancelled { return nil }

            let estimatedBytes = resources.plan.estimatedBytes
            let useRequestData = HashPipelinePolicy.shouldUseRequestData(
                estimatedBytes: estimatedBytes,
                hasUnknownResourceSize: resources.plan.hasUnknownResourceSize,
                requestDataEnabled: requestDataEnabled
            )
            let charge = useRequestData
                ? max(estimatedBytes, 1)
                : HashPipelinePolicy.requestDataActiveBytesLimit

            // A safe-path resource acquires the entire budget, so it waits for
            // all active requestData streams to drain and runs exclusively.
            guard await activeBytesBudget.acquire(charge) else { return nil }
            defer { activeBytesBudget.release(charge) }

            if !useRequestData {
                logInfo(
                    "Primary hash using safe temp-file path: asset=\(asset.localIdentifier), estimatedBytes=\(estimatedBytes), unknownSize=\(resources.plan.hasUnknownResourceSize), requestDataEnabled=\(requestDataEnabled)",
                    category: .hash
                )

                do {
                    let files = try await prepare(resources)
                    let result = try await hash(files)
                    return PrimaryHashBatchItem(
                        localIdentifier: asset.localIdentifier,
                        result: result,
                        modificationDate: resources.plan.modificationDate,
                        errorDescription: nil
                    )
                } catch {
                    return PrimaryHashBatchItem(
                        localIdentifier: asset.localIdentifier,
                        result: nil,
                        modificationDate: resources.plan.modificationDate,
                        errorDescription: error.localizedDescription
                    )
                }
            }

            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = allowNetworkAccess
            let startedAt = ProcessInfo.processInfo.systemUptime

            return await withCheckedContinuation { continuation in
                var hasher = Insecure.SHA1()
                var totalBytes = 0

                requestRef.id = PHAssetResourceManager.default().requestData(
                    for: resources.primaryResource,
                    options: options,
                    dataReceivedHandler: { data in
                        totalBytes += data.count
                        hasher.update(data: data)
                    },
                    completionHandler: { error in
                        let item: PrimaryHashBatchItem?
                        switch error {
                        case let photosError as PHPhotosError where photosError.code == .userCancelled:
                            item = nil
                        case let error?:
                            item = PrimaryHashBatchItem(
                                localIdentifier: asset.localIdentifier,
                                result: nil,
                                modificationDate: resources.plan.modificationDate,
                                errorDescription: error.localizedDescription
                            )
                        case nil:
                            let digest = Data(hasher.finalize())
                            let hash = digest.map { String(format: "%02x", $0) }.joined()
                            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                            let mebibytes = Double(totalBytes) / (1024.0 * 1024.0)
                            let throughput = elapsed > 0 ? mebibytes / elapsed : 0

                            logDebug(
                                "Immich-style hash finished: asset=\(asset.localIdentifier), bytes=\(totalBytes), elapsed=\(String(format: "%.3f", elapsed))s, throughput=\(String(format: "%.1f", throughput))MiB/s",
                                category: .hash
                            )

                            item = PrimaryHashBatchItem(
                                localIdentifier: asset.localIdentifier,
                                result: MultiResourceHashResult(
                                    localIdentifier: asset.localIdentifier,
                                    primaryHash: hash,
                                    primaryFileSize: Int64(totalBytes),
                                    rawHash: nil,
                                    rawFileSize: nil,
                                    hasRAW: resources.plan.hasRAWCompanion,
                                    calculatedAt: Date()
                                ),
                                modificationDate: resources.plan.modificationDate,
                                errorDescription: nil
                            )
                        }
                        continuation.resume(returning: item)
                    }
                )
            }
        } onCancel: {
            guard let requestId = requestRef.id else { return }
            PHAssetResourceManager.default().cancelDataRequest(requestId)
        }
    }

    /// Downloads only the primary resource for the normal hash pass. RAW
    /// companions are intentionally deferred and are materialized only by the
    /// lazy fallback path when server state cannot otherwise be resolved.
    func prepare(_ resources: AssetResources) async throws -> AssetTempFiles {
        let primaryFileURL = try await ResourceFileAccess.tempFile(for: resources.primaryResource)
        return AssetTempFiles(plan: resources.plan, primaryFileURL: primaryFileURL, rawFileURL: nil)
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

        return MultiResourceHashResult(
            localIdentifier: plan.localIdentifier,
            primaryHash: primaryHash,
            primaryFileSize: Int64(primarySize),
            rawHash: nil,
            rawFileSize: nil,
            hasRAW: plan.hasRAWCompanion,
            calculatedAt: Date()
        )
    }

    /// Materializes and hashes a RAW companion only on the lazy fallback path.
    /// The caller decides whether RAW hashing is necessary after primary/server
    /// checks have already run.
    func hashRawResource(
        _ resource: PHAssetResource,
        assetIdentifier: String
    ) async throws -> (hash: String, size: Int64) {
        let fileURL = try await ResourceFileAccess.tempFile(for: resource)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let result = try await Self.readFileHash(
            fileURL,
            assetIdentifier: assetIdentifier,
            resourceLabel: "raw-lazy"
        )
        return (result.hash, Int64(result.size))
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
