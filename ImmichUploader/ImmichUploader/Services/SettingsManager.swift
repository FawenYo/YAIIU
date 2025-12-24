import Foundation
import SwiftUI

class SettingsManager: ObservableObject {
    @Published var serverURL: String = ""
    @Published var apiKey: String = ""
    @Published var isLoggedIn: Bool = false
    @Published var hasCompletedOnboarding: Bool = false
    
    private let serverURLKey = "immich_server_url"
    private let apiKeyKey = "immich_api_key"
    private let isLoggedInKey = "immich_is_logged_in"
    private let hasCompletedOnboardingKey = "immich_has_completed_onboarding"
    
    init() {
        loadSettings()
    }
    
    private func loadSettings() {
        serverURL = UserDefaults.standard.string(forKey: serverURLKey) ?? ""
        apiKey = loadAPIKeyFromKeychain() ?? ""
        isLoggedIn = UserDefaults.standard.bool(forKey: isLoggedInKey)
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: hasCompletedOnboardingKey)
        
        if isLoggedIn && (serverURL.isEmpty || apiKey.isEmpty) {
            isLoggedIn = false
            UserDefaults.standard.set(false, forKey: isLoggedInKey)
        }
    }
    
    private func saveSettings() {
        UserDefaults.standard.set(serverURL, forKey: serverURLKey)
        UserDefaults.standard.set(isLoggedIn, forKey: isLoggedInKey)
        UserDefaults.standard.set(hasCompletedOnboarding, forKey: hasCompletedOnboardingKey)
        saveAPIKeyToKeychain(apiKey)
    }
    
    func login(serverURL: String, apiKey: String) {
        self.serverURL = serverURL
        self.apiKey = apiKey
        self.isLoggedIn = true
        // Reset onboarding status for new login
        self.hasCompletedOnboarding = false
        saveSettings()
    }
    
    func completeOnboarding() {
        self.hasCompletedOnboarding = true
        saveSettings()
    }
    
    func logout() {
        self.serverURL = ""
        self.apiKey = ""
        self.isLoggedIn = false
        
        UserDefaults.standard.removeObject(forKey: serverURLKey)
        UserDefaults.standard.removeObject(forKey: isLoggedInKey)
        deleteAPIKeyFromKeychain()
    }
    
    // MARK: - Keychain Operations
    
    private let keychainService = "com.immich.uploader"
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
