import Foundation

/// Network state used to decide whether the extension may create new upload jobs.
public enum BackgroundUploadNetworkInterface: Equatable {
    case wifi
    case cellular
    case other
    case unavailable
    case unknown
}

public enum BackgroundUploadPolicy {
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
    /// Bound diagnostic retries and keep all copies of a selected asset together.
    public static func isolationGroups<Item, AssetID: Hashable>(
        _ jobs: [Item],
        maxGroups: Int,
        assetIdentifier: (Item) -> AssetID
    ) -> [[Item]] {
        guard maxGroups > 0 else { return [] }
        var groups = [[Item]]()
        var indices = [AssetID: Int]()
        for job in jobs {
            let identifier = assetIdentifier(job)
            if let index = indices[identifier] {
                groups[index].append(job)
            } else if groups.count < maxGroups {
                indices[identifier] = groups.count
                groups.append([job])
            }
        }
        return groups
    }

}
