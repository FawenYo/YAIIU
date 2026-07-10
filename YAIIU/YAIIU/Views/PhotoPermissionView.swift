import SwiftUI
import Photos

/// Onboarding step that requests full photo library access.
/// Full ".authorized" access (not ".limited") is required so the background upload
/// extension can be enabled later without PHPhotosErrorDomain 3202.
struct PhotoPermissionView: View {
    @EnvironmentObject var settingsManager: SettingsManager

    @State private var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var isRequesting = false

    private var hasFullAccess: Bool { status == .authorized }
    private var needsUpgrade: Bool { status == .limited || status == .denied || status == .restricted }

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

            Spacer()

            actionSection
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
        .onAppear {
            refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshStatus()
        }
    }

    private func refreshStatus() {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if currentStatus == .authorized {
            settingsManager.completePhotoPermission()
        } else {
            status = currentStatus
        }
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
                if newStatus == .authorized {
                    self.settingsManager.completePhotoPermission()
                }
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

#Preview {
    PhotoPermissionView()
        .environmentObject(SettingsManager())
}
