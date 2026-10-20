import Foundation

struct FavoriteChangeDetector {
    struct Change: Equatable {
        let localIdentifier: String
        let immichId: String
        let newFavorite: Bool
    }

    static func detectChanges(
        in uploadedAssets: [UploadedAssetFavoriteInfo],
        batchSize: Int = 300,
        fetchFavorites: ([String]) -> [String: Bool]
    ) -> [Change] {
        precondition(batchSize > 0)
        var changes: [Change] = []
        for start in stride(from: 0, to: uploadedAssets.count, by: batchSize) {
            // Include the fetch itself so PhotoKit result buffers and the
            // comparison map are released before requesting another batch.
            autoreleasepool {
                let batch = uploadedAssets[start..<min(start + batchSize, uploadedAssets.count)]
                let favorites = fetchFavorites(batch.map(\.localIdentifier))
                for asset in batch {
                    guard let current = favorites[asset.localIdentifier],
                          current != asset.storedFavorite else { continue }
                    changes.append(Change(
                        localIdentifier: asset.localIdentifier,
                        immichId: asset.immichId,
                        newFavorite: current
                    ))
                }
            }
        }
        return changes
    }
}
