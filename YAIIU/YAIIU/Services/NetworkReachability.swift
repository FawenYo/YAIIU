import CoreLocation
import Foundation
import Network
import NetworkExtension
import SystemConfiguration.CaptiveNetwork

final class NetworkReachability: NSObject, ObservableObject {
    static let shared = NetworkReachability()
    
    @Published private(set) var isOnInternalNetwork = false
    @Published private(set) var isConnected = false
    @Published private(set) var currentSSID: String?
    @Published private(set) var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isPreciseLocationEnabled: Bool = false
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.yaiiu.network.monitor")
    private let locationManager = CLLocationManager()
    private var configuredSSID: String?
    
    private override init() {
        super.init()
        locationManager.delegate = self
        locationAuthorizationStatus = locationManager.authorizationStatus
        isPreciseLocationEnabled = locationManager.accuracyAuthorization == .fullAccuracy
        startMonitoring()
    }
    
    deinit {
        monitor.cancel()
    }
    
    // MARK: - Public Interface
    
    func configure(ssid: String?) {
        configuredSSID = ssid?.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if let ssid = configuredSSID, !ssid.isEmpty,
           locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        
        checkNetworkStatus()
    }
    
    func resolveServerURL(externalURL: String, internalURL: String?, ssid: String?) -> String {
        guard let internalURL, !internalURL.isEmpty,
              let ssid, !ssid.isEmpty else {
            return externalURL
        }
        return isOnInternalNetwork ? internalURL : externalURL
    }
    
    func refresh() {
        checkNetworkStatus()
    }
    
    func requestLocationPermission() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            checkNetworkStatus()
        default:
            break
        }
    }
    
    func getCurrentWiFiSSID() -> String? {
        #if targetEnvironment(simulator)
        return nil
        #else
        return fetchSSIDViaCNCopy()
        #endif
    }
    
    // MARK: - Private Methods
    
    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let isWiFi = path.usesInterfaceType(.wifi)
            
            DispatchQueue.main.async {
                self?.isConnected = connected
            }
            
            if connected && isWiFi {
                self?.checkNetworkStatus()
            } else {
                DispatchQueue.main.async {
                    self?.currentSSID = nil
                    self?.isOnInternalNetwork = false
                }
            }
        }
        monitor.start(queue: queue)
    }
    
    private func checkNetworkStatus() {
        fetchSSID { [weak self] ssid in
            DispatchQueue.main.async {
                guard let self else { return }
                self.currentSSID = ssid
                self.isOnInternalNetwork = self.matchesConfiguredSSID(ssid)
            }
        }
    }
    
    private func matchesConfiguredSSID(_ ssid: String?) -> Bool {
        guard let ssid,
              let configured = configuredSSID,
              !configured.isEmpty else {
            return false
        }
        return ssid == configured
    }
    
    private func fetchSSID(completion: @escaping (String?) -> Void) {
        #if targetEnvironment(simulator)
        completion(nil)
        #else
        
        NEHotspotNetwork.fetchCurrent { network in
            if let ssid = network?.ssid {
                completion(ssid)
            } else {
                // Fallback to deprecated method for older iOS versions if needed
                completion(self.fetchSSIDViaCNCopy())
            }
        }
        #endif
    }
    
    private func fetchSSIDViaCNCopy() -> String? {
        guard let interfaces = CNCopySupportedInterfaces() as? [String] else {
            return nil
        }
        
        for interface in interfaces {
            guard let info = CNCopyCurrentNetworkInfo(interface as CFString) as? [String: Any],
                  let ssid = info[kCNNetworkInfoKeySSID as String] as? String else {
                continue
            }
            return ssid
        }
        return nil
    }
}

// MARK: - CLLocationManagerDelegate

extension NetworkReachability: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let preciseEnabled = manager.accuracyAuthorization == .fullAccuracy
        
        DispatchQueue.main.async {
            self.locationAuthorizationStatus = status
            self.isPreciseLocationEnabled = preciseEnabled
        }
        
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            checkNetworkStatus()
        }
    }
}
