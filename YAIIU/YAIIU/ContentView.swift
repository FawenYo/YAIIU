import CoreLocation
import SwiftUI

// MARK: - URL Identifiable Extension for sheet(item:) support
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

struct ContentView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var uploadManager: UploadManager
    
    var body: some View {
        Group {
            if settingsManager.isLoggedIn {
                if !settingsManager.hasCompletedInitialSetup {
                    InitialSetupView()
                } else if !settingsManager.hasCompletedOnboarding {
                    // Only iOS 26.1+ needs restart to work around PHPhotosErrorDomain 3202
                    if #available(iOS 26.1, *) {
                        OnboardingImportView(showRestartOnComplete: true)
                    } else {
                        OnboardingImportView(showRestartOnComplete: false)
                    }
                } else if settingsManager.needsAppRestart {
                    // RestartRequiredView only shown on iOS 26.1+ (set by showRestartOnComplete)
                    RestartRequiredView()
                } else {
                    MainTabView()
                }
            } else {
                LoginView()
            }
        }
    }
}

struct MainTabView: View {
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            PhotoGridView()
                .tabItem {
                    Label(L10n.Tab.photos, systemImage: "photo.on.rectangle")
                }
                .tag(0)
            
            UploadProgressView()
                .tabItem {
                    Label(L10n.Tab.upload, systemImage: "arrow.up.circle")
                }
                .tag(1)
            
            SettingsView()
                .tabItem {
                    Label(L10n.Tab.settings, systemImage: "gear")
                }
                .tag(2)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var uploadManager: UploadManager
    @State private var showingLogoutAlert = false
    @State private var showingImportView = false
    @State private var showingClearLogsAlert = false
    @State private var hashCacheStats: (total: Int, checked: Int, onServer: Int) = (0, 0, 0)
    @State private var logFileSize: String = "0 KB"
    @State private var logCount: Int = 0
    @State private var exportedLogURL: URL?
    @State private var backgroundUploadEnabled = false
    @State private var backgroundUploadLoading = false
    @State private var backgroundUploadError: String?
    
    @ObservedObject private var networkReachability = NetworkReachability.shared
    
    private var currentServerURL: String {
        if networkReachability.isOnInternalNetwork && !settingsManager.internalServerURL.isEmpty {
            return settingsManager.internalServerURL
        }
        return settingsManager.serverURL
    }
    
    private var isUsingInternalNetwork: Bool {
        networkReachability.isOnInternalNetwork && !settingsManager.internalServerURL.isEmpty
    }
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text(L10n.Settings.serverInfo)) {
                    // Network Settings - shows current status and allows editing
                    NavigationLink(destination: NetworkSettingsView()) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.Settings.networkSettings)
                                HStack(spacing: 4) {
                                    Image(systemName: isUsingInternalNetwork ? "house.fill" : "globe")
                                        .font(.caption)
                                    Text(isUsingInternalNetwork ? L10n.Settings.usingInternalNetwork : L10n.Settings.usingExternalNetwork)
                                        .font(.caption)
                                }
                                .foregroundColor(isUsingInternalNetwork ? .green : .blue)
                            }
                            Spacer()
                            Text(currentServerURL)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .font(.caption)
                        }
                    }
                    
                    HStack {
                        Text(L10n.Settings.apiKey)
                        Spacer()
                        Text(String(repeating: "•", count: min(settingsManager.apiKey.count, 20)))
                            .foregroundColor(.secondary)
                    }
                }
                
                Section(header: Text(L10n.Settings.statistics)) {
                    HStack {
                        Text(L10n.Settings.uploadedCount)
                        Spacer()
                        Text("\(uploadManager.uploadedCount)")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text(L10n.Settings.cachedHashCount)
                        Spacer()
                        Text("\(hashCacheStats.total)")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text(L10n.Settings.confirmedOnCloud)
                        Spacer()
                        Text("\(hashCacheStats.onServer)")
                            .foregroundColor(.secondary)
                    }
                }
                
                // iOS 26.1+ Background Upload Settings
                if #available(iOS 26.1, *) {
                    Section(header: Text(L10n.BackgroundUpload.sectionAutoUpload), footer: Text(L10n.BackgroundUpload.description).font(.caption)) {
                        Toggle(isOn: $backgroundUploadEnabled) {
                            HStack {
                                Image(systemName: "arrow.up.circle.badge.clock")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L10n.BackgroundUpload.title)
                                        .foregroundColor(.primary)
                                    Text(backgroundUploadEnabled ? L10n.BackgroundUpload.enabled : L10n.BackgroundUpload.disabled)
                                        .font(.caption)
                                        .foregroundColor(backgroundUploadEnabled ? .green : .secondary)
                                }
                            }
                        }
                        .disabled(backgroundUploadLoading)
                        .onChange(of: backgroundUploadEnabled) { _, newValue in
                            toggleBackgroundUpload(enabled: newValue)
                        }
                        
                        if let error = backgroundUploadError {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
                
                Section(header: Text(L10n.Settings.dataManagement)) {
                    Button(action: {
                        showingImportView = true
                    }) {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                                .foregroundColor(.blue)
                            Text(L10n.Settings.importImmichData)
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section(header: Text(L10n.Settings.logs)) {
                    HStack {
                        Text(L10n.Settings.logCount)
                        Spacer()
                        Text("\(logCount)")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text(L10n.Settings.logFileSize)
                        Spacer()
                        Text(logFileSize)
                            .foregroundColor(.secondary)
                    }
                    
                    NavigationLink(destination: LogViewerView()) {
                        HStack {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundColor(.blue)
                            Text(L10n.Settings.viewLogs)
                                .foregroundColor(.primary)
                        }
                    }
                    
                    Button(action: {
                        exportLogs()
                    }) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundColor(.blue)
                            Text(L10n.Settings.exportLogs)
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Button(action: {
                        showingClearLogsAlert = true
                    }) {
                        HStack {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                            Text(L10n.Settings.clearLogs)
                                .foregroundColor(.red)
                        }
                    }
                }
                
                Section {
                    Button(action: {
                        showingLogoutAlert = true
                    }) {
                        HStack {
                            Spacer()
                            Text(L10n.Settings.logout)
                                .foregroundColor(.red)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle(L10n.Settings.title)
            .onAppear {
                loadHashCacheStats()
                loadLogStats()
                loadBackgroundUploadStatus()
            }
            .alert(L10n.Settings.logoutConfirmTitle, isPresented: $showingLogoutAlert) {
                Button(L10n.Settings.logoutCancel, role: .cancel) { }
                Button(L10n.Settings.logout, role: .destructive) {
                    settingsManager.logout()
                }
            } message: {
                Text(L10n.Settings.logoutConfirmMessage)
            }
            .alert(L10n.Settings.clearLogsConfirmTitle, isPresented: $showingClearLogsAlert) {
                Button(L10n.Settings.clearLogsCancel, role: .cancel) { }
                Button(L10n.Settings.clearLogs, role: .destructive) {
                    LogService.shared.clearLogs()
                    loadLogStats()
                }
            } message: {
                Text(L10n.Settings.clearLogsConfirmMessage)
            }
            .sheet(isPresented: $showingImportView) {
                ImportDatabaseView()
                    .onDisappear {
                        loadHashCacheStats()
                    }
            }
            .sheet(item: $exportedLogURL) { url in
                ShareSheet(activityItems: [url])
            }
        }
    }
    
    private func loadHashCacheStats() {
        DatabaseManager.shared.getHashCacheStatsAsync { total, checked, onServer in
            hashCacheStats = (total, checked, onServer)
        }
    }
    
    private func loadLogStats() {
        // Use total log count including background upload logs
        logCount = LogService.shared.getTotalLogCount()
        logFileSize = LogService.shared.getLogFileSizeString()
    }
    
    private func exportLogs() {
        logInfo("User requested log export", category: .app)
        // Export all merged logs (app + background upload)
        if let url = LogService.shared.exportAllLogsToFile() {
            exportedLogURL = url
        }
    }
    
    private func loadBackgroundUploadStatus() {
        if #available(iOS 26.1, *) {
            let manager = BackgroundUploadManager.shared
            backgroundUploadEnabled = manager.isEnabled
            backgroundUploadError = manager.errorMessage
        }
    }
    
    private func toggleBackgroundUpload(enabled: Bool) {
        if #available(iOS 26.1, *) {
            let manager = BackgroundUploadManager.shared
            guard enabled != manager.isEnabled else { return }
            
            backgroundUploadLoading = true
            backgroundUploadError = nil
            
            Task {
                do {
                    if enabled {
                        try await manager.enableBackgroundUpload()
                    } else {
                        try await manager.disableBackgroundUpload()
                    }
                    
                    await MainActor.run {
                        backgroundUploadLoading = false
                        loadBackgroundUploadStatus()
                    }
                } catch {
                    await MainActor.run {
                        backgroundUploadLoading = false
                        backgroundUploadEnabled = manager.isEnabled
                        backgroundUploadError = error.localizedDescription
                    }
                }
            }
        }
    }
}

// MARK: - Network Settings View

struct NetworkSettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var networkReachability = NetworkReachability.shared
    
    @State private var externalURL: String = ""
    @State private var internalURL: String = ""
    @State private var wifiSSID: String = ""
    @FocusState private var focusedField: Field?
    
    private enum Field {
        case externalURL, internalURL, ssid
    }
    
    private var needsLocationPermission: Bool {
        let status = networkReachability.locationAuthorizationStatus
        return status == .notDetermined || status == .denied || status == .restricted
    }
    
    private var needsPreciseLocation: Bool {
        let status = networkReachability.locationAuthorizationStatus
        let hasPermission = status == .authorizedWhenInUse || status == .authorizedAlways
        return hasPermission && !networkReachability.isPreciseLocationEnabled
    }
    
    private var isUsingInternalNetwork: Bool {
        networkReachability.isOnInternalNetwork && !settingsManager.internalServerURL.isEmpty
    }
    
    var body: some View {
        Form {
            // Current status section
            Section(header: Text(L10n.Settings.currentStatus)) {
                HStack {
                    Image(systemName: isUsingInternalNetwork ? "house.fill" : "globe")
                        .foregroundColor(isUsingInternalNetwork ? .green : .blue)
                    Text(isUsingInternalNetwork ? L10n.Settings.usingInternalNetwork : L10n.Settings.usingExternalNetwork)
                    Spacer()
                    if let ssid = networkReachability.currentSSID {
                        HStack(spacing: 4) {
                            Image(systemName: "wifi")
                                .font(.caption)
                            Text(ssid)
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                    }
                }
            }
            
            // External URL section
            Section(header: Text(L10n.Settings.externalServerURL), footer: Text(L10n.Settings.externalServerURLHint).font(.caption)) {
                TextField(L10n.Settings.externalServerURLPlaceholder, text: $externalURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($focusedField, equals: .externalURL)
            }
            
            // Internal URL section
            Section(header: Text(L10n.Settings.internalServerURL), footer: Text(L10n.Settings.internalServerURLHint).font(.caption)) {
                TextField(L10n.Settings.internalServerURLPlaceholder, text: $internalURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($focusedField, equals: .internalURL)
            }
            
            // WiFi SSID section
            Section(header: Text(L10n.Settings.wifiSSID), footer: Text(L10n.Settings.wifiSSIDHint).font(.caption)) {
                TextField(L10n.Settings.wifiSSIDPlaceholder, text: $wifiSSID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .ssid)
                
                // Use published currentSSID from networkReachability
                if let detectedSSID = networkReachability.currentSSID, !detectedSSID.isEmpty {
                    Button(action: {
                        wifiSSID = detectedSSID
                    }) {
                        HStack {
                            Image(systemName: "wifi")
                            Text(L10n.Settings.useCurrentWiFi)
                            Spacer()
                            Text(detectedSSID)
                                .foregroundColor(.secondary)
                        }
                    }
                } else if !needsLocationPermission && !needsPreciseLocation {
                    HStack {
                        Image(systemName: "wifi.slash")
                            .foregroundColor(.secondary)
                        Text(L10n.Settings.wifiNotDetected)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // Location permission warning
            if needsLocationPermission {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "location.slash.fill")
                                .foregroundColor(.orange)
                            Text(L10n.Settings.locationPermissionRequired)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                        
                        Text(L10n.Settings.locationPermissionHint)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Button(action: {
                            NetworkReachability.shared.requestLocationPermission()
                        }) {
                            HStack {
                                Image(systemName: "location.fill")
                                Text(L10n.Settings.grantLocationPermission)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                    .padding(.vertical, 4)
                }
            }
            
            // Precise location warning
            if needsPreciseLocation {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "location.slash.fill")
                                .foregroundColor(.orange)
                            Text(L10n.Settings.preciseLocationRequired)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                        
                        Text(L10n.Settings.preciseLocationHint)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Button(action: {
                            openLocationSettings()
                        }) {
                            HStack {
                                Image(systemName: "gear")
                                Text(L10n.Settings.openSettings)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                    .padding(.vertical, 4)
                }
            }
            
            // Save button
            Section {
                Button(action: saveSettings) {
                    HStack {
                        Spacer()
                        Text(L10n.Settings.save)
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(externalURL.isEmpty)
            }
        }
        .navigationTitle(L10n.Settings.networkSettings)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            externalURL = settingsManager.serverURL
            internalURL = settingsManager.internalServerURL
            wifiSSID = settingsManager.internalNetworkSSID
            // Trigger refresh to update currentSSID via async method
            NetworkReachability.shared.refresh()
        }
    }
    
    private func saveSettings() {
        var external = externalURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var internal_ = internalURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let ssid = wifiSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Format external URL
        if !external.isEmpty {
            if !external.hasPrefix("http://") && !external.hasPrefix("https://") {
                external = "https://" + external
            }
            if external.hasSuffix("/") {
                external = String(external.dropLast())
            }
        }
        
        // Format internal URL
        if !internal_.isEmpty {
            if !internal_.hasPrefix("http://") && !internal_.hasPrefix("https://") {
                internal_ = "http://" + internal_
            }
            if internal_.hasSuffix("/") {
                internal_ = String(internal_.dropLast())
            }
        }
        
        // Update external URL if changed
        if external != settingsManager.serverURL && !external.isEmpty {
            settingsManager.updateServerURL(external)
        }
        
        // Update internal network settings
        settingsManager.updateInternalNetworkSettings(url: internal_, ssid: ssid)
        dismiss()
    }
    
    private func openLocationSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
        .environmentObject(SettingsManager())
        .environmentObject(UploadManager())
}
