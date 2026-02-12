import Foundation
import SwiftUI

// MARK: - Supported Languages
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case english = "en"
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case german = "de"
    case french = "fr"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .system:
            return "language.system".localized
        case .english:
            return "English"
        case .traditionalChinese:
            return "繁體中文"
        case .simplifiedChinese:
            return "简体中文"
        case .japanese:
            return "日本語"
        case .korean:
            return "한국어"
        case .spanish:
            return "Español"
        case .german:
            return "Deutsch"
        case .french:
            return "Français"
        }
    }
    
    var localeIdentifier: String? {
        switch self {
        case .system:
            return nil
        default:
            return rawValue
        }
    }
}

// MARK: - Language Manager
@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()
    
    private static let languageKey = "app_language"
    
    @Published private(set) var currentLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: Self.languageKey)
            updateBundle()
        }
    }
    
    nonisolated(unsafe) private let bundleLock = NSLock()
    nonisolated(unsafe) private var _bundle: Bundle = .main
    nonisolated private(set) var bundle: Bundle {
        get {
            bundleLock.withLock { _bundle }
        }
        set {
            bundleLock.withLock { _bundle = newValue }
        }
    }
    
    private init() {
        if let stored = UserDefaults.standard.string(forKey: Self.languageKey),
           let language = AppLanguage(rawValue: stored) {
            self.currentLanguage = language
        } else {
            self.currentLanguage = .system
        }
        updateBundle()
    }
    
    var currentLanguageCode: String {
        if currentLanguage == .system {
            return Bundle.main.preferredLocalizations.first ?? "en"
        }
        return currentLanguage.rawValue
    }
    
    func setLanguage(_ language: AppLanguage) {
        guard language != currentLanguage else { return }
        currentLanguage = language
    }
    
    private func updateBundle() {
        if currentLanguage == .system {
            self.bundle = .main
            return
        }

        let languageCode = currentLanguage.rawValue
        if let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            self.bundle = bundle
        } else {
            self.bundle = .main
        }
    }
}

// MARK: - String Localization Extension
extension String {
    /// Returns a localized string using the current app language
    var localized: String {
        let customBundle = LanguageManager.shared.bundle
        let localizedString = NSLocalizedString(self, bundle: customBundle, comment: "")
        
        // Fallback to English (base) bundle if a translation is missing in the custom bundle
        if localizedString == self && customBundle != .main {
            if let enPath = Bundle.main.path(forResource: "en", ofType: "lproj"),
               let enBundle = Bundle(path: enPath) {
                return NSLocalizedString(self, bundle: enBundle, comment: "")
            }
        }
        
        return localizedString
    }
    
    /// Returns a localized string with format arguments
    func localized(with arguments: CVarArg...) -> String {
        return String(format: self.localized, arguments: arguments)
    }
}

// MARK: - Localization Keys
/// Centralized localization keys for type-safe access
enum L10n {
    // MARK: - Tab Items
    enum Tab {
        static var photos: String { "tab.photos".localized }
        static var upload: String { "tab.upload".localized }
        static var settings: String { "tab.settings".localized }
    }
    
    // MARK: - Login
    enum Login {
        static var title: String { "login.title".localized }
        static var subtitle: String { "login.subtitle".localized }
        static var serverURL: String { "login.serverURL".localized }
        static var serverURLPlaceholder: String { "login.serverURL.placeholder".localized }
        static var internalServerURL: String { "login.internalServerURL".localized }
        static var internalServerURLPlaceholder: String { "login.internalServerURL.placeholder".localized }
        static var internalServerURLHint: String { "login.internalServerURL.hint".localized }
        static var advancedSettings: String { "login.advancedSettings".localized }
        static var apiKey: String { "login.apiKey".localized }
        static var apiKeyPlaceholder: String { "login.apiKey.placeholder".localized }
        static var button: String { "login.button".localized }
        static var buttonConnecting: String { "login.button.connecting".localized }
        static var errorTitle: String { "login.error.title".localized }
        static var errorInvalidApiKey: String { "login.error.invalidApiKey".localized }
        static func errorConnectionFailed(_ error: String) -> String {
            return "login.error.connectionFailed".localized(with: error)
        }
        static var errorOk: String { "login.error.ok".localized }
        static var backgroundUploadNoteTitle: String { "login.backgroundUploadNote.title".localized }
        static var backgroundUploadNoteMessage: String { "login.backgroundUploadNote.message".localized }
        static var backgroundUploadNoteLearnMore: String { "login.backgroundUploadNote.learnMore".localized }
        static var backgroundUploadNoteLink: String { "login.backgroundUploadNote.link".localized }
    }
    
    // MARK: - Settings
    enum Settings {
        static var title: String { "settings.title".localized }
        static var serverInfo: String { "settings.serverInfo".localized }
        static var serverURL: String { "settings.serverURL".localized }
        static var networkSettings: String { "settings.networkSettings".localized }
        static var currentStatus: String { "settings.currentStatus".localized }
        static var externalServerURL: String { "settings.externalServerURL".localized }
        static var externalServerURLPlaceholder: String { "settings.externalServerURL.placeholder".localized }
        static var externalServerURLHint: String { "settings.externalServerURL.hint".localized }
        static var internalServerURL: String { "settings.internalServerURL".localized }
        static var internalServerURLPlaceholder: String { "settings.internalServerURL.placeholder".localized }
        static var internalServerURLHint: String { "settings.internalServerURL.hint".localized }
        static var internalNetworkSettings: String { "settings.internalNetworkSettings".localized }
        static var notConfigured: String { "settings.notConfigured".localized }
        static var edit: String { "settings.edit".localized }
        static var save: String { "settings.save".localized }
        static var cancel: String { "settings.cancel".localized }
        static var apiKey: String { "settings.apiKey".localized }
        static var wifiSSID: String { "settings.wifiSSID".localized }
        static var wifiSSIDPlaceholder: String { "settings.wifiSSID.placeholder".localized }
        static var wifiSSIDHint: String { "settings.wifiSSID.hint".localized }
        static var wifiNotDetected: String { "settings.wifiNotDetected".localized }
        static var useCurrentWiFi: String { "settings.useCurrentWiFi".localized }
        static var clearInternalNetwork: String { "settings.clearInternalNetwork".localized }
        static var locationPermissionRequired: String { "settings.locationPermissionRequired".localized }
        static var locationPermissionHint: String { "settings.locationPermissionHint".localized }
        static var grantLocationPermission: String { "settings.grantLocationPermission".localized }
        static var preciseLocationRequired: String { "settings.preciseLocationRequired".localized }
        static var preciseLocationHint: String { "settings.preciseLocationHint".localized }
        static var openSettings: String { "settings.openSettings".localized }
        static var usingInternalNetwork: String { "settings.usingInternalNetwork".localized }
        static var usingExternalNetwork: String { "settings.usingExternalNetwork".localized }
        static var statistics: String { "settings.statistics".localized }
        static var uploadedCount: String { "settings.uploadedCount".localized }
        static var cachedHashCount: String { "settings.cachedHashCount".localized }
        static var confirmedOnCloud: String { "settings.confirmedOnCloud".localized }
        static var dataManagement: String { "settings.dataManagement".localized }
        static var importImmichData: String { "settings.importImmichData".localized }
        static var logout: String { "settings.logout".localized }
        static var logoutConfirmTitle: String { "settings.logout.confirm.title".localized }
        static var logoutConfirmMessage: String { "settings.logout.confirm.message".localized }
        static var logoutCancel: String { "settings.logout.cancel".localized }
        static var logs: String { "settings.logs".localized }
        static var logCount: String { "settings.logCount".localized }
        static var logFileSize: String { "settings.logFileSize".localized }
        static var viewLogs: String { "settings.viewLogs".localized }
        static var exportLogs: String { "settings.exportLogs".localized }
        static var clearLogs: String { "settings.clearLogs".localized }
        static var clearLogsConfirmTitle: String { "settings.clearLogs.confirm.title".localized }
        static var clearLogsConfirmMessage: String { "settings.clearLogs.confirm.message".localized }
        static var clearLogsCancel: String { "settings.clearLogs.cancel".localized }
        static var appVersion: String { "settings.appVersion".localized }
        static var searchLogs: String { "settings.searchLogs".localized }
        static var filterAll: String { "settings.filterAll".localized }
        static var refreshLogs: String { "settings.refreshLogs".localized }
        static var scrollToBottom: String { "settings.scrollToBottom".localized }
        static var noLogsAvailable: String { "settings.noLogsAvailable".localized }
        static var language: String { "settings.language".localized }
        static var languageSection: String { "settings.languageSection".localized }
        static var currentLanguage: String { "settings.currentLanguage".localized }
        static var changeLanguage: String { "settings.changeLanguage".localized }
        static var systemDefault: String { "settings.systemDefault".localized }
    }
    
    // MARK: - Photo Grid
    enum PhotoGrid {
        static var title: String { "photoGrid.title".localized }
        static var select: String { "photoGrid.select".localized }
        static var cancel: String { "photoGrid.cancel".localized }
        static func upload(_ count: Int) -> String {
            return "photoGrid.upload".localized(with: count)
        }
        static var confirmTitle: String { "photoGrid.confirm.title".localized }
        static func confirmMessage(_ count: Int) -> String {
            return "photoGrid.confirm.message".localized(with: count)
        }
        static var confirmCancel: String { "photoGrid.confirm.cancel".localized }
        static var confirmUpload: String { "photoGrid.confirm.upload".localized }
        static var processingPreparing: String { "photoGrid.processing.preparing".localized }
        static func processingComparing(_ current: Int, _ total: Int) -> String {
            return "photoGrid.processing.comparing".localized(with: current, total)
        }
        static var processingChecking: String { "photoGrid.processing.checking".localized }
        static var processingDefault: String { "photoGrid.processing.default".localized }
        static var permissionTitle: String { "photoGrid.permission.title".localized }
        static var permissionMessage: String { "photoGrid.permission.message".localized }
        static var permissionGrant: String { "photoGrid.permission.grant".localized }
        static var permissionDeniedTitle: String { "photoGrid.permission.denied.title".localized }
        static var permissionDeniedMessage: String { "photoGrid.permission.denied.message".localized }
        static var permissionOpenSettings: String { "photoGrid.permission.openSettings".localized }
        static var filterAll: String { "photoGrid.filter.all".localized }
        static var filterNotUploaded: String { "photoGrid.filter.notUploaded".localized }
        static func filterActive(_ count: Int) -> String {
            return "photoGrid.filter.active".localized(with: count)
        }
        static var sectionToday: String { "photoGrid.section.today".localized }
        static var sectionYesterday: String { "photoGrid.section.yesterday".localized }
    }
    
    // MARK: - Upload Progress
    enum UploadProgress {
        static var title: String { "uploadProgress.title".localized }
        static var pause: String { "uploadProgress.pause".localized }
        static var resume: String { "uploadProgress.resume".localized }
        static var emptyTitle: String { "uploadProgress.empty.title".localized }
        static var emptyMessage: String { "uploadProgress.empty.message".localized }
        static func emptySuccess(_ count: Int) -> String {
            return "uploadProgress.empty.success".localized(with: count)
        }
        static var overall: String { "uploadProgress.overall".localized }
        static var uploading: String { "uploadProgress.uploading".localized }
        static var paused: String { "uploadProgress.paused".localized }
        static func files(_ current: Int, _ total: Int) -> String {
            return "uploadProgress.files".localized(with: current, total)
        }
        static func fileCount(_ count: Int) -> String {
            return "uploadProgress.fileCount".localized(with: count)
        }
        static var video: String { "uploadProgress.video".localized }
    }
    
    // MARK: - Upload Status
    enum UploadStatus {
        static var pending: String { "uploadStatus.pending".localized }
        static func uploading(_ percent: Int) -> String {
            return "uploadStatus.uploading".localized(with: percent)
        }
        static var processing: String { "uploadStatus.processing".localized }
        static var completed: String { "uploadStatus.completed".localized }
        static var failed: String { "uploadStatus.failed".localized }
    }
    
    // MARK: - Import
    enum Import {
        static var title: String { "import.title".localized }
        static var cancel: String { "import.cancel".localized }
        static var done: String { "import.done".localized }
        static var instructionTitle: String { "import.instruction.title".localized }
        static var instructionDescription: String { "import.instruction.description".localized }
        static var instructionStep1: String { "import.instruction.step1".localized }
        static var instructionStep2: String { "import.instruction.step2".localized }
        static var instructionStep3: String { "import.instruction.step3".localized }
        static var selectFile: String { "import.selectFile".localized }
        static var reselectFile: String { "import.reselectFile".localized }
        static var validationSuccess: String { "import.validation.success".localized }
        static var validationFailed: String { "import.validation.failed".localized }
        static var validationRecordCount: String { "import.validation.recordCount".localized }
        static func validationRecords(_ count: Int) -> String {
            return "import.validation.records".localized(with: count)
        }
        static var statisticsTitle: String { "import.statistics.title".localized }
        static var statisticsTotalAssets: String { "import.statistics.totalAssets".localized }
        static var statisticsAssetsWithHash: String { "import.statistics.assetsWithHash".localized }
        static var statisticsImageCount: String { "import.statistics.imageCount".localized }
        static var statisticsVideoCount: String { "import.statistics.videoCount".localized }
        static var statisticsServerSync: String { "import.statistics.serverSync".localized }
        static var statisticsRemoteAssets: String { "import.statistics.remoteAssets".localized }
        static var statisticsLocalSynced: String { "import.statistics.localSynced".localized }
        static var importButton: String { "import.import.button".localized }
        static var importImporting: String { "import.import.importing".localized }
        static func importProgress(_ current: Int, _ total: Int) -> String {
            return "import.import.progress".localized(with: current, total)
        }
        static var resultSuccess: String { "import.result.success".localized }
        static var resultError: String { "import.result.error".localized }
        static var resultTotalRecords: String { "import.result.totalRecords".localized }
        static var resultImportedRecords: String { "import.result.importedRecords".localized }
        static var resultAlreadyOnServer: String { "import.result.alreadyOnServer".localized }
        static var resultSkippedRecords: String { "import.result.skippedRecords".localized }
        static var resultTip: String { "import.result.tip".localized }
        static var alertOk: String { "import.alert.ok".localized }
        static var alertImportFailed: String { "import.alert.importFailed".localized }
    }
    
    // MARK: - Onboarding
    enum Onboarding {
        static var title: String { "onboarding.title".localized }
        static var description: String { "onboarding.description".localized }
        static var importButton: String { "onboarding.import.button".localized }
        static var importDescription: String { "onboarding.import.description".localized }
        static var skip: String { "onboarding.skip".localized }
        static var continue_: String { "onboarding.continue".localized }
        static var changeFile: String { "onboarding.changeFile".localized }
        static func validationSuccess(_ count: Int) -> String {
            return "onboarding.validation.success".localized(with: count)
        }
        static var startImport: String { "onboarding.startImport".localized }
    }
    
    // MARK: - Initial Setup
    enum InitialSetup {
        static var title: String { "initialSetup.title".localized }
        static var description: String { "initialSetup.description".localized }
        static var syncing: String { "initialSetup.syncing".localized }
        static var syncingDescription: String { "initialSetup.syncingDescription".localized }
        static var completed: String { "initialSetup.completed".localized }
        static var completedDescription: String { "initialSetup.completedDescription".localized }
        static var failed: String { "initialSetup.failed".localized }
        static var failedDescription: String { "initialSetup.failedDescription".localized }
        static var syncedAssets: String { "initialSetup.syncedAssets".localized }
        static var continue_: String { "initialSetup.continue".localized }
        static var retry: String { "initialSetup.retry".localized }
        static var skip: String { "initialSetup.skip".localized }
        static func fetchedAssets(_ count: Int) -> String {
            return "initialSetup.fetchedAssets".localized(with: count)
        }
        static var phaseConnecting: String { "initialSetup.phase.connecting".localized }
        static var phaseFetchingUserInfo: String { "initialSetup.phase.fetchingUserInfo".localized }
        static var phaseFetchingPartners: String { "initialSetup.phase.fetchingPartners".localized }
        static func phaseFetchingAssets(_ count: Int) -> String {
            return "initialSetup.phase.fetchingAssets".localized(with: count)
        }
        static var phaseFetchingAssetsInitial: String { "initialSetup.phase.fetchingAssetsInitial".localized }
        static func phaseProcessingAssets(_ count: Int) -> String {
            return "initialSetup.phase.processingAssets".localized(with: count)
        }
        static var phaseSavingToDatabase: String { "initialSetup.phase.savingToDatabase".localized }
    }
    
    // MARK: - Restart Required
    enum RestartRequired {
        static var title: String { "restartRequired.title".localized }
        static var description: String { "restartRequired.description".localized }
        static var instructions: String { "restartRequired.instructions".localized }
        static var closeApp: String { "restartRequired.closeApp".localized }
    }
    
    // MARK: - Background Upload (iOS 26.1+)
    enum BackgroundUpload {
        static var title: String { "backgroundUpload.title".localized }
        static var settingsTitle: String { "backgroundUpload.settingsTitle".localized }
        static var enabled: String { "backgroundUpload.enabled".localized }
        static var disabled: String { "backgroundUpload.disabled".localized }
        static var description: String { "backgroundUpload.description".localized }
        static var requiresIOS26: String { "backgroundUpload.requiresIOS26".localized }
        static var sectionAutoUpload: String { "backgroundUpload.section.autoUpload".localized }
        static var sectionStatistics: String { "backgroundUpload.section.statistics".localized }
        static var sectionDebug: String { "backgroundUpload.section.debug".localized }
        static var uploadedCount: String { "backgroundUpload.uploadedCount".localized }
        static var pendingCount: String { "backgroundUpload.pendingCount".localized }
        static var viewLogs: String { "backgroundUpload.viewLogs".localized }
        static var clearLogs: String { "backgroundUpload.clearLogs".localized }
        static var logsTitle: String { "backgroundUpload.logsTitle".localized }
        static var noLogs: String { "backgroundUpload.noLogs".localized }
        static var notSupported: String { "backgroundUpload.notSupported".localized }
        static var errorPhotoLibraryNotAuthorized: String { "backgroundUpload.error.photoLibraryNotAuthorized".localized }
        static var errorNotLoggedIn: String { "backgroundUpload.error.notLoggedIn".localized }
        static var errorExtensionNotAvailable: String { "backgroundUpload.error.extensionNotAvailable".localized }
    }
    
    // MARK: - Photo Detail
    enum PhotoDetail {
        static var fileNameUnknown: String { "photoDetail.fileNameUnknown".localized }
        static var openInMaps: String { "photoDetail.openInMaps".localized }
        static var previewRequiresAssets: String { "photoDetail.previewRequiresAssets".localized }
    }
    
    // MARK: - iCloud ID Sync
    enum CloudIdSync {
        static var title: String { "cloudIdSync.title".localized }
        static var description: String { "cloudIdSync.description".localized }
        static var button: String { "cloudIdSync.button".localized }
        static var syncing: String { "cloudIdSync.syncing".localized }
        static var completed: String { "cloudIdSync.completed".localized }
        static func success(_ count: Int) -> String {
            return "cloudIdSync.success".localized(with: count)
        }
        static func error(_ message: String) -> String {
            return "cloudIdSync.error".localized(with: message)
        }
        static var requiresIOS16: String { "cloudIdSync.requiresIOS16".localized }
    }
}
