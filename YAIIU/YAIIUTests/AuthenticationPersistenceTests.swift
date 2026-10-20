import Security
import XCTest
@testable import YAIIU

final class AuthenticationPersistenceTests: XCTestCase {
    private var testSuiteNames: [String] = []

    override func tearDown() {
        for suite in testSuiteNames {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        super.tearDown()
    }

    func testExistingCredentialRestoresLogin() {
        let defaults = makeDefaults(loggedIn: true, serverURL: "https://immich.example")
        let store = StubCredentialStorage(value: "existing-token")
        let settings = SettingsManager(preferences: defaults, credentialStore: store)

        XCTAssertTrue(settings.isLoggedIn)
        XCTAssertEqual(settings.apiKey, "existing-token")
        XCTAssertEqual(store.saveCount, 0)
    }

    func testTemporaryKeychainFailureDoesNotEraseSavedLogin() {
        let defaults = makeDefaults(loggedIn: true, serverURL: "https://immich.example")
        let store = StubCredentialStorage(value: nil, readStatus: errSecInteractionNotAllowed)
        let settings = SettingsManager(preferences: defaults, credentialStore: store)

        XCTAssertFalse(settings.isLoggedIn)
        XCTAssertTrue(defaults.bool(forKey: SettingsManager.isLoggedInKey))
        XCTAssertEqual(store.saveCount, 0)
    }

    func testMissingKeychainItemDoesNotEraseSavedLogin() {
        let defaults = makeDefaults(loggedIn: true, serverURL: "https://immich.example")
        let store = StubCredentialStorage(value: nil, readStatus: errSecItemNotFound)
        let settings = SettingsManager(preferences: defaults, credentialStore: store)

        XCTAssertFalse(settings.isLoggedIn)
        XCTAssertTrue(defaults.bool(forKey: SettingsManager.isLoggedInKey))
    }

    func testMissingServerURLDoesNotEraseSavedLogin() {
        let defaults = makeDefaults(loggedIn: true, serverURL: "")
        let store = StubCredentialStorage(value: "existing-token")
        let settings = SettingsManager(preferences: defaults, credentialStore: store)

        XCTAssertFalse(settings.isLoggedIn)
        XCTAssertTrue(defaults.bool(forKey: SettingsManager.isLoggedInKey))
    }

    func testSavingUnrelatedSettingsDoesNotRewriteCredential() {
        let defaults = makeDefaults(loggedIn: true, serverURL: "https://immich.example")
        let store = StubCredentialStorage(value: "existing-token")
        let settings = SettingsManager(preferences: defaults, credentialStore: store)

        settings.completeInitialSetup()
        settings.completeOnboarding()
        settings.completePhotoPermission()

        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(settings.apiKey, "existing-token")
        XCTAssertTrue(defaults.bool(forKey: SettingsManager.isLoggedInKey))
    }

    func testFailedCredentialSaveDoesNotChangeLoggedInState() {
        let defaults = makeDefaults(loggedIn: false, serverURL: "")
        let store = StubCredentialStorage(
            value: nil,
            readStatus: errSecItemNotFound,
            saveStatus: errSecInteractionNotAllowed
        )
        let settings = SettingsManager(preferences: defaults, credentialStore: store)

        XCTAssertThrowsError(try settings.login(
            serverURL: "https://immich.example",
            apiKey: "new-token"
        )) { error in
            guard case SettingsManager.CredentialPersistenceError.saveFailed(errSecInteractionNotAllowed) = error else {
                return XCTFail("Expected the Keychain error to propagate")
            }
        }

        XCTAssertFalse(settings.isLoggedIn)
        XCTAssertFalse(defaults.bool(forKey: SettingsManager.isLoggedInKey))
        XCTAssertTrue(settings.serverURL.isEmpty)
        XCTAssertEqual(store.saveCount, 1)
    }

    private func makeDefaults(loggedIn: Bool, serverURL: String) -> UserDefaults {
        let suite = "com.fawenyo.yaiiu.auth-tests.\(UUID().uuidString)"
        testSuiteNames.append(suite)
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not create isolated UserDefaults")
        }
        defaults.removePersistentDomain(forName: suite)
        defaults.set(loggedIn, forKey: SettingsManager.isLoggedInKey)
        defaults.set(serverURL, forKey: "immich_server_url")
        return defaults
    }
}

private final class StubCredentialStorage: CredentialStorage {
    let value: String?
    let readStatus: OSStatus
    let saveStatus: OSStatus
    private(set) var saveCount = 0

    init(value: String?, readStatus: OSStatus = errSecSuccess, saveStatus: OSStatus = errSecSuccess) {
        self.value = value
        self.readStatus = readStatus
        self.saveStatus = saveStatus
    }

    func load() -> StoredCredential {
        StoredCredential(value: readStatus == errSecSuccess ? value : nil, status: readStatus)
    }

    func save(_ value: String) -> OSStatus {
        saveCount += 1
        return saveStatus
    }

    func delete() -> OSStatus {
        errSecSuccess
    }
}
