import SwiftUI
import UniformTypeIdentifiers

struct ImportDatabaseView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var hashManager = HashManager.shared
    
    @State private var isShowingFilePicker = false
    @State private var selectedFileURL: URL?
    @State private var validationResult: (isValid: Bool, recordCount: Int, errorMessage: String?)?
    @State private var statistics: [String: Any]?
    @State private var isImporting = false
    @State private var importResult: ImmichSQLiteImporter.ImportResult?
    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var importProgress: (current: Int, total: Int) = (0, 0)
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    instructionSection
                    fileSelectionSection
                    
                    if let validation = validationResult {
                        validationSection(validation)
                    }
                    
                    if let stats = statistics {
                        statisticsSection(stats)
                    }
                    
                    if let result = importResult {
                        importResultSection(result)
                    }
                    
                    if validationResult?.isValid == true && importResult == nil {
                        importButton
                    }
                    
                    Spacer(minLength: 20)
                }
                .padding()
            }
            .navigationTitle(L10n.Import.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.Import.cancel) {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    if importResult != nil {
                        Button(L10n.Import.done) {
                            hashManager.refreshStatusCache()
                            dismiss()
                        }
                    }
                }
            }
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
    
    private var instructionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.Import.instructionTitle, systemImage: "info.circle.fill")
                .font(.headline)
                .foregroundColor(.blue)
            
            Text(L10n.Import.instructionDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text("1.")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(L10n.Import.instructionStep1)
                        .font(.subheadline)
                }
                
                HStack(alignment: .top) {
                    Text("2.")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(L10n.Import.instructionStep2)
                        .font(.subheadline)
                }
                
                HStack(alignment: .top) {
                    Text("3.")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(L10n.Import.instructionStep3)
                        .font(.subheadline)
                }
            }
            .padding(.top, 4)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    private var fileSelectionSection: some View {
        VStack(spacing: 12) {
            Button {
                isShowingFilePicker = true
            } label: {
                HStack {
                    Image(systemName: "doc.badge.plus")
                        .font(.title2)
                    Text(selectedFileURL == nil ? L10n.Import.selectFile : L10n.Import.reselectFile)
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            
            if let url = selectedFileURL {
                HStack {
                    Image(systemName: "doc.fill")
                        .foregroundColor(.blue)
                    Text(url.lastPathComponent)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(8)
            }
        }
    }
    
    private func validationSection(_ validation: (isValid: Bool, recordCount: Int, errorMessage: String?)) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: validation.isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(validation.isValid ? .green : .red)
                    .font(.title2)
                
                Text(validation.isValid ? L10n.Import.validationSuccess : L10n.Import.validationFailed)
                    .font(.headline)
                    .foregroundColor(validation.isValid ? .green : .red)
            }
            
            if validation.isValid {
                HStack {
                    Text(L10n.Import.validationRecordCount)
                        .foregroundColor(.secondary)
                    Text(L10n.Import.validationRecords(validation.recordCount))
                        .fontWeight(.semibold)
                }
            } else if let error = validation.errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundColor(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    private func statisticsSection(_ stats: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.Import.statisticsTitle, systemImage: "chart.bar.fill")
                .font(.headline)
                .foregroundColor(.purple)
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                StatCard(title: L10n.Import.statisticsTotalAssets, value: "\(stats["totalAssets"] as? Int ?? 0)", icon: "photo.stack")
                StatCard(title: L10n.Import.statisticsAssetsWithHash, value: "\(stats["assetsWithChecksum"] as? Int ?? 0)", icon: "checkmark.seal")
                StatCard(title: L10n.Import.statisticsImageCount, value: "\(stats["imageCount"] as? Int ?? 0)", icon: "photo")
                StatCard(title: L10n.Import.statisticsVideoCount, value: "\(stats["videoCount"] as? Int ?? 0)", icon: "video")
            }
            
            if let remoteAssets = stats["remoteAssets"] as? Int,
               let assetsOnServer = stats["assetsOnServer"] as? Int {
                Divider()
                    .padding(.vertical, 4)
                
                Label(L10n.Import.statisticsServerSync, systemImage: "cloud.fill")
                    .font(.headline)
                    .foregroundColor(.green)
                
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    StatCard(title: L10n.Import.statisticsRemoteAssets, value: "\(remoteAssets)", icon: "cloud", color: .green)
                    StatCard(title: L10n.Import.statisticsLocalSynced, value: "\(assetsOnServer)", icon: "checkmark.icloud", color: .green)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    private func importResultSection(_ result: ImmichSQLiteImporter.ImportResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: result.errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(result.errorMessage == nil ? .green : .orange)
                    .font(.title2)
                
                Text(result.errorMessage == nil ? L10n.Import.resultSuccess : L10n.Import.resultError)
                    .font(.headline)
                    .foregroundColor(result.errorMessage == nil ? .green : .orange)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.Import.resultTotalRecords)
                        .foregroundColor(.secondary)
                    Text(L10n.Import.validationRecords(result.totalRecords))
                }
                
                HStack {
                    Text(L10n.Import.resultImportedRecords)
                        .foregroundColor(.secondary)
                    Text(L10n.Import.validationRecords(result.importedRecords))
                        .foregroundColor(.green)
                }
                
                HStack {
                    Image(systemName: "checkmark.icloud.fill")
                        .foregroundColor(.blue)
                    Text(L10n.Import.resultAlreadyOnServer)
                        .foregroundColor(.secondary)
                    Text(L10n.Import.validationRecords(result.alreadyOnServer))
                        .foregroundColor(.blue)
                        .fontWeight(.semibold)
                }
                
                HStack {
                    Text(L10n.Import.resultSkippedRecords)
                        .foregroundColor(.secondary)
                    Text(L10n.Import.validationRecords(result.skippedRecords))
                        .foregroundColor(.orange)
                }
            }
            
            if result.alreadyOnServer > 0 {
                Text(L10n.Import.resultTip)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
            
            if let error = result.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.top, 4)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    private var importButton: some View {
        VStack(spacing: 12) {
            Button {
                performImport()
            } label: {
                HStack {
                    if isImporting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                    Text(isImporting ? L10n.Import.importImporting : L10n.Import.importButton)
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(isImporting ? Color.gray : Color.green)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(isImporting)
            
            if isImporting && importProgress.total > 0 {
                VStack(spacing: 8) {
                    ProgressView(value: Double(importProgress.current), total: Double(importProgress.total))
                        .progressViewStyle(LinearProgressViewStyle())
                    
                    Text(L10n.Import.importProgress(importProgress.current, importProgress.total))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("\(Int(Double(importProgress.current) / Double(importProgress.total) * 100))%")
                        .font(.headline)
                        .foregroundColor(.blue)
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(10)
            }
        }
    }
    
    // MARK: - Actions
    
    private func validateSelectedFile(_ url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        
        let result = ImmichSQLiteImporter.shared.validateFile(fileURL: url)
        validationResult = result
        
        if result.isValid {
            statistics = ImmichSQLiteImporter.shared.getStatistics(fileURL: url)
        } else {
            statistics = nil
        }
        
        importResult = nil
        
        if hasAccess {
            url.stopAccessingSecurityScopedResource()
        }
    }
    
    private func performImport() {
        guard let url = selectedFileURL else { return }
        
        // Stop any ongoing hash processing to avoid conflicts
        let wasProcessing = hashManager.isProcessing
        if wasProcessing {
            hashManager.stopProcessing()
            // Wait a moment for processing to stop
            Thread.sleep(forTimeInterval: 0.3)
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
                
                if let error = result.errorMessage {
                    showAlert(title: L10n.Import.alertImportFailed, message: error)
                }
            }
        }
    }
    
    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showingAlert = true
    }
}

// MARK: - Supporting Views

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var color: Color = .blue
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .cornerRadius(8)
    }
}

// MARK: - Document Picker

struct DocumentPicker: UIViewControllerRepresentable {
    @Binding var fileURL: URL?
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let supportedTypes: [UTType] = [
            UTType(filenameExtension: "sqlite")!,
            UTType(filenameExtension: "db")!,
            UTType(filenameExtension: "sqlite3")!,
            .database,
            .data
        ]
        
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        
        init(_ parent: DocumentPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.fileURL = url
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        }
    }
}

#Preview {
    ImportDatabaseView()
}
