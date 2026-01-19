import Foundation
import SwiftUI

class SettingsManager: ObservableObject {
    @Published var serverURL: String = ""
    @Published var internalServerURL: String = ""
    @Published var internalNetworkSSID: String = ""
    @Published var apiKey: String = ""
    @Published var isLoggedIn: Bool = false
    @Published var hasCompletedOnboarding: Bool = false
    @Published var hasCompletedInitialSetup: Bool = false
    @Published var needsAppRestart: Bool = false
    
    private let serverURLKey = "immich_server_url"
    private let internalServerURLKey = "immich_internal_server_url"
    private let internalNetworkSSIDKey = "immich_internal_network_ssid"
    private let apiKeyKey = "immich_api_key"
    private let isLoggedInKey = "immich_is_logged_in"
    private let hasCompletedOnboardingKey = "immich_has_completed_onboarding"
    private let hasCompletedInitialSetupKey = "immich_has_completed_initial_setup"
    private let needsAppRestartKey = "immich_needs_app_restart"
    
    init() {
        loadSettings()
    }
    
    private func loadSettings() {
        serverURL = UserDefaults.standard.string(forKey: serverURLKey) ?? ""
        internalServerURL = UserDefaults.standard.string(forKey: internalServerURLKey) ?? ""
        internalNetworkSSID = UserDefaults.standard.string(forKey: internalNetworkSSIDKey) ?? ""
        apiKey = loadAPIKeyFromKeychain() ?? ""
        isLoggedIn = UserDefaults.standard.bool(forKey: isLoggedInKey)
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: hasCompletedOnboardingKey)
        hasCompletedInitialSetup = UserDefaults.standard.bool(forKey: hasCompletedInitialSetupKey)
        needsAppRestart = UserDefaults.standard.bool(forKey: needsAppRestartKey)
        
        // Clear restart flag on app launch - user has restarted the app
        if needsAppRestart {
            needsAppRestart = false
            UserDefaults.standard.set(false, forKey: needsAppRestartKey)
        }
        
        if isLoggedIn && (serverURL.isEmpty || apiKey.isEmpty) {
            isLoggedIn = false
            UserDefaults.standard.set(false, forKey: isLoggedInKey)
        }
        
        if !internalNetworkSSID.isEmpty {
            NetworkReachability.shared.configure(ssid: internalNetworkSSID)
        }
    }
    
    private func saveSettings() {
        UserDefaults.standard.set(serverURL, forKey: serverURLKey)
        UserDefaults.standard.set(internalServerURL, forKey: internalServerURLKey)
        UserDefaults.standard.set(internalNetworkSSID, forKey: internalNetworkSSIDKey)
        UserDefaults.standard.set(isLoggedIn, forKey: isLoggedInKey)
        UserDefaults.standard.set(hasCompletedOnboarding, forKey: hasCompletedOnboardingKey)
        UserDefaults.standard.set(hasCompletedInitialSetup, forKey: hasCompletedInitialSetupKey)
        UserDefaults.standard.set(needsAppRestart, forKey: needsAppRestartKey)
        saveAPIKeyToKeychain(apiKey)
    }
    
    var activeServerURL: String {
        return NetworkReachability.shared.resolveServerURL(
            externalURL: serverURL,
            internalURL: internalServerURL.isEmpty ? nil : internalServerURL,
            ssid: internalNetworkSSID.isEmpty ? nil : internalNetworkSSID
        )
    }
    
    func login(serverURL: String, apiKey: String, internalServerURL: String? = nil, ssid: String? = nil) {
        self.serverURL = serverURL
        self.internalServerURL = internalServerURL ?? ""
        self.internalNetworkSSID = ssid ?? ""
        self.apiKey = apiKey
        self.isLoggedIn = true
        self.hasCompletedOnboarding = false
        self.hasCompletedInitialSetup = false
        
        if let ssid = ssid, !ssid.isEmpty {
            NetworkReachability.shared.configure(ssid: ssid)
        }
        
        saveSettings()
        syncToSharedSettings()
    }
    
    func updateServerURL(_ url: String) {
        self.serverURL = url
        UserDefaults.standard.set(url, forKey: serverURLKey)
        syncToSharedSettings()
    }
    
    func updateInternalNetworkSettings(url: String, ssid: String) {
        self.internalServerURL = url
        self.internalNetworkSSID = ssid
        
        UserDefaults.standard.set(url, forKey: internalServerURLKey)
        UserDefaults.standard.set(ssid, forKey: internalNetworkSSIDKey)
        
        NetworkReachability.shared.configure(ssid: ssid.isEmpty ? nil : ssid)
        
        syncToSharedSettings()
    }
    
    private func syncToSharedSettings() {
        if #available(iOS 26.1, *) {
            BackgroundUploadManager.shared.syncSettings(
                serverURL: serverURL,
                apiKey: apiKey,
                internalServerURL: internalServerURL.isEmpty ? nil : internalServerURL,
                ssid: internalNetworkSSID.isEmpty ? nil : internalNetworkSSID
            )
        } else {
            SharedSettings.shared.syncFromMainApp(
                serverURL: serverURL,
                apiKey: apiKey,
                isLoggedIn: true,
                internalServerURL: internalServerURL.isEmpty ? nil : internalServerURL,
                ssid: internalNetworkSSID.isEmpty ? nil : internalNetworkSSID
            )
        }
    }
    
    func completeOnboarding() {
        self.hasCompletedOnboarding = true
        saveSettings()
    }
    
    func completeInitialSetup() {
        self.hasCompletedInitialSetup = true
        saveSettings()
    }
    
    func requestAppRestart() {
        self.needsAppRestart = true
        saveSettings()
    }
    
    func logout() {
        self.serverURL = ""
        self.internalServerURL = ""
        self.internalNetworkSSID = ""
        self.apiKey = ""
        self.isLoggedIn = false
        
        UserDefaults.standard.removeObject(forKey: serverURLKey)
        UserDefaults.standard.removeObject(forKey: internalServerURLKey)
        UserDefaults.standard.removeObject(forKey: internalNetworkSSIDKey)
        UserDefaults.standard.removeObject(forKey: isLoggedInKey)
        deleteAPIKeyFromKeychain()
        
        // Clear SharedSettings and disable background upload
        if #available(iOS 26.1, *) {
            Task {
                await BackgroundUploadManager.shared.handleLogout()
            }
        } else {
            SharedSettings.shared.clearAll()
        }
    }
    
    // MARK: - Keychain Operations
    
    private let keychainService = "com.fawenyo.yaiiu"
    private let keychainAccount = "api_key"
    
    private func saveAPIKeyToKeychain(_ apiKey: String) {
        let data = apiKey.data(using: .utf8)!
        
        deleteAPIKeyFromKeychain()
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data
        ]
        
        SecItemAdd(query as CFDictionary, nil)
    }
    
    private func loadAPIKeyFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        
        return nil
    }
    
    private func deleteAPIKeyFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        
        SecItemDelete(query as CFDictionary)
    }
}
