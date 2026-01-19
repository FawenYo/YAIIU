import Foundation

// MARK: - String Localization Extension
extension String {
    /// Returns a localized string using the key
    var localized: String {
        return NSLocalizedString(self, comment: "")
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
        static let photos = "tab.photos".localized
        static let upload = "tab.upload".localized
        static let settings = "tab.settings".localized
    }
    
    // MARK: - Login
    enum Login {
        static let title = "login.title".localized
        static let subtitle = "login.subtitle".localized
        static let serverURL = "login.serverURL".localized
        static let serverURLPlaceholder = "login.serverURL.placeholder".localized
        static let internalServerURL = "login.internalServerURL".localized
        static let internalServerURLPlaceholder = "login.internalServerURL.placeholder".localized
        static let internalServerURLHint = "login.internalServerURL.hint".localized
        static let advancedSettings = "login.advancedSettings".localized
        static let apiKey = "login.apiKey".localized
        static let apiKeyPlaceholder = "login.apiKey.placeholder".localized
        static let button = "login.button".localized
        static let buttonConnecting = "login.button.connecting".localized
        static let errorTitle = "login.error.title".localized
        static let errorInvalidApiKey = "login.error.invalidApiKey".localized
        static func errorConnectionFailed(_ error: String) -> String {
            return "login.error.connectionFailed".localized(with: error)
        }
        static let errorOk = "login.error.ok".localized
        // Background Upload Note (iOS 26.1+)
        static let backgroundUploadNoteTitle = "login.backgroundUploadNote.title".localized
        static let backgroundUploadNoteMessage = "login.backgroundUploadNote.message".localized
        static let backgroundUploadNoteLearnMore = "login.backgroundUploadNote.learnMore".localized
        static let backgroundUploadNoteLink = "login.backgroundUploadNote.link".localized
    }
    
    // MARK: - Settings
    enum Settings {
        static let title = "settings.title".localized
        static let serverInfo = "settings.serverInfo".localized
        static let serverURL = "settings.serverURL".localized
        static let networkSettings = "settings.networkSettings".localized
        static let currentStatus = "settings.currentStatus".localized
        static let externalServerURL = "settings.externalServerURL".localized
        static let externalServerURLPlaceholder = "settings.externalServerURL.placeholder".localized
        static let externalServerURLHint = "settings.externalServerURL.hint".localized
        static let internalServerURL = "settings.internalServerURL".localized
        static let internalServerURLPlaceholder = "settings.internalServerURL.placeholder".localized
        static let internalServerURLHint = "settings.internalServerURL.hint".localized
        static let internalNetworkSettings = "settings.internalNetworkSettings".localized
        static let notConfigured = "settings.notConfigured".localized
        static let edit = "settings.edit".localized
        static let save = "settings.save".localized
        static let cancel = "settings.cancel".localized
        static let apiKey = "settings.apiKey".localized
        static let wifiSSID = "settings.wifiSSID".localized
        static let wifiSSIDPlaceholder = "settings.wifiSSID.placeholder".localized
        static let wifiSSIDHint = "settings.wifiSSID.hint".localized
        static let wifiNotDetected = "settings.wifiNotDetected".localized
        static let useCurrentWiFi = "settings.useCurrentWiFi".localized
        static let clearInternalNetwork = "settings.clearInternalNetwork".localized
        static let locationPermissionRequired = "settings.locationPermissionRequired".localized
        static let locationPermissionHint = "settings.locationPermissionHint".localized
        static let grantLocationPermission = "settings.grantLocationPermission".localized
        static let preciseLocationRequired = "settings.preciseLocationRequired".localized
        static let preciseLocationHint = "settings.preciseLocationHint".localized
        static let openSettings = "settings.openSettings".localized
        static let usingInternalNetwork = "settings.usingInternalNetwork".localized
        static let usingExternalNetwork = "settings.usingExternalNetwork".localized
        static let statistics = "settings.statistics".localized
        static let uploadedCount = "settings.uploadedCount".localized
        static let cachedHashCount = "settings.cachedHashCount".localized
        static let confirmedOnCloud = "settings.confirmedOnCloud".localized
        static let dataManagement = "settings.dataManagement".localized
        static let importImmichData = "settings.importImmichData".localized
        static let logout = "settings.logout".localized
        static let logoutConfirmTitle = "settings.logout.confirm.title".localized
        static let logoutConfirmMessage = "settings.logout.confirm.message".localized
        static let logoutCancel = "settings.logout.cancel".localized
        // Logs
        static let logs = "settings.logs".localized
        static let logCount = "settings.logCount".localized
        static let logFileSize = "settings.logFileSize".localized
        static let viewLogs = "settings.viewLogs".localized
        static let exportLogs = "settings.exportLogs".localized
        static let clearLogs = "settings.clearLogs".localized
        static let clearLogsConfirmTitle = "settings.clearLogs.confirm.title".localized
        static let clearLogsConfirmMessage = "settings.clearLogs.confirm.message".localized
        static let clearLogsCancel = "settings.clearLogs.cancel".localized
        static let searchLogs = "settings.searchLogs".localized
        static let filterAll = "settings.filterAll".localized
        static let refreshLogs = "settings.refreshLogs".localized
        static let scrollToBottom = "settings.scrollToBottom".localized
        static let noLogsAvailable = "settings.noLogsAvailable".localized
    }
    
    // MARK: - Photo Grid
    enum PhotoGrid {
        static let title = "photoGrid.title".localized
        static let select = "photoGrid.select".localized
        static let cancel = "photoGrid.cancel".localized
        static func upload(_ count: Int) -> String {
            return "photoGrid.upload".localized(with: count)
        }
        static let confirmTitle = "photoGrid.confirm.title".localized
        static func confirmMessage(_ count: Int) -> String {
            return "photoGrid.confirm.message".localized(with: count)
        }
        static let confirmCancel = "photoGrid.confirm.cancel".localized
        static let confirmUpload = "photoGrid.confirm.upload".localized
        static let processingPreparing = "photoGrid.processing.preparing".localized
        static func processingComparing(_ current: Int, _ total: Int) -> String {
            return "photoGrid.processing.comparing".localized(with: current, total)
        }
        static let processingChecking = "photoGrid.processing.checking".localized
        static let processingDefault = "photoGrid.processing.default".localized
        static let permissionTitle = "photoGrid.permission.title".localized
        static let permissionMessage = "photoGrid.permission.message".localized
        static let permissionGrant = "photoGrid.permission.grant".localized
        static let permissionDeniedTitle = "photoGrid.permission.denied.title".localized
        static let permissionDeniedMessage = "photoGrid.permission.denied.message".localized
        static let permissionOpenSettings = "photoGrid.permission.openSettings".localized
        // Filter options
        static let filterAll = "photoGrid.filter.all".localized
        static let filterNotUploaded = "photoGrid.filter.notUploaded".localized
        static func filterActive(_ count: Int) -> String {
            return "photoGrid.filter.active".localized(with: count)
        }
    }
    
    // MARK: - Upload Progress
    enum UploadProgress {
        static let title = "uploadProgress.title".localized
        static let pause = "uploadProgress.pause".localized
        static let resume = "uploadProgress.resume".localized
        static let emptyTitle = "uploadProgress.empty.title".localized
        static let emptyMessage = "uploadProgress.empty.message".localized
        static func emptySuccess(_ count: Int) -> String {
            return "uploadProgress.empty.success".localized(with: count)
        }
        static let overall = "uploadProgress.overall".localized
        static let uploading = "uploadProgress.uploading".localized
        static let paused = "uploadProgress.paused".localized
        static func files(_ current: Int, _ total: Int) -> String {
            return "uploadProgress.files".localized(with: current, total)
        }
        static func fileCount(_ count: Int) -> String {
            return "uploadProgress.fileCount".localized(with: count)
        }
        static let video = "uploadProgress.video".localized
    }
    
    // MARK: - Upload Status
    enum UploadStatus {
        static let pending = "uploadStatus.pending".localized
        static func uploading(_ percent: Int) -> String {
            return "uploadStatus.uploading".localized(with: percent)
        }
        static let completed = "uploadStatus.completed".localized
        static let failed = "uploadStatus.failed".localized
    }
    
    // MARK: - Import
    enum Import {
        static let title = "import.title".localized
        static let cancel = "import.cancel".localized
        static let done = "import.done".localized
        static let instructionTitle = "import.instruction.title".localized
        static let instructionDescription = "import.instruction.description".localized
        static let instructionStep1 = "import.instruction.step1".localized
        static let instructionStep2 = "import.instruction.step2".localized
        static let instructionStep3 = "import.instruction.step3".localized
        static let selectFile = "import.selectFile".localized
        static let reselectFile = "import.reselectFile".localized
        static let validationSuccess = "import.validation.success".localized
        static let validationFailed = "import.validation.failed".localized
        static let validationRecordCount = "import.validation.recordCount".localized
        static func validationRecords(_ count: Int) -> String {
            return "import.validation.records".localized(with: count)
        }
        static let statisticsTitle = "import.statistics.title".localized
        static let statisticsTotalAssets = "import.statistics.totalAssets".localized
        static let statisticsAssetsWithHash = "import.statistics.assetsWithHash".localized
        static let statisticsImageCount = "import.statistics.imageCount".localized
        static let statisticsVideoCount = "import.statistics.videoCount".localized
        static let statisticsServerSync = "import.statistics.serverSync".localized
        static let statisticsRemoteAssets = "import.statistics.remoteAssets".localized
        static let statisticsLocalSynced = "import.statistics.localSynced".localized
        static let importButton = "import.import.button".localized
        static let importImporting = "import.import.importing".localized
        static func importProgress(_ current: Int, _ total: Int) -> String {
            return "import.import.progress".localized(with: current, total)
        }
        static let resultSuccess = "import.result.success".localized
        static let resultError = "import.result.error".localized
        static let resultTotalRecords = "import.result.totalRecords".localized
        static let resultImportedRecords = "import.result.importedRecords".localized
        static let resultAlreadyOnServer = "import.result.alreadyOnServer".localized
        static let resultSkippedRecords = "import.result.skippedRecords".localized
        static let resultTip = "import.result.tip".localized
        static let alertOk = "import.alert.ok".localized
        static let alertImportFailed = "import.alert.importFailed".localized
    }
    
    // MARK: - Onboarding
    enum Onboarding {
        static let title = "onboarding.title".localized
        static let description = "onboarding.description".localized
        static let importButton = "onboarding.import.button".localized
        static let importDescription = "onboarding.import.description".localized
        static let skip = "onboarding.skip".localized
        static let continue_ = "onboarding.continue".localized
        static let changeFile = "onboarding.changeFile".localized
        static func validationSuccess(_ count: Int) -> String {
            return "onboarding.validation.success".localized(with: count)
        }
        static let startImport = "onboarding.startImport".localized
    }
    
    // MARK: - Initial Setup
    enum InitialSetup {
        static let title = "initialSetup.title".localized
        static let description = "initialSetup.description".localized
        static let syncing = "initialSetup.syncing".localized
        static let syncingDescription = "initialSetup.syncingDescription".localized
        static let completed = "initialSetup.completed".localized
        static let completedDescription = "initialSetup.completedDescription".localized
        static let failed = "initialSetup.failed".localized
        static let failedDescription = "initialSetup.failedDescription".localized
        static let syncedAssets = "initialSetup.syncedAssets".localized
        static let continue_ = "initialSetup.continue".localized
        static let retry = "initialSetup.retry".localized
        static let skip = "initialSetup.skip".localized
        
        // Progress indicators
        static func fetchedAssets(_ count: Int) -> String {
            return "initialSetup.fetchedAssets".localized(with: count)
        }
        static let phaseConnecting = "initialSetup.phase.connecting".localized
        static let phaseFetchingUserInfo = "initialSetup.phase.fetchingUserInfo".localized
        static let phaseFetchingPartners = "initialSetup.phase.fetchingPartners".localized
        static func phaseFetchingAssets(_ count: Int) -> String {
            return "initialSetup.phase.fetchingAssets".localized(with: count)
        }
        static let phaseFetchingAssetsInitial = "initialSetup.phase.fetchingAssetsInitial".localized
        static func phaseProcessingAssets(_ count: Int) -> String {
            return "initialSetup.phase.processingAssets".localized(with: count)
        }
        static let phaseSavingToDatabase = "initialSetup.phase.savingToDatabase".localized
    }
    
    // MARK: - Restart Required
    enum RestartRequired {
        static let title = "restartRequired.title".localized
        static let description = "restartRequired.description".localized
        static let instructions = "restartRequired.instructions".localized
        static let closeApp = "restartRequired.closeApp".localized
    }
    
    // MARK: - Background Upload (iOS 26.1+)
    enum BackgroundUpload {
        static let title = "backgroundUpload.title".localized
        static let settingsTitle = "backgroundUpload.settingsTitle".localized
        static let enabled = "backgroundUpload.enabled".localized
        static let disabled = "backgroundUpload.disabled".localized
        static let description = "backgroundUpload.description".localized
        static let requiresIOS26 = "backgroundUpload.requiresIOS26".localized
        static let sectionAutoUpload = "backgroundUpload.section.autoUpload".localized
        static let sectionStatistics = "backgroundUpload.section.statistics".localized
        static let sectionDebug = "backgroundUpload.section.debug".localized
        static let uploadedCount = "backgroundUpload.uploadedCount".localized
        static let pendingCount = "backgroundUpload.pendingCount".localized
        static let viewLogs = "backgroundUpload.viewLogs".localized
        static let clearLogs = "backgroundUpload.clearLogs".localized
        static let logsTitle = "backgroundUpload.logsTitle".localized
        static let noLogs = "backgroundUpload.noLogs".localized
        static let notSupported = "backgroundUpload.notSupported".localized
        static let errorPhotoLibraryNotAuthorized = "backgroundUpload.error.photoLibraryNotAuthorized".localized
        static let errorNotLoggedIn = "backgroundUpload.error.notLoggedIn".localized
        static let errorExtensionNotAvailable = "backgroundUpload.error.extensionNotAvailable".localized
    }
}
