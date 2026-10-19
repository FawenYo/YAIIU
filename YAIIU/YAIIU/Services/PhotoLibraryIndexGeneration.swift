/// Tracks changes that can make a numeric asset position refer to another photo.
/// Content-only PhotoKit updates, including iCloud downloads, preserve positions.
struct PhotoLibraryIndexGeneration {
    private(set) var value = 0

    mutating func recordReload() {
        value &+= 1
    }

    mutating func recordChange(
        isIncremental: Bool, insertedCount: Int, removedCount: Int, hasMoves: Bool
    ) {
        if !isIncremental || insertedCount > 0 || removedCount > 0 || hasMoves {
            recordReload()
        }
    }

    func canReuseIdentifiers(
        from previousGeneration: Int, snapshotIsReady: Bool, snapshotCount: Int, assetCount: Int
    ) -> Bool {
        value == previousGeneration && snapshotIsReady && snapshotCount == assetCount
    }
}

struct PhotoAssetContentRevision: Equatable {
    let library: UInt64
    let asset: UInt64

    /// A newly shown asset performs its normal initial load. Only a changed
    /// revision for the *same* visible asset needs an additional reload.
    static func needsReload(
        previousIdentifier: String?,
        previousRevision: Self?,
        currentIdentifier: String,
        currentRevision: Self
    ) -> Bool {
        guard previousIdentifier == currentIdentifier,
              let previousRevision else { return false }
        return previousRevision != currentRevision
    }
}
