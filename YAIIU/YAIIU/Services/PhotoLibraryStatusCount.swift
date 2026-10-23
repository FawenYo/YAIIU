import Foundation

struct PhotoLibraryStatusCount {
    /// Filters can show the last loaded state while the authoritative
    /// Not Uploaded badge waits for migration/sync/hash work to settle.
    static func canBuildNotUploadedFilter(
        hasLoadedStatusSnapshot: Bool,
        hasPhotoLibraryFetch: Bool,
        isPhotoLibraryLoading: Bool
    ) -> Bool {
        hasLoadedStatusSnapshot && hasPhotoLibraryFetch && !isPhotoLibraryLoading
    }

    /// A badge is informative only after both stores have been loaded and
    /// there is no concurrent sync/hash job changing its membership.
    static func canPresentCount(
        statusCacheReady: Bool,
        inventoryUpToDate: Bool,
        isServerSyncing: Bool,
        isHashProcessing: Bool,
        isUploading: Bool,
        hasFullPhotoAccess: Bool,
        hasPhotoLibraryFetch: Bool,
        isPhotoLibraryLoading: Bool
    ) -> Bool {
        statusCacheReady && inventoryUpToDate && !isServerSyncing && !isHashProcessing && !isUploading &&
            hasFullPhotoAccess && hasPhotoLibraryFetch && !isPhotoLibraryLoading
    }

}
