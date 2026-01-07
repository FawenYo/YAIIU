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
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text(L10n.Settings.serverInfo)) {
                    HStack {
                        Text(L10n.Settings.serverURL)
                        Spacer()
                        Text(settingsManager.serverURL)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
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
