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
    @State private var apiKey: String = ""
    @State private var isLoading: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    
    // Use FocusState for better keyboard management and visual feedback
    @FocusState private var focusedField: Field?
    
    enum Field: Hashable {
        case serverURL
        case apiKey
    }
    
    // Cache trimmed values to avoid repeated computation during rendering
    private var trimmedServerURL: String {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
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
            // Server URL Field
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(L10n.Login.serverURL)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                } icon: {
                    Image(systemName: "server.rack")
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
                        focusedField = .apiKey
                    }
                    .enhancedTextFieldStyle(isFocused: focusedField == .serverURL)
            }
            
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
    
    // MARK: - Login Action
    private func login() {
        isLoading = true
        
        var formattedURL = trimmedServerURL
        if !formattedURL.hasPrefix("http://") && !formattedURL.hasPrefix("https://") {
            formattedURL = "http://" + formattedURL
        }
        if formattedURL.hasSuffix("/") {
            formattedURL = String(formattedURL.dropLast())
        }
        
        let apiKeyToUse = trimmedApiKey
        
        Task {
            do {
                let isValid = try await ImmichAPIService.shared.validateConnection(
                    serverURL: formattedURL,
                    apiKey: apiKeyToUse
                )
                
                await MainActor.run {
                    isLoading = false
                    if isValid {
                        settingsManager.login(
                            serverURL: formattedURL,
                            apiKey: apiKeyToUse
                        )
                    } else {
                        errorMessage = L10n.Login.errorInvalidApiKey
                        showError = true
                    }
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
}

#Preview {
    LoginView()
        .environmentObject(SettingsManager())
}
