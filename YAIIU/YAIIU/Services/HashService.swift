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

struct ImmichRequestDataSelection: @unchecked Sendable {
    let resource: PHAssetResource
    let selectedSize: Int64
    let candidateDescription: String
}

enum ImmichRequestDataResourceSelector {
    static func select(for asset: PHAsset) -> ImmichRequestDataSelection? {
        let all = PHAssetResource.assetResources(for: asset)
        let candidates = all.filter {
            isMediaResource($0)
                && isValidResourceType($0.type, mediaType: asset.mediaType)
        }

        guard !candidates.isEmpty else { return nil }

        let selected: PHAssetResource?
        if candidates.count == 1 {
            selected = candidates.first
        } else if let current = candidates.first(where: { isCurrent($0) }) {
            selected = current
        } else {
            selected = candidates.first(where: {
                isFullSizeResourceType($0.type, mediaType: asset.mediaType)
            })
        }

        guard let selected else { return nil }

        let description = candidates.map { resource in
            let bytes = fileSize(resource)
            return [
                "type=\(resource.type.rawValue)",
                "current=\(isCurrent(resource))",
                "bytes=\(bytes)",
                "uti=\(resource.uniformTypeIdentifier)",
                "name=\(resource.originalFilename)"
            ].joined(separator: ",")
        }.joined(separator: " | ")

        return ImmichRequestDataSelection(
            resource: selected,
            selectedSize: fileSize(selected),
            candidateDescription: description
        )
    }

    static func isCurrent(_ resource: PHAssetResource) -> Bool {
        resource.value(forKey: "isCurrent") as? Bool ?? false
    }

    static func fileSize(_ resource: PHAssetResource) -> Int64 {
        (resource.value(forKey: "fileSize") as? CLong)
            .map(Int64.init) ?? 0
    }

    private static func isMediaResource(_ resource: PHAssetResource) -> Bool {
        if resource.type == .adjustmentData {
            return false
        }
        if #available(iOS 17, *), resource.type == .photoProxy {
            return false
        }
        return true
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


/// Result of one asset in the requestData experiment. Primary bytes are
/// streamed directly from PhotoKit; RAW companions (when present) are hashed
/// through the existing temp-file path so database semantics remain unchanged.
struct PrimaryHashBatchItem: Sendable {
    let localIdentifier: String
    let result: MultiResourceHashResult?
    let modificationDate: Date?
    let errorDescription: String?
}

private struct RequestDataPrimaryItem: Sendable {
    let localIdentifier: String
    let primaryHash: String?
    let primaryFileSize: Int64
    let modificationDate: Date?
    let hasRAWCompanion: Bool
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

    /// Controlled primary hashing experiment: each invocation owns one finite
    /// batch (32 IDs at the caller), fetches only those assets, starts one task
    /// per asset, and fully awaits the batch before returning. Primary resource
    /// bytes never touch disk; RAW companions keep the stable temp-file path.
    func hashPrimaryBatchWithRequestData(
        assetIds: [String],
        allowNetworkAccess: Bool
    ) async -> [PrimaryHashBatchItem] {
        guard !assetIds.isEmpty else { return [] }

        let nativeTask = Task.detached(
            priority: .userInitiated
        ) { [weak self] () -> [PrimaryHashBatchItem] in
            guard let self else { return [] }
            return await self.hashPrimaryBatchWithRequestDataImpl(
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

    private func hashPrimaryBatchWithRequestDataImpl(
        assetIds: [String],
        allowNetworkAccess: Bool
    ) async -> [PrimaryHashBatchItem] {
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

        // Phase 1 is the actual experiment: all primary resources in the finite
        // batch are streamed through requestData and fully awaited.
        let primaryItems = await withTaskGroup(
            of: RequestDataPrimaryItem?.self
        ) { group in
            var items: [RequestDataPrimaryItem] = []
            items.reserveCapacity(assetIds.count)

            for asset in assets {
                if Task.isCancelled { break }
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    return await self.hashPrimaryAssetWithRequestData(
                        asset,
                        allowNetworkAccess: allowNetworkAccess
                    )
                }
            }

            for await item in group {
                if let item {
                    items.append(item)
                }
            }
            return items
        }

        guard !Task.isCancelled else { return [] }

        // Phase 2 preserves current-main RAW semantics only after every primary
        // requestData stream in this batch has stopped. RAW uses the stable
        // temp-file hasher and is deliberately serialized.
        var finalItems: [PrimaryHashBatchItem] = []
        finalItems.reserveCapacity(assetIds.count)

        for item in primaryItems {
            guard !Task.isCancelled else { break }

            guard let primaryHash = item.primaryHash,
                  item.errorDescription == nil else {
                finalItems.append(
                    PrimaryHashBatchItem(
                        localIdentifier: item.localIdentifier,
                        result: nil,
                        modificationDate: item.modificationDate,
                        errorDescription: item.errorDescription
                            ?? "Primary requestData hash failed"
                    )
                )
                continue
            }

            var rawHash: String?
            var rawSize: Int64?

            if item.hasRAWCompanion {
                do {
                    let raw = try await hashRawCompanionSafely(
                        assetIdentifier: item.localIdentifier
                    )
                    rawHash = raw.hash
                    rawSize = raw.size
                } catch {
                    guard !Task.isCancelled else { break }
                    finalItems.append(
                        PrimaryHashBatchItem(
                            localIdentifier: item.localIdentifier,
                            result: nil,
                            modificationDate: item.modificationDate,
                            errorDescription:
                                "RAW safe-path failed: \(error.localizedDescription)"
                        )
                    )
                    continue
                }
            }

            finalItems.append(
                PrimaryHashBatchItem(
                    localIdentifier: item.localIdentifier,
                    result: MultiResourceHashResult(
                        localIdentifier: item.localIdentifier,
                        primaryHash: primaryHash,
                        primaryFileSize: item.primaryFileSize,
                        rawHash: rawHash,
                        rawFileSize: rawSize,
                        hasRAW: item.hasRAWCompanion,
                        calculatedAt: Date()
                    ),
                    modificationDate: item.modificationDate,
                    errorDescription: nil
                )
            )
        }

        if !Task.isCancelled {
            for missing in missingAssetIds {
                finalItems.append(
                    PrimaryHashBatchItem(
                        localIdentifier: missing,
                        result: nil,
                        modificationDate: nil,
                        errorDescription: "Asset not found in library"
                    )
                )
            }
        }

        return finalItems
    }

    private func hashPrimaryAssetWithRequestData(
        _ asset: PHAsset,
        allowNetworkAccess: Bool
    ) async -> RequestDataPrimaryItem? {
        final class RequestRef: @unchecked Sendable {
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
                    PHAssetResourceManager.default()
                        .cancelDataRequest(requestID)
                }
            }
        }

        let requestRef = RequestRef()

        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            guard let selection = ImmichRequestDataResourceSelector.select(for: asset) else {
                return RequestDataPrimaryItem(
                    localIdentifier: asset.localIdentifier,
                    primaryHash: nil,
                    primaryFileSize: 0,
                    modificationDate: asset.modificationDate,
                    hasRAWCompanion: false,
                    errorDescription: "Cannot get Immich-compatible asset resource"
                )
            }

            let safeResources = AssetResourceSelector.select(for: asset)
            let hasRAWCompanion = safeResources?.rawResource != nil

            logDebug(
                "Immich resource selection: asset=\(asset.localIdentifier), mediaType=\(asset.mediaType.rawValue), selectedType=\(selection.resource.type.rawValue), selectedCurrent=\(ImmichRequestDataResourceSelector.isCurrent(selection.resource)), selectedBytes=\(selection.selectedSize), candidates=[\(selection.candidateDescription)]",
                category: .hash
            )

            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = allowNetworkAccess
            let startedAt = ProcessInfo.processInfo.systemUptime

            let primary: (hash: String, size: Int64, error: String?) =
                await withCheckedContinuation { continuation in
                    let accumulator = RequestDataHashAccumulator()

                    let requestID = PHAssetResourceManager.default().requestData(
                        for: selection.resource,
                        options: options,
                        dataReceivedHandler: { data in
                            accumulator.append(data)
                        },
                        completionHandler: { error in
                            switch error {
                            case let photosError as PHPhotosError
                                where photosError.code == .userCancelled:
                                continuation.resume(
                                    returning:
                                        ("", 0, "PhotoKit request cancelled")
                                )
                            case let error?:
                                continuation.resume(
                                    returning:
                                        ("", 0, error.localizedDescription)
                                )
                            case nil:
                                let result = accumulator.finalize()
                                continuation.resume(
                                    returning:
                                        (result.hash, result.size, nil)
                                )
                            }
                        }
                    )
                    requestRef.install(requestID)
                }

            guard !Task.isCancelled else { return nil }

            if let error = primary.error {
                return RequestDataPrimaryItem(
                    localIdentifier: asset.localIdentifier,
                    primaryHash: nil,
                    primaryFileSize: 0,
                    modificationDate: asset.modificationDate,
                    hasRAWCompanion: hasRAWCompanion,
                    errorDescription: error
                )
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let mebibytes = Double(primary.size) / (1024.0 * 1024.0)
            let throughput = elapsed > 0 ? mebibytes / elapsed : 0

            logDebug(
                "requestData primary finished: asset=\(asset.localIdentifier), bytes=\(primary.size), elapsed=\(String(format: "%.3f", elapsed))s, throughput=\(String(format: "%.1f", throughput))MiB/s",
                category: .hash
            )

            return RequestDataPrimaryItem(
                localIdentifier: asset.localIdentifier,
                primaryHash: primary.hash,
                primaryFileSize: primary.size,
                modificationDate: asset.modificationDate,
                hasRAWCompanion: hasRAWCompanion,
                errorDescription: nil
            )
        } onCancel: {
            requestRef.cancel()
        }
    }

    private func hashRawCompanionSafely(
        assetIdentifier: String
    ) async throws -> (hash: String, size: Int64) {
        let fetch = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetIdentifier],
            options: nil
        )
        guard let asset = fetch.firstObject,
              let rawResource = AssetResourceSelector.select(for: asset)?.rawResource else {
            throw NSError(
                domain: "HashService",
                code: 404,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "RAW companion disappeared before safe hashing"
                ]
            )
        }

        let rawURL = try await ResourceFileAccess.tempFile(for: rawResource)
        defer { try? FileManager.default.removeItem(at: rawURL) }

        let result = try await Self.readFileHash(
            rawURL,
            assetIdentifier: assetIdentifier,
            resourceLabel: "raw-safe"
        )
        return (result.hash, Int64(result.size))
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
