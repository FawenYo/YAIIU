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
}
