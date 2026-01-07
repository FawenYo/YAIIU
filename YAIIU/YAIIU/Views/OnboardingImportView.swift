import SwiftUI
import UniformTypeIdentifiers

/// View displayed after first login to prompt user for importing Immich SQLite data
struct OnboardingImportView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @ObservedObject var hashManager = HashManager.shared
    
    var showRestartOnComplete: Bool = false
    
    @State private var isShowingFilePicker = false
    @State private var selectedFileURL: URL?
    @State private var validationResult: (isValid: Bool, recordCount: Int, errorMessage: String?)?
    @State private var isImporting = false
    @State private var importResult: ImmichSQLiteImporter.ImportResult?
    @State private var importProgress: (current: Int, total: Int) = (0, 0)
    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Header
                headerSection
                
                Spacer()
                
                // Main content
                if importResult != nil {
                    importResultSection
                } else if isImporting {
                    importingSection
                } else if let validation = validationResult, validation.isValid {
                    fileSelectedSection(validation)
                } else {
                    optionsSection
                }
                
                Spacer()
                
                // Bottom buttons
                bottomButtonsSection
            }
            .padding()
            .navigationBarHidden(true)
            .sheet(isPresented: $isShowingFilePicker) {
                DocumentPicker(fileURL: $selectedFileURL)
            }
            .onChange(of: selectedFileURL) { _, newURL in
                if let url = newURL {
                    validateSelectedFile(url)
                }
            }
            .alert(alertTitle, isPresented: $showingAlert) {
                Button(L10n.Import.alertOk, role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
        }
    }
    
    // MARK: - View Components
    
    private var headerSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            
            Text(L10n.Onboarding.title)
                .font(.title)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
            
            Text(L10n.Onboarding.description)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.top, 40)
    }
    
    private var optionsSection: some View {
        VStack(spacing: 20) {
            // Import option
            Button {
                isShowingFilePicker = true
            } label: {
                HStack {
                    Image(systemName: "doc.badge.plus")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.Onboarding.importButton)
                            .fontWeight(.semibold)
                        Text(L10n.Onboarding.importDescription)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            
            // Error message if validation failed
            if let validation = validationResult, !validation.isValid {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(validation.errorMessage ?? L10n.Import.validationFailed)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .padding(.horizontal)
            }
        }
        .padding(.horizontal)
    }
    
    private func fileSelectedSection(_ validation: (isValid: Bool, recordCount: Int, errorMessage: String?)) -> some View {
        VStack(spacing: 20) {
            // File info
            if let url = selectedFileURL {
                HStack {
                    Image(systemName: "doc.fill")
                        .foregroundColor(.blue)
                    Text(url.lastPathComponent)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        isShowingFilePicker = true
                    } label: {
                        Text(L10n.Onboarding.changeFile)
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(10)
            }
            
            // Validation success
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(L10n.Onboarding.validationSuccess(validation.recordCount))
                    .font(.subheadline)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.green.opacity(0.1))
            .cornerRadius(10)
            
            // Import button
            Button {
                performImport()
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                    Text(L10n.Onboarding.startImport)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
        }
        .padding(.horizontal)
    }
    
    private var importingSection: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text(L10n.Import.importImporting)
                .font(.headline)
            
            if importProgress.total > 0 {
                VStack(spacing: 8) {
                    ProgressView(value: Double(importProgress.current), total: Double(importProgress.total))
                        .progressViewStyle(LinearProgressViewStyle())
                    
                    Text(L10n.Import.importProgress(importProgress.current, importProgress.total))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 40)
            }
        }
    }
    
    private var importResultSection: some View {
        VStack(spacing: 20) {
            if let result = importResult {
                Image(systemName: result.errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(result.errorMessage == nil ? .green : .orange)
                
                Text(result.errorMessage == nil ? L10n.Import.resultSuccess : L10n.Import.resultError)
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.Import.resultImportedRecords)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(L10n.Import.validationRecords(result.importedRecords))
                            .fontWeight(.semibold)
                    }
                    
                    HStack {
                        Text(L10n.Import.resultAlreadyOnServer)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(L10n.Import.validationRecords(result.alreadyOnServer))
                            .foregroundColor(.blue)
                            .fontWeight(.semibold)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(10)
                
                if result.alreadyOnServer > 0 {
                    Text(L10n.Import.resultTip)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(.horizontal)
    }
    
    private var bottomButtonsSection: some View {
        VStack(spacing: 12) {
            if importResult != nil {
                // Continue button after import
                Button {
                    completeOnboarding()
                } label: {
                    Text(L10n.Onboarding.continue_)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            } else if !isImporting && validationResult?.isValid != true {
                // Skip button
                Button {
                    completeOnboarding()
                } label: {
                    Text(L10n.Onboarding.skip)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 20)
            }
        }
        .padding(.horizontal)
    }
    
    // MARK: - Actions
    
    private func validateSelectedFile(_ url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        
        let result = ImmichSQLiteImporter.shared.validateFile(fileURL: url)
        validationResult = result
        
        if hasAccess {
            url.stopAccessingSecurityScopedResource()
        }
    }
    
    private func performImport() {
        guard let url = selectedFileURL else { return }
        
        // Check if hashing is in progress and pause it
        let wasProcessing = hashManager.isProcessing
        if wasProcessing {
            hashManager.stopProcessing()
            // Wait a moment for the processing to stop
            Thread.sleep(forTimeInterval: 0.5)
        }
        
        isImporting = true
        importProgress = (0, 0)
        
        DispatchQueue.global(qos: .userInitiated).async {
            let hasAccess = url.startAccessingSecurityScopedResource()
            
            let result = ImmichSQLiteImporter.shared.importFromFile(fileURL: url) { current, total in
                DispatchQueue.main.async {
                    importProgress = (current, total)
                }
            }
            
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
            
            DispatchQueue.main.async {
                isImporting = false
                importResult = result
                
                // Refresh hash manager cache
                hashManager.refreshStatusCache()
                
                if let error = result.errorMessage {
                    showAlert(title: L10n.Import.alertImportFailed, message: error)
                }
            }
        }
    }
    
    private func completeOnboarding() {
        settingsManager.completeOnboarding()
        
        if showRestartOnComplete {
            settingsManager.requestAppRestart()
        }
    }
    
    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showingAlert = true
    }
}

#Preview {
    OnboardingImportView()
        .environmentObject(SettingsManager())
}
