import Foundation

struct PhotoLibraryStatusCount {
    /// A badge is informative only after both stores have been loaded and
    /// there is no concurrent sync/hash job changing its membership.
    static func canPresentCount(
        statusCacheReady: Bool,
        isServerSyncing: Bool,
        isHashProcessing: Bool,
        isUploading: Bool,
        hasFullPhotoAccess: Bool,
        hasPhotoLibraryFetch: Bool,
        isPhotoLibraryLoading: Bool
    ) -> Bool {
        statusCacheReady && !isServerSyncing && !isHashProcessing && !isUploading &&
            hasFullPhotoAccess && hasPhotoLibraryFetch && !isPhotoLibraryLoading
    }

}
