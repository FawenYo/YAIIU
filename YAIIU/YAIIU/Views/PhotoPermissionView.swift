import SwiftUI
import Photos

/// Onboarding step that requests full photo library access.
/// Full ".authorized" access (not ".limited") is required so the background upload
/// extension can be enabled later without PHPhotosErrorDomain 3202.
struct PhotoPermissionView: View {
    @EnvironmentObject var settingsManager: SettingsManager

    @State private var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var isRequesting = false

    @State private var backgroundUploadEnabled = false
    @State private var backgroundUploadLoading = false
    @State private var backgroundUploadError: String?

    private var hasFullAccess: Bool { status == .authorized }
    private var needsUpgrade: Bool { status == .limited || status == .denied || status == .restricted }

    private var backgroundUploadSupported: Bool {
        if #available(iOS 26.1, *) { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: hasFullAccess ? "checkmark.circle.fill" : "photo.on.rectangle.angled")
                .font(.system(size: 80))
                .foregroundColor(hasFullAccess ? .green : .blue)

            VStack(spacing: 12) {
                Text(L10n.PhotoPermission.title)
                    .font(.title)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text(L10n.PhotoPermission.description)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            if needsUpgrade {
                warningCard
            }

            if hasFullAccess && backgroundUploadSupported {
                backgroundUploadCard
            }

            Spacer()

            actionSection
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
        .onAppear {
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            loadBackgroundUploadStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            loadBackgroundUploadStatus()
        }
    }

    private var backgroundUploadCard: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            Text(L10n.BackgroundUpload.description)
                .font(.caption)
                .foregroundColor(.secondary)

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
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var warningCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(L10n.PhotoPermission.limitedWarning)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            Button {
                openSettings()
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text(L10n.PhotoPermission.openSettings)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var actionSection: some View {
        VStack(spacing: 12) {
            if status == .notDetermined {
                Button {
                    requestAccess()
                } label: {
                    Text(L10n.PhotoPermission.grantButton)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(isRequesting)
            } else {
                Button {
                    settingsManager.completePhotoPermission()
                } label: {
                    Text(L10n.PhotoPermission.continue_)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }
        }
    }

    private func requestAccess() {
        isRequesting = true
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
            DispatchQueue.main.async {
                self.status = newStatus
                self.isRequesting = false
                self.loadBackgroundUploadStatus()
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
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
        guard #available(iOS 26.1, *) else { return }
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
                    backgroundUploadEnabled = !enabled
                    backgroundUploadError = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    PhotoPermissionView()
        .environmentObject(SettingsManager())
}
