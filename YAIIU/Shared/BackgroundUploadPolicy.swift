import Foundation
import Photos

/// Network state used to decide whether the extension may create new upload jobs.
public enum BackgroundUploadNetworkInterface: Equatable {
    case wifi
    case cellular
    case other
    case unavailable
    case unknown
}

public enum BackgroundUploadPolicy {
    /// Live Photos use .pairedVideo / .fullSizePairedVideo for their movie
    /// companions. They are separate uploadable resources from the still.
    public static func isUploadableResourceType(_ type: PHAssetResourceType) -> Bool {
        switch type {
        case .photo, .fullSizePhoto, .video, .fullSizeVideo,
             .pairedVideo, .fullSizePairedVideo, .alternatePhoto:
            return true
        default:
            return false
        }
    }

    // Shared by foreground and extension to avoid order-dependent video choice.
    static func livePhotoVideoPriority(_ type: PHAssetResourceType) -> Int {
        switch type {
        case .fullSizePairedVideo: return 4
        case .pairedVideo: return 3
        case .fullSizeVideo: return 2
        case .video: return 1
        default: return 0
        }
    }

    /// A Live Photo may expose both original and edited movie resources.
    /// The background job table keys by (asset_id, "video"), so schedule
    /// exactly one video, preferring the full-size edited variant.
    static func preferredLivePhotoVideoIndex(types: [PHAssetResourceType]) -> Int? {
        types.indices.filter { livePhotoVideoPriority(types[$0]) > 0 }
            .max { livePhotoVideoPriority(types[$0]) < livePhotoVideoPriority(types[$1]) }
    }

    static func selectUploadableResources(
        _ resources: [PHAssetResource], isLivePhoto: Bool
    ) -> [PHAssetResource] {
        let accepted = resources.filter { isUploadableResourceType($0.type) }
        guard isLivePhoto else { return accepted }
        let preferred = preferredLivePhotoVideoIndex(types: accepted.map(\.type))
        return accepted.enumerated().compactMap { index, resource in
            if livePhotoVideoPriority(resource.type) > 0 && index != preferred {
                return nil
            }
            return resource
        }
    }

    /// Existing retry and acknowledgement jobs are not subject to this policy.
    public static func canCreateNewJobs(
        allowCellular: Bool,
        interface: BackgroundUploadNetworkInterface
    ) -> Bool {
        switch interface {
        case .wifi:
            return true
        case .cellular:
            return allowCellular
        case .other, .unavailable, .unknown:
            return false
        }
    }
    public enum RequestPurpose {
        case newJob
        case retry
    }

    public static func allowsCellularAccess(
        for purpose: RequestPurpose,
        allowCellular: Bool
    ) -> Bool {
        switch purpose {
        case .newJob:
            return allowCellular
        case .retry:
            return true
        }
    }
}
