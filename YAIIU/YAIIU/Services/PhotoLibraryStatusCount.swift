import Foundation

struct PhotoLibraryStatusCount {
    /// A badge is informative only after both stores have been loaded and
    /// there is no concurrent sync/hash job changing its membership.
    static func canPresentCount(
        statusCacheReady: Bool,
        isServerSyncing: Bool,
        isHashProcessing: Bool,
        hasPhotoLibraryFetch: Bool,
        isPhotoLibraryLoading: Bool
    ) -> Bool {
        statusCacheReady && !isServerSyncing && !isHashProcessing &&
            hasPhotoLibraryFetch && !isPhotoLibraryLoading
    }

    static func notUploadedCount(
        totalCount: Int,
        statuses: [String: PhotoSyncStatus],
        batchSize: Int = 300,
        shouldStop: () -> Bool = { false },
        countVisibleUploaded: ([String]) -> Int
    ) -> Int? {
        precondition(batchSize > 0)
        var uploadedCount = 0
        var batch: [String] = []
        batch.reserveCapacity(batchSize)
        for (identifier, status) in statuses {
            guard !shouldStop() else { return nil }
            guard status == .uploaded else { continue }
            batch.append(identifier)
            if batch.count == batchSize {
                uploadedCount += autoreleasepool { countVisibleUploaded(batch) }
                batch.removeAll(keepingCapacity: true)
            }
        }
        guard !shouldStop() else { return nil }
        if !batch.isEmpty {
            uploadedCount += autoreleasepool { countVisibleUploaded(batch) }
        }
        guard !shouldStop() else { return nil }
        return max(0, totalCount - uploadedCount)
    }
}
