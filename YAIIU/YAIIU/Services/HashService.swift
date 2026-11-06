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
/// hash and which PhotoKit version they were selected from. Selection happens
/// once in `AssetResourceSelector.select(for:)`.
struct AssetResourcePlan: Sendable {
    let localIdentifier: String
    /// RAW-only libraries hash the RAW as the primary, with no separate RAW slot.
    let isRAWOnly: Bool
    let modificationDate: Date?
    let adjustmentVersion: String
}

/// Resources selected for an asset: the primary (JPEG/video) and optional RAW.
/// `PHAssetResource` is not Sendable, so this stays with the task that
/// selected it; only `plan` may cross task boundaries.
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
                adjustmentVersion: PhotoAssetAdjustmentVersion.make(for: asset)
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
            adjustmentVersion: PhotoAssetAdjustmentVersion.make(for: asset)
        )
        return AssetResources(plan: plan, primaryResource: primary, rawResource: rawResource)
    }
}

class HashService {
    static let shared = HashService()

    private static let rawIdentifiers: Set<String> = [
        "raw-image", "dng", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2"
    ]

    static func isRAWResource(_ resource: PHAssetResource) -> Bool {
        if resource.type == .alternatePhoto {
            return true
        }

        let uti = resource.uniformTypeIdentifier.lowercased()
        return rawIdentifiers.contains { uti.contains($0) }
    }

    private init() {}

    /// Hashes planned resources directly from `requestData` chunks, without
    /// writing temp files.
    func streamHash(_ resources: AssetResources) async throws -> MultiResourceHashResult {
        let plan = resources.plan
        let primary = try await ResourceStreamHasher.sha1Hex(of: resources.primaryResource)

        var raw: (hash: String, size: Int)?
        if !plan.isRAWOnly, let rawResource = resources.rawResource {
            raw = try await ResourceStreamHasher.sha1Hex(of: rawResource)
        }

        return MultiResourceHashResult(
            localIdentifier: plan.localIdentifier,
            primaryHash: primary.hash,
            primaryFileSize: Int64(primary.size),
            rawHash: raw?.hash,
            rawFileSize: raw.map { Int64($0.size) },
            hasRAW: raw != nil,
            calculatedAt: Date()
        )
    }
}
