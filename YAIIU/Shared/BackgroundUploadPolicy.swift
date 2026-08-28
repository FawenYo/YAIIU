import Foundation

/// Network state used to decide whether the extension may create new upload jobs.
public enum BackgroundUploadNetworkInterface: Equatable {
    case wifi
    case cellular
    case other
    case unavailable
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
        case .other, .unavailable:
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
