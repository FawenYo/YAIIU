import SwiftUI

struct InitialSetupView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    
    @State private var syncState: SyncState = .idle
    @State private var syncProgressText: String = ""
    @State private var syncedAssetCount: Int = 0
    @State private var syncResult: SyncResult?
    @State private var errorMessage: String?
    
    enum SyncState {
        case idle
        case syncing
        case completed
        case failed
    }
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            iconSection
            titleSection
            
            Spacer()
            
            contentSection
            
            Spacer()
            
            actionSection
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
        .onAppear {
            startInitialSync()
        }
    }
    
    // MARK: - View Components
    
    private var iconSection: some View {
        Group {
            switch syncState {
            case .idle, .syncing:
                SyncingIconView(isAnimating: syncState == .syncing)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.orange)
            }
        }
    }
    
    private var titleSection: some View {
        VStack(spacing: 12) {
            Text(titleText)
                .font(.title)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
            
            Text(subtitleText)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    private var titleText: String {
        switch syncState {
        case .idle:
            return L10n.InitialSetup.title
        case .syncing:
            return L10n.InitialSetup.syncing
        case .completed:
            return L10n.InitialSetup.completed
        case .failed:
            return L10n.InitialSetup.failed
        }
    }
    
    private var subtitleText: String {
        switch syncState {
        case .idle:
            return L10n.InitialSetup.description
        case .syncing:
            return syncProgressText.isEmpty ? L10n.InitialSetup.syncingDescription : syncProgressText
        case .completed:
            return L10n.InitialSetup.completedDescription
        case .failed:
            return errorMessage ?? L10n.InitialSetup.failedDescription
        }
    }
    
    private var contentSection: some View {
        VStack(spacing: 16) {
            if syncState == .syncing {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    
                    if syncedAssetCount > 0 {
                        Text(L10n.InitialSetup.fetchedAssets(syncedAssetCount))
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.top, 8)
                    }
                }
                .padding()
            }
            
            if let result = syncResult, syncState == .completed {
                syncResultCard(result)
            }
        }
    }
    
    private func syncResultCard(_ result: SyncResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.InitialSetup.syncedAssets)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(result.totalAssets)")
                    .fontWeight(.semibold)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    private var actionSection: some View {
        VStack(spacing: 12) {
            switch syncState {
            case .idle, .syncing:
                EmptyView()
            case .completed:
                Button {
                    proceedToOnboarding()
                } label: {
                    Text(L10n.InitialSetup.continue_)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            case .failed:
                Button {
                    startInitialSync()
                } label: {
                    Text(L10n.InitialSetup.retry)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                
                Button {
                    skipInitialSync()
                } label: {
                    Text(L10n.InitialSetup.skip)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Actions
    
    private func startInitialSync() {
        syncState = .syncing
        syncProgressText = ""
        syncedAssetCount = 0
        errorMessage = nil
        
        logInfo("Starting initial setup sync", category: .sync)
        
        ServerAssetSyncService.shared.syncServerAssets(
            serverURL: settingsManager.activeServerURL,
            apiKey: settingsManager.apiKey,
            forceFullSync: true,
            progressHandler: { [self] progress in
                handleSyncProgress(progress)
            }
        ) { result in
            switch result {
            case .success(let syncResult):
                self.syncResult = syncResult
                self.syncState = .completed
                logInfo("Initial setup sync completed: \(syncResult.totalAssets) assets", category: .sync)
                
            case .failure(let error):
                self.errorMessage = error.localizedDescription
                self.syncState = .failed
                logError("Initial setup sync failed: \(error.localizedDescription)", category: .sync)
            }
        }
    }
    
    private func handleSyncProgress(_ progress: SyncProgress) {
        syncedAssetCount = progress.fetchedCount
        
        switch progress.phase {
        case .connecting:
            syncProgressText = L10n.InitialSetup.phaseConnecting
        case .fetchingUserInfo:
            syncProgressText = L10n.InitialSetup.phaseFetchingUserInfo
        case .fetchingPartners:
            syncProgressText = L10n.InitialSetup.phaseFetchingPartners
        case .fetchingAssets:
            if progress.fetchedCount > 0 {
                syncProgressText = L10n.InitialSetup.phaseFetchingAssets(progress.fetchedCount)
            } else {
                syncProgressText = L10n.InitialSetup.phaseFetchingAssetsInitial
            }
        case .processingAssets:
            syncProgressText = L10n.InitialSetup.phaseProcessingAssets(progress.fetchedCount)
        case .savingToDatabase:
            syncProgressText = L10n.InitialSetup.phaseSavingToDatabase
        }
    }
    
    private func proceedToOnboarding() {
        logInfo("Initial sync completed, proceeding to onboarding", category: .app)
        settingsManager.completeInitialSetup()
    }
    
    private func skipInitialSync() {
        logWarning("User skipped initial sync", category: .app)
        settingsManager.completeInitialSetup()
    }
}

#Preview {
    InitialSetupView()
        .environmentObject(SettingsManager())
}

// MARK: - Syncing Icon with Rotation Animation

private struct SyncingIconView: View {
    let isAnimating: Bool
    @State private var rotation: Double = 0
    
    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
            .font(.system(size: 80))
            .foregroundColor(.blue)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                if isAnimating {
                    startAnimation()
                }
            }
            .onChange(of: isAnimating) { _, newValue in
                if newValue {
                    startAnimation()
                }
            }
    }
    
    private func startAnimation() {
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            rotation = 360
        }
    }
}
