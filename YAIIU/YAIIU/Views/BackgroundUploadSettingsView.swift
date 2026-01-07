import SwiftUI
import Photos
import Combine

struct BackgroundUploadSettingsView: View {
    @StateObject private var viewModel = BackgroundUploadSettingsViewModel()
    
    var body: some View {
        List {
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
    @Published var isSupported: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    private var managerRef: Any?
    
    init() {
        if #available(iOS 26.1, *) {
            isSupported = true
            let manager = BackgroundUploadManager.shared
            managerRef = manager
            
            manager.$isEnabled
                .receive(on: DispatchQueue.main)
                .assign(to: &$isEnabled)
            
            manager.$errorMessage
                .receive(on: DispatchQueue.main)
                .assign(to: &$errorMessage)
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
}

// MARK: - Preview

#Preview {
    NavigationStack {
        BackgroundUploadSettingsView()
    }
}
