import Foundation
import Security
import SwiftUI

class SettingsManager: ObservableObject {
    enum CredentialPersistenceError: LocalizedError {
        case saveFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Unable to securely save login credentials (Keychain OSStatus \(status)). Please try again."
            }
        }
    }

    private let preferences: UserDefaults
    private let credentialStore: CredentialStorage

    @Published var serverURL: String = ""
    @Published var internalServerURL: String = ""
    @Published var internalNetworkSSID: String = ""
    @Published var apiKey: String = ""
    @Published var isLoggedIn: Bool = false
    @Published var allowCellularBackgroundUpload: Bool = true
    @Published var syncApplePhotosAlbums: Bool = false
    @Published var hasCompletedOnboarding: Bool = false
    @Published var hasCompletedInitialSetup: Bool = false
    @Published var hasCompletedPhotoPermission: Bool = false
    
    private let serverURLKey = "immich_server_url"
    private let internalServerURLKey = "immich_internal_server_url"
    private let internalNetworkSSIDKey = "immich_internal_network_ssid"
    private let apiKeyKey = "immich_api_key"
    static let isLoggedInKey = "immich_is_logged_in"
    private let hasCompletedOnboardingKey = "immich_has_completed_onboarding"
    private let hasCompletedInitialSetupKey = "immich_has_completed_initial_setup"
    private let hasCompletedPhotoPermissionKey = "immich_has_completed_photo_permission"
    private let allowCellularBackgroundUploadKey = "immich_allow_cellular_background_upload"
    static let syncApplePhotosAlbumsKey = "immich_sync_apple_photos_albums"
    init(preferences: UserDefaults = .standard, credentialStore: CredentialStorage = SystemKeychainCredentialStore()) {
        self.preferences = preferences
        self.credentialStore = credentialStore
        loadSettings()
    }
    
    private func loadSettings() {
        serverURL = preferences.string(forKey: serverURLKey) ?? ""
        internalServerURL = preferences.string(forKey: internalServerURLKey) ?? ""
        internalNetworkSSID = preferences.string(forKey: internalNetworkSSIDKey) ?? ""
        let credential = credentialStore.load()
        apiKey = credential.value ?? ""
        let savedLoginFlag = preferences.bool(forKey: Self.isLoggedInKey)
        isLoggedIn = savedLoginFlag
        hasCompletedOnboarding = preferences.bool(forKey: hasCompletedOnboardingKey)
        hasCompletedInitialSetup = preferences.bool(forKey: hasCompletedInitialSetupKey)
        hasCompletedPhotoPermission = preferences.bool(forKey: hasCompletedPhotoPermissionKey)
        allowCellularBackgroundUpload = preferences.object(forKey: allowCellularBackgroundUploadKey) as? Bool ?? true
        syncApplePhotosAlbums = preferences.bool(forKey: Self.syncApplePhotosAlbumsKey)

        // A transient Keychain read failure must not permanently erase the saved
        // login flag. A future app launch can retry accessing the credential.
        if savedLoginFlag {
            logInfo(
                "Auth restore: savedLogin=true, serverConfigured=\(!serverURL.isEmpty), credentialPresent=\(!apiKey.isEmpty), keychainStatus=\(credential.status)",
                category: .app
            )
            if serverURL.isEmpty || apiKey.isEmpty {
                isLoggedIn = false
                let reason = serverURL.isEmpty ? "missing_server_url"
                    : credential.status == errSecItemNotFound ? "credential_not_found" : "credential_unavailable"
                logWarning(
                    "Auth restore unavailable: reason=\(reason), keychainStatus=\(credential.status), savedLoginPreserved=true",
                    category: .app
                )
            }
        } else {
            logDebug("Auth restore: savedLogin=false, keychainStatus=\(credential.status)", category: .app)
        }
        
        if !internalNetworkSSID.isEmpty {
            NetworkReachability.shared.configure(ssid: internalNetworkSSID)
        }
    }
    
    private func saveSettings() {
        preferences.set(serverURL, forKey: serverURLKey)
        preferences.set(internalServerURL, forKey: internalServerURLKey)
        preferences.set(internalNetworkSSID, forKey: internalNetworkSSIDKey)
        preferences.set(isLoggedIn, forKey: Self.isLoggedInKey)
        preferences.set(hasCompletedOnboarding, forKey: hasCompletedOnboardingKey)
        preferences.set(hasCompletedInitialSetup, forKey: hasCompletedInitialSetupKey)
        preferences.set(hasCompletedPhotoPermission, forKey: hasCompletedPhotoPermissionKey)
        preferences.set(allowCellularBackgroundUpload, forKey: allowCellularBackgroundUploadKey)
        preferences.set(syncApplePhotosAlbums, forKey: Self.syncApplePhotosAlbumsKey)
    }
    
    var activeServerURL: String {
        return NetworkReachability.shared.resolveServerURL(
            externalURL: serverURL,
            internalURL: internalServerURL.isEmpty ? nil : internalServerURL,
            ssid: internalNetworkSSID.isEmpty ? nil : internalNetworkSSID
        )
    }
    
    func login(serverURL: String, apiKey: String, internalServerURL: String? = nil, ssid: String? = nil) throws {
        let keychainStatus = credentialStore.save(apiKey)
        guard keychainStatus == errSecSuccess else {
            logError("Auth login: credential save failed, keychainStatus=\(keychainStatus)", category: .app)
            throw CredentialPersistenceError.saveFailed(keychainStatus)
        }
        logInfo("Auth login: credential saved, keychainStatus=\(keychainStatus)", category: .app)
        AlbumSyncService.invalidateInFlightSync()
        self.serverURL = serverURL
        self.internalServerURL = internalServerURL ?? ""
        self.internalNetworkSSID = ssid ?? ""
        self.apiKey = apiKey
        self.isLoggedIn = true
        self.hasCompletedOnboarding = false
        self.hasCompletedInitialSetup = false
        self.hasCompletedPhotoPermission = false

        if let ssid = ssid, !ssid.isEmpty {
            NetworkReachability.shared.configure(ssid: ssid)
        }

        saveSettings()
        syncToSharedSettings()
        scheduleAlbumSyncIfEnabled()
    }

    func updateServerURL(_ url: String) {
        guard url != self.serverURL else { return }
        AlbumSyncService.invalidateInFlightSync()
        self.serverURL = url
        preferences.set(url, forKey: serverURLKey)
        syncToSharedSettings()
        scheduleAlbumSyncIfEnabled()
    }

    func updateInternalNetworkSettings(url: String, ssid: String) {
        guard url != self.internalServerURL || ssid != self.internalNetworkSSID else { return }
        AlbumSyncService.invalidateInFlightSync()
        self.internalServerURL = url
        self.internalNetworkSSID = ssid

        preferences.set(url, forKey: internalServerURLKey)
        preferences.set(ssid, forKey: internalNetworkSSIDKey)

        NetworkReachability.shared.configure(ssid: ssid.isEmpty ? nil : ssid)

        syncToSharedSettings()
        scheduleAlbumSyncIfEnabled()
    }

    func updateAllowCellularBackgroundUpload(_ allowed: Bool) {
        allowCellularBackgroundUpload = allowed
        preferences.set(allowed, forKey: allowCellularBackgroundUploadKey)
        syncToSharedSettings()
    }

    private func scheduleAlbumSyncIfEnabled() {
        guard isLoggedIn, syncApplePhotosAlbums else { return }
        Task { await AlbumSyncService.shared.syncIfEnabled() }
    }

    func updateSyncApplePhotosAlbums(_ enabled: Bool) {
        guard syncApplePhotosAlbums != enabled else { return }
        AlbumSyncService.invalidateInFlightSync()
        syncApplePhotosAlbums = enabled
        preferences.set(enabled, forKey: Self.syncApplePhotosAlbumsKey)
        if enabled {
            scheduleAlbumSyncIfEnabled()
        }
    }

    
    private func syncToSharedSettings() {
        if #available(iOS 26.1, *) {
            BackgroundUploadManager.shared.syncSettings(
                serverURL: serverURL,
                apiKey: apiKey,
                internalServerURL: internalServerURL.isEmpty ? nil : internalServerURL,
                ssid: internalNetworkSSID.isEmpty ? nil : internalNetworkSSID,
                allowCellular: allowCellularBackgroundUpload
            )
        } else {
            SharedSettings.shared.syncFromMainApp(
                serverURL: serverURL,
                apiKey: apiKey,
                isLoggedIn: true,
                internalServerURL: internalServerURL.isEmpty ? nil : internalServerURL,
                ssid: internalNetworkSSID.isEmpty ? nil : internalNetworkSSID,
                allowCellular: allowCellularBackgroundUpload
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

    func completePhotoPermission() {
        self.hasCompletedPhotoPermission = true
        saveSettings()
    }

    func logout() {
        logInfo("Auth logout: explicitly invoked", category: .app)
        AlbumSyncService.invalidateInFlightSync()
        self.serverURL = ""
        self.internalServerURL = ""
        self.internalNetworkSSID = ""
        self.apiKey = ""
        self.isLoggedIn = false
        self.allowCellularBackgroundUpload = true
        self.syncApplePhotosAlbums = false
        
        preferences.removeObject(forKey: serverURLKey)
        preferences.removeObject(forKey: internalServerURLKey)
        preferences.removeObject(forKey: internalNetworkSSIDKey)
        preferences.removeObject(forKey: Self.isLoggedInKey)
        preferences.removeObject(forKey: allowCellularBackgroundUploadKey)
        preferences.removeObject(forKey: Self.syncApplePhotosAlbumsKey)
        let keychainStatus = credentialStore.delete()
        if keychainStatus != errSecSuccess && keychainStatus != errSecItemNotFound {
            logWarning("Auth logout: credential delete failed, keychainStatus=\(keychainStatus)", category: .app)
        }

        // Clear SharedSettings and disable background upload
        if #available(iOS 26.1, *) {
            Task {
                await BackgroundUploadManager.shared.handleLogout()
            }
        } else {
            SharedSettings.shared.clearAll()
        }
    }
    
}

// Isolated for deterministic restore and persistence-error tests.
struct StoredCredential {
    let value: String?
    let status: OSStatus
}

protocol CredentialStorage {
    func load() -> StoredCredential
    func save(_ value: String) -> OSStatus
    func delete() -> OSStatus
}

struct SystemKeychainCredentialStore: CredentialStorage {
    private let service = "com.fawenyo.yaiiu"
    private let account = "api_key"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func load() -> StoredCredential {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        guard status == errSecSuccess else {
            return StoredCredential(value: nil, status: status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return StoredCredential(value: nil, status: errSecDecode)
        }
        return StoredCredential(value: value, status: status)
    }

    func save(_ value: String) -> OSStatus {
        let data = Data(value.utf8)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            return SecItemAdd(item as CFDictionary, nil)
        }
        // Never delete the previous credential before a successful replacement.
        return status
    }

    func delete() -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}
