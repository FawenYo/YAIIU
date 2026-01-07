import Foundation
import SwiftUI

class SettingsManager: ObservableObject {
    @Published var serverURL: String = ""
    @Published var apiKey: String = ""
    @Published var isLoggedIn: Bool = false
    @Published var hasCompletedOnboarding: Bool = false
    @Published var hasCompletedInitialSetup: Bool = false
    @Published var needsAppRestart: Bool = false
    
    private let serverURLKey = "immich_server_url"
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
    }
    
    private func saveSettings() {
        UserDefaults.standard.set(serverURL, forKey: serverURLKey)
        UserDefaults.standard.set(isLoggedIn, forKey: isLoggedInKey)
        UserDefaults.standard.set(hasCompletedOnboarding, forKey: hasCompletedOnboardingKey)
        UserDefaults.standard.set(hasCompletedInitialSetup, forKey: hasCompletedInitialSetupKey)
        UserDefaults.standard.set(needsAppRestart, forKey: needsAppRestartKey)
        saveAPIKeyToKeychain(apiKey)
    }
    
    func login(serverURL: String, apiKey: String) {
        self.serverURL = serverURL
        self.apiKey = apiKey
        self.isLoggedIn = true
        // Reset onboarding and initial setup status for new login
        self.hasCompletedOnboarding = false
        self.hasCompletedInitialSetup = false
        saveSettings()
        
        // Sync settings to SharedSettings for background upload extension
        if #available(iOS 26.1, *) {
            BackgroundUploadManager.shared.syncSettings(
                serverURL: serverURL,
                apiKey: apiKey
            )
        } else {
            // For iOS versions below 26.1, still sync to SharedSettings
            SharedSettings.shared.syncFromMainApp(
                serverURL: serverURL,
                apiKey: apiKey,
                isLoggedIn: true
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
        self.apiKey = ""
        self.isLoggedIn = false
        
        UserDefaults.standard.removeObject(forKey: serverURLKey)
        UserDefaults.standard.removeObject(forKey: isLoggedInKey)
        deleteAPIKeyFromKeychain()
        
        // Clear SharedSettings and disable background upload
        if #available(iOS 26.1, *) {
            Task {
                await BackgroundUploadManager.shared.handleLogout()
            }
        } else {
            // For iOS versions below 26.1, still clear SharedSettings
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
