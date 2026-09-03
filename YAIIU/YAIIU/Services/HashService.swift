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
    /// KVC size estimate; may be 0 for iCloud-optimised assets (caller floors it).
    let estimatedBytes: Int64
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
            let plan = AssetResourcePlan(
                localIdentifier: asset.localIdentifier,
                isRAWOnly: true,
                modificationDate: asset.modificationDate,
                estimatedBytes: estimatedSize(of: [raw])
            )
            return AssetResources(plan: plan, primaryResource: raw, rawResource: nil)
        }

        guard let primary = primaryResource ?? resources.first(where: { !HashService.isRAWResource($0) }) else {
            return nil
        }

        let plan = AssetResourcePlan(
            localIdentifier: asset.localIdentifier,
            isRAWOnly: false,
            modificationDate: asset.modificationDate,
            estimatedBytes: estimatedSize(of: [primary] + (rawResource.map { [$0] } ?? []))
        )
        return AssetResources(plan: plan, primaryResource: primary, rawResource: rawResource)
    }

    private static func estimatedSize(of resources: [PHAssetResource]) -> Int64 {
        resources.reduce(0) { partial, resource in
            partial + ((resource.value(forKey: "fileSize") as? CLong).map(Int64.init) ?? 0)
        }
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
    /// File reads run off the cooperative pool so large originals never block it.
    func hash(_ files: AssetTempFiles) async throws -> MultiResourceHashResult {
        defer { files.removeAll() }

        let plan = files.plan
        let (primaryHash, primarySize) = try await Self.readFileHash(files.primaryFileURL)

        var rawHash: String?
        var rawSize: Int64?

        if !plan.isRAWOnly, let rawFileURL = files.rawFileURL {
            let (hash, size) = try await Self.readFileHash(rawFileURL)
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

    /// File hashing on a utility-priority thread, with cancellation forwarded
    /// so a stopped run abandons large files between chunks.
    private static func readFileHash(_ url: URL) async throws -> (hash: String, size: Int) {
        let task = Task.detached(priority: .utility) {
            try FileHasher.sha1Hex(ofFileAt: url)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
