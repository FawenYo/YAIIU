import SwiftUI
import Photos
import Combine

/// BackgroundUploadSettingsView - Background upload settings view
/// Allows users to enable/disable iOS 26.1 background upload feature
struct BackgroundUploadSettingsView: View {
    @StateObject private var viewModel = BackgroundUploadSettingsViewModel()
    
    var body: some View {
        List {
            // Background upload toggle section
            Section {
                if viewModel.isSupported {
                    Toggle(isOn: $viewModel.isEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.BackgroundUpload.title)
                                .font(.body)
                            Text(viewModel.isEnabled ? L10n.BackgroundUpload.enabled : L10n.BackgroundUpload.disabled)
                                .font(.caption)
                                .foregroundColor(viewModel.isEnabled ? .green : .secondary)
                        }
                    }
                    .onChange(of: viewModel.isEnabled) { _, newValue in
                        viewModel.toggleBackgroundUpload(enabled: newValue)
                    }
                    .disabled(viewModel.isLoading)
                } else {
                    // Show unsupported message for iOS versions below 26.1
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text(L10n.BackgroundUpload.requiresIOS26)
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text(L10n.BackgroundUpload.sectionAutoUpload)
            } footer: {
                Text(L10n.BackgroundUpload.description)
                    .font(.caption)
            }
            
            // Statistics section
            if viewModel.isSupported && viewModel.isEnabled {
                Section {
                    HStack {
                        Label(L10n.BackgroundUpload.uploadedCount, systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Spacer()
                        Text("\(viewModel.uploadedCount)")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Label(L10n.BackgroundUpload.pendingCount, systemImage: "clock.fill")
                            .foregroundColor(.blue)
                        Spacer()
                        Text("\(viewModel.pendingCount)")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text(L10n.BackgroundUpload.sectionStatistics)
                }
            }
            
            // Error message section
            if let errorMessage = viewModel.errorMessage {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(errorMessage)
                            .font(.body)
                            .foregroundColor(.red)
                    }
                }
            }
            
            // Logs section (for debugging)
            #if DEBUG
            if viewModel.isSupported {
                Section {
                    NavigationLink(destination: BackgroundUploadLogsView()) {
                        Label(L10n.BackgroundUpload.viewLogs, systemImage: "doc.text")
                    }
                    
                    Button(action: {
                        viewModel.clearLogs()
                    }) {
                        Label(L10n.BackgroundUpload.clearLogs, systemImage: "trash")
                            .foregroundColor(.red)
                    }
                } header: {
                    Text(L10n.BackgroundUpload.sectionDebug)
                }
            }
            #endif
        }
        .navigationTitle(L10n.BackgroundUpload.settingsTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.refresh()
        }
        .refreshable {
            viewModel.refresh()
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView()
                    .scaleEffect(1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.2))
            }
        }
    }
}

// MARK: - ViewModel

class BackgroundUploadSettingsViewModel: ObservableObject {
    @Published var isEnabled: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var uploadedCount: Int = 0
    @Published var pendingCount: Int = 0
    @Published var isSupported: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    // Use Any? to avoid @available restriction on stored properties
    private var managerRef: Any?
    
    init() {
        // Check if iOS 26.1 is supported
        if #available(iOS 26.1, *) {
            isSupported = true
            let manager = BackgroundUploadManager.shared
            managerRef = manager
            
            // Subscribe to manager's published properties
            manager.$isEnabled
                .receive(on: DispatchQueue.main)
                .assign(to: &$isEnabled)
            
            manager.$errorMessage
                .receive(on: DispatchQueue.main)
                .assign(to: &$errorMessage)
            
            manager.$uploadedCount
                .receive(on: DispatchQueue.main)
                .assign(to: &$uploadedCount)
            
            manager.$pendingCount
                .receive(on: DispatchQueue.main)
                .assign(to: &$pendingCount)
        } else {
            isSupported = false
        }
        refresh()
    }
    
    func refresh() {
        guard isSupported else { return }
        
        if #available(iOS 26.1, *) {
            if let manager = managerRef as? BackgroundUploadManager {
                manager.checkExtensionStatus()
            }
        }
    }
    
    func toggleBackgroundUpload(enabled: Bool) {
        guard isSupported else { return }
        
        if #available(iOS 26.1, *) {
            guard let manager = managerRef as? BackgroundUploadManager else { return }
            guard enabled != manager.isEnabled else { return }
            
            isLoading = true
            errorMessage = nil
            
            Task {
                do {
                    if enabled {
                        try await manager.enableBackgroundUpload()
                    } else {
                        try await manager.disableBackgroundUpload()
                    }
                    
                    await MainActor.run {
                        self.isLoading = false
                        self.refresh()
                    }
                } catch {
                    await MainActor.run {
                        self.isLoading = false
                        self.isEnabled = manager.isEnabled
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
    
    func clearLogs() {
        if #available(iOS 26.1, *) {
            BackgroundUploadManager.shared.clearBackgroundLogs()
        }
    }
}

// MARK: - Background Upload Logs View (Debug)

#if DEBUG
struct BackgroundUploadLogsView: View {
    @State private var logs: String = ""
    
    var body: some View {
        ScrollView {
            Text(logs)
                .font(.system(.caption, design: .monospaced))
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(L10n.BackgroundUpload.logsTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadLogs()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: loadLogs) {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }
    
    private func loadLogs() {
        if #available(iOS 26.1, *) {
            logs = BackgroundUploadManager.shared.readBackgroundLogs() ?? L10n.BackgroundUpload.noLogs
        } else {
            logs = L10n.BackgroundUpload.notSupported
        }
    }
}
#endif

// MARK: - Preview

#Preview {
    NavigationStack {
        BackgroundUploadSettingsView()
    }
}
