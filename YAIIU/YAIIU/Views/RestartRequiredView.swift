import SwiftUI

/// View displayed after onboarding to request app restart.
/// This workaround addresses PHPhotosErrorDomain error 3202, which occurs when enabling
/// the background upload extension immediately after fresh install.
struct RestartRequiredView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.blue)
            
            VStack(spacing: 12) {
                Text(L10n.RestartRequired.title)
                    .font(.title)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                
                Text(L10n.RestartRequired.description)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
            
            instructionCard
            
            Spacer()
            
            Button {
                closeApp()
            } label: {
                Text(L10n.RestartRequired.closeApp)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
    }
    
    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.blue)
                    .font(.title2)
                Text(L10n.RestartRequired.title)
                    .font(.headline)
            }
            
            Text(L10n.RestartRequired.instructions)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    private func closeApp() {
        logInfo("User requested app termination for restart", category: .app)
        exit(0)
    }
}

#Preview {
    RestartRequiredView()
        .environmentObject(SettingsManager())
}
