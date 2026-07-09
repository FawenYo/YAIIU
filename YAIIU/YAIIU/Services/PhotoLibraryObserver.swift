import Foundation
import Photos

/// Long-lived registration of a photo library change observer on the shared
/// PHPhotoLibrary instance.
///
/// Enabling the background upload extension (setUploadJobExtensionEnabled) requires
/// the shared library to be an active, observed instance. Registering an observer
/// while authorization is still `.notDetermined` triggers the system permission
/// prompt, so this warm-up must only run after full access has been granted.
final class PhotoLibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotoLibraryObserver()

    private var isRegistered = false

    private override init() {
        super.init()
    }

    /// Registers as a change observer on the shared library. Safe to call multiple
    /// times; only the first call after authorization has any effect. Must not be
    /// called while authorization is `.notDetermined`, or it will prompt the user.
    func warmUpIfAuthorized() {
        guard !isRegistered else { return }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        PHPhotoLibrary.shared().register(self)
        isRegistered = true
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        // No-op. Registration exists solely to keep the shared library active so the
        // background upload extension can be enabled. Per-view photo updates are
        // handled by PhotoLibraryManager instances.
    }
}
