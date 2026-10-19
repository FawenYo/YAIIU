/// Keep only the currently displayed and explicitly cached indexed fetches.
/// SwiftUI may retain previous view values and callbacks after a state update;
/// those copies must share this storage instead of owning previous fetches.
final class PhotoGridFetchStorage<Fetch: AnyObject> {
    var filtered: Fetch?
    var filteredIndexGeneration: Int?
    var cachedNotUploaded: Fetch?
    var cachedNotUploadedIndexGeneration: Int?
    var cachedNotUploadedStatusGeneration: Int?

    var filteredSnapshot: Snapshot { Snapshot(filtered) }

    /// A visible snapshot can open detail during content refreshes, provided its
    /// positions still address the same assets in the manager's current fetch.
    func canOpenFilteredDetail(at index: Int, displayCount: Int, indexGeneration: Int) -> Bool {
        filtered != nil && filteredIndexGeneration == indexGeneration &&
            index >= 0 && index < displayCount
    }

    func canReuseNotUploadedIndices(indexGeneration: Int, statusGeneration: Int) -> Bool {
        cachedNotUploaded != nil && cachedNotUploadedIndexGeneration == indexGeneration &&
            cachedNotUploadedStatusGeneration == statusGeneration
    }

    /// A cell may outlive its indexed fetch in LazyVGrid. Expire that binding
    /// instead of keeping the fetch alive or resolving its index in a new fetch.
    struct Snapshot {
        private(set) weak var value: Fetch?

        init(_ value: Fetch?) {
            self.value = value
        }
    }
}
