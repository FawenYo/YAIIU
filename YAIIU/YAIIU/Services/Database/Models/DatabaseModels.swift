import Foundation

struct UploadRecord {
    let id: Int
    let localIdentifier: String
    let resourceType: String
    let filename: String
    let immichId: String?
    let uploadedAt: String?
    let fileSize: Int64
    let isDuplicate: Bool
}

struct HashCacheRecord {
    let id: Int
    let localIdentifier: String
    let sha1Hash: String
    let fileSize: Int64
    let syncStatus: String
    let isOnServer: Bool
    let calculatedAt: String?
    let checkedAt: String?
}

struct ServerAssetRecord {
    let immichId: String
    let checksum: String
    let originalFilename: String?
    let assetType: String?
    let updatedAt: String?
}

struct SyncMetadata {
    let lastSyncTime: Date?
    let lastSyncType: String?
    let userId: String?
    let totalAssets: Int
}

struct MultiResourceHashRecord {
    let assetId: String
    let primaryHash: String
    let rawHash: String?
    let hasRAW: Bool
    let primaryOnServer: Bool
    let rawOnServer: Bool
}

struct UploadedAssetFavoriteInfo {
    let localIdentifier: String
    let immichId: String
    let storedFavorite: Bool
}
