import Foundation
import Security

/// SharedSettings uses App Group to share settings between the main App and Extension
/// App Group: group.com.fawenyo.yaiiu
class SharedSettings {
    static let shared = SharedSettings()
    
    private let appGroupIdentifier = "group.com.fawenyo.yaiiu"
    private let userDefaults: UserDefaults?
    
    // MARK: - Keys
    private let serverURLKey = "immich_server_url"
    private let isLoggedInKey = "immich_is_logged_in"
    private let backgroundUploadEnabledKey = "immich_background_upload_enabled"
    private let lastProcessedChangeTokenKey = "immich_last_processed_change_token"
    private let uploadedAssetIdentifiersKey = "immich_uploaded_asset_identifiers"
    
    // MARK: - Keychain
    private let keychainService = "com.fawenyo.yaiiu.shared"
    private let keychainAccount = "api_key"
    private let keychainAccessGroup = "group.com.fawenyo.yaiiu"
    
    private init() {
        userDefaults = UserDefaults(suiteName: appGroupIdentifier)
        if userDefaults == nil {
            print("[SharedSettings] Warning: Failed to initialize UserDefaults with app group: \(appGroupIdentifier)")
        }
    }
    
    // MARK: - Server Settings
    
    var serverURL: String {
        get {
            return userDefaults?.string(forKey: serverURLKey) ?? ""
        }
        set {
            userDefaults?.set(newValue, forKey: serverURLKey)
            userDefaults?.synchronize()
        }
    }
    
    var apiKey: String {
        get {
            return loadAPIKeyFromKeychain() ?? ""
        }
        set {
            saveAPIKeyToKeychain(newValue)
        }
    }
    
    var isLoggedIn: Bool {
        get {
            return userDefaults?.bool(forKey: isLoggedInKey) ?? false
        }
        set {
            userDefaults?.set(newValue, forKey: isLoggedInKey)
            userDefaults?.synchronize()
        }
    }
    
    // MARK: - Background Upload Settings
    
    var backgroundUploadEnabled: Bool {
        get {
            return userDefaults?.bool(forKey: backgroundUploadEnabledKey) ?? false
        }
        set {
            userDefaults?.set(newValue, forKey: backgroundUploadEnabledKey)
            userDefaults?.synchronize()
        }
    }
    
    // MARK: - Change Token to track photo library changes
    
    var lastProcessedChangeToken: Data? {
        get {
            return userDefaults?.data(forKey: lastProcessedChangeTokenKey)
        }
        set {
            userDefaults?.set(newValue, forKey: lastProcessedChangeTokenKey)
            userDefaults?.synchronize()
        }
    }
    
    // MARK: - Uploaded Asset Tracking
    
    var uploadedAssetIdentifiers: Set<String> {
        get {
            if let array = userDefaults?.array(forKey: uploadedAssetIdentifiersKey) as? [String] {
                return Set(array)
            }
            return []
        }
        set {
            userDefaults?.set(Array(newValue), forKey: uploadedAssetIdentifiersKey)
            userDefaults?.synchronize()
        }
    }
    
    func markAssetAsUploaded(_ identifier: String) {
        var identifiers = uploadedAssetIdentifiers
        identifiers.insert(identifier)
        uploadedAssetIdentifiers = identifiers
    }
    
    func isAssetUploaded(_ identifier: String) -> Bool {
        return uploadedAssetIdentifiers.contains(identifier)
    }
    
    // MARK: - Sync Settings from Main App

    func syncFromMainApp(serverURL: String, apiKey: String, isLoggedIn: Bool) {
        self.serverURL = serverURL
        self.apiKey = apiKey
        self.isLoggedIn = isLoggedIn
    }
    
    func clearAll() {
        serverURL = ""
        apiKey = ""
        isLoggedIn = false
        backgroundUploadEnabled = false
        lastProcessedChangeToken = nil
    }
    
    // MARK: - Keychain Operations
    
    private func saveAPIKeyToKeychain(_ apiKey: String) {
        guard let data = apiKey.data(using: .utf8) else { return }
        
        deleteAPIKeyFromKeychain()
        
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        query[kSecAttrAccessGroup as String] = keychainAccessGroup
        
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("[SharedSettings] Failed to save API key to keychain: \(status)")
        }
    }
    
    private func loadAPIKeyFromKeychain() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        query[kSecAttrAccessGroup as String] = keychainAccessGroup
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        
        return nil
    }
    
    private func deleteAPIKeyFromKeychain() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        
        query[kSecAttrAccessGroup as String] = keychainAccessGroup
        
        SecItemDelete(query as CFDictionary)
    }
}
