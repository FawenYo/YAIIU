import SwiftUI

// MARK: - Custom Text Field Style for better UI/UX
struct EnhancedTextFieldStyle: ViewModifier {
    let isFocused: Bool
    
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isFocused ? Color.blue : Color.clear, lineWidth: 2)
            )
            .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}

extension View {
    func enhancedTextFieldStyle(isFocused: Bool) -> some View {
        modifier(EnhancedTextFieldStyle(isFocused: isFocused))
    }
}

struct LoginView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    
    @State private var serverURL: String = ""
    @State private var internalServerURL: String = ""
    @State private var wifiSSID: String = ""
    @State private var apiKey: String = ""
    @State private var isLoading: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var showAdvancedSettings: Bool = false
    @State private var currentSSID: String?
    
    // Use FocusState for better keyboard management and visual feedback
    @FocusState private var focusedField: Field?
    
    enum Field: Hashable {
        case serverURL
        case internalServerURL
        case wifiSSID
        case apiKey
    }
    
    // Cache trimmed values to avoid repeated computation during rendering
    private var trimmedServerURL: String {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private var trimmedInternalServerURL: String {
        internalServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private var trimmedApiKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private var isValidInput: Bool {
        !trimmedServerURL.isEmpty && !trimmedApiKey.isEmpty
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 32) {
                    // Logo and Title
                    headerSection
                    
                    // Input Fields
                    inputFieldsSection
                    
                    // Login Button
                    loginButtonSection
                    
                    // iOS 26.1+ Background Upload Note
                    backgroundUploadNoteSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationBarHidden(true)
            .alert(L10n.Login.errorTitle, isPresented: $showError) {
                Button(L10n.Login.errorOk, role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
            .onTapGesture {
                // Dismiss keyboard when tapping outside
                focusedField = nil
            }
        }
        .navigationViewStyle(.stack)
    }
    
    // MARK: - Header Section
    private var headerSection: some View {
        VStack(spacing: 16) {
            // App icon with gradient background
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.2), Color.blue.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 50, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.blue, Color.blue.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            
            VStack(spacing: 8) {
                Text(L10n.Login.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                
                Text(L10n.Login.subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 20)
    }
    
    // MARK: - Input Fields Section
    private var inputFieldsSection: some View {
        VStack(spacing: 24) {
            // Server URL Field (External/Public)
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(L10n.Login.serverURL)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                } icon: {
                    Image(systemName: "globe")
                        .font(.subheadline)
                }
                .foregroundColor(.primary)
                
                TextField(L10n.Login.serverURLPlaceholder, text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($focusedField, equals: .serverURL)
                    .submitLabel(.next)
                    .onSubmit {
                        if showAdvancedSettings {
                            focusedField = .internalServerURL
                        } else {
                            focusedField = .apiKey
                        }
                    }
                    .enhancedTextFieldStyle(isFocused: focusedField == .serverURL)
            }
            
            // Advanced Settings Toggle
            advancedSettingsSection
            
            // API Key Field
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(L10n.Login.apiKey)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                } icon: {
                    Image(systemName: "key.fill")
                        .font(.subheadline)
                }
                .foregroundColor(.primary)
                
                SecureField(L10n.Login.apiKeyPlaceholder, text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .apiKey)
                    .submitLabel(.go)
                    .onSubmit {
                        if isValidInput {
                            login()
                        }
                    }
                    .enhancedTextFieldStyle(isFocused: focusedField == .apiKey)
            }
        }
    }
    
    // MARK: - Advanced Settings Section
    private var advancedSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showAdvancedSettings.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: showAdvancedSettings ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(L10n.Login.advancedSettings)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            
            if showAdvancedSettings {
                VStack(spacing: 20) {
                    // Internal Server URL Field
                    VStack(alignment: .leading, spacing: 10) {
                        Label {
                            Text(L10n.Login.internalServerURL)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        } icon: {
                            Image(systemName: "network")
                                .font(.subheadline)
                        }
                        .foregroundColor(.primary)
                        
                        TextField(L10n.Login.internalServerURLPlaceholder, text: $internalServerURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .focused($focusedField, equals: .internalServerURL)
                            .submitLabel(.next)
                            .onSubmit {
                                focusedField = .wifiSSID
                            }
                            .enhancedTextFieldStyle(isFocused: focusedField == .internalServerURL)
                        
                        Text(L10n.Login.internalServerURLHint)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    
                    // WiFi SSID Field
                    VStack(alignment: .leading, spacing: 10) {
                        Label {
                            Text(L10n.Settings.wifiSSID)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        } icon: {
                            Image(systemName: "wifi")
                                .font(.subheadline)
                        }
                        .foregroundColor(.primary)
                        
                        TextField(L10n.Settings.wifiSSIDPlaceholder, text: $wifiSSID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .wifiSSID)
                            .submitLabel(.next)
                            .onSubmit {
                                focusedField = .apiKey
                            }
                            .enhancedTextFieldStyle(isFocused: focusedField == .wifiSSID)
                        
                        // Use current WiFi button
                        if let currentSSID = currentSSID, !currentSSID.isEmpty {
                            Button(action: {
                                wifiSSID = currentSSID
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "wifi")
                                        .font(.caption)
                                    Text(L10n.Settings.useCurrentWiFi)
                                        .font(.caption)
                                    Text("(\(currentSSID))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.blue)
                        }
                        
                        Text(L10n.Settings.wifiSSIDHint)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
                .onAppear {
                    currentSSID = NetworkReachability.shared.getCurrentWiFiSSID()
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Login Button Section
    private var loginButtonSection: some View {
        VStack(spacing: 16) {
            Button(action: {
                focusedField = nil
                login()
            }) {
                HStack(spacing: 10) {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.9)
                    } else {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 18))
                    }
                    
                    Text(isLoading ? L10n.Login.buttonConnecting : L10n.Login.button)
                        .font(.headline)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Group {
                        if isValidInput && !isLoading {
                            LinearGradient(
                                colors: [Color.blue, Color.blue.opacity(0.85)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        } else {
                            LinearGradient(
                                colors: [Color.gray.opacity(0.5), Color.gray.opacity(0.4)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        }
                    }
                )
                .foregroundColor(.white)
                .cornerRadius(14)
                .shadow(color: isValidInput ? Color.blue.opacity(0.3) : Color.clear, radius: 8, x: 0, y: 4)
            }
            .disabled(!isValidInput || isLoading)
            .animation(.easeInOut(duration: 0.2), value: isValidInput)
            .animation(.easeInOut(duration: 0.2), value: isLoading)
        }
        .padding(.top, 8)
    }
    
    // MARK: - Background Upload Note Section
    private var backgroundUploadNoteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(L10n.Login.backgroundUploadNoteTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)
            }
            
            Text(L10n.Login.backgroundUploadNoteMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            if let url = URL(string: L10n.Login.backgroundUploadNoteLink) {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text(L10n.Login.backgroundUploadNoteLearnMore)
                            .font(.caption)
                            .fontWeight(.medium)
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                    }
                    .foregroundColor(.blue)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
    
    private var trimmedWifiSSID: String {
        wifiSSID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Login Action
    private func login() {
        isLoading = true
        
        let formattedURL = formatURL(trimmedServerURL)
        let formattedInternalURL = trimmedInternalServerURL.isEmpty ? nil : formatURL(trimmedInternalServerURL)
        let ssidToUse = trimmedWifiSSID.isEmpty ? nil : trimmedWifiSSID
        let apiKeyToUse = trimmedApiKey
        
        Task {
            do {
                _ = try await ImmichAPIService.shared.getCurrentUser(
                    serverURL: formattedURL,
                    apiKey: apiKeyToUse
                )
                
                await MainActor.run {
                    isLoading = false
                    settingsManager.login(
                        serverURL: formattedURL,
                        apiKey: apiKeyToUse,
                        internalServerURL: formattedInternalURL,
                        ssid: ssidToUse
                    )
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = L10n.Login.errorConnectionFailed(error.localizedDescription)
                    showError = true
                }
            }
        }
    }
    
    /// Formats a URL by adding protocol prefix and removing trailing slash
    private func formatURL(_ url: String) -> String {
        var formatted = url
        if !formatted.hasPrefix("http://") && !formatted.hasPrefix("https://") {
            formatted = "http://" + formatted
        }
        if formatted.hasSuffix("/") {
            formatted = String(formatted.dropLast())
        }
        return formatted
    }
}

#Preview {
    LoginView()
        .environmentObject(SettingsManager())
}
