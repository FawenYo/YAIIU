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

/// Decides whether a PhotoKit change can affect the persisted inventory or hash
/// cache. iCloud thumbnail downloads and other metadata updates arrive as
/// in-place changes that keep each asset's adjustment version, and must not
/// start a foreground reconciliation on every notification.
enum PhotoKitInventoryChangePolicy {
    // Bounds the synchronous hash_cache lookup on the PhotoKit callback queue.
    static let maxInspectedChanges = 500

    static func shouldInspectVersions(
        isIncremental: Bool, insertedCount: Int, removedCount: Int, hasMoves: Bool, changedCount: Int
    ) -> Bool {
        isIncremental && insertedCount == 0 && removedCount == 0 && !hasMoves &&
            changedCount > 0 && changedCount <= maxInspectedChanges
    }

    /// `storedVersions` holds only non-NULL `hash_cache.asset_adjustment_version`
    /// values; an asset missing from it is unknown and always needs reconciliation.
    static func requiresReconciliation(
        isIncremental: Bool,
        insertedCount: Int,
        removedCount: Int,
        hasMoves: Bool,
        currentVersions: [String: String],
        storedVersions: [String: String]
    ) -> Bool {
        guard isIncremental, insertedCount == 0, removedCount == 0, !hasMoves,
              !currentVersions.isEmpty else { return true }
        return currentVersions.contains { identifier, version in
            storedVersions[identifier] != version
        }
    }
}
