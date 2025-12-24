import SwiftUI

struct LoginView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    
    @State private var serverURL: String = ""
    @State private var apiKey: String = ""
    @State private var isLoading: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                // Logo and Title
                VStack(spacing: 16) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 80))
                        .foregroundColor(.blue)
                    
                    Text(L10n.Login.title)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text(L10n.Login.subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 40)
                
                Spacer()
                
                // Input Fields
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.Login.serverURL)
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        TextField(L10n.Login.serverURLPlaceholder, text: $serverURL)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.Login.apiKey)
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        SecureField(L10n.Login.apiKeyPlaceholder, text: $apiKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }
                .padding(.horizontal, 30)
                
                Spacer()
                
                // Login Button
                Button(action: {
                    login()
                }) {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .padding(.trailing, 8)
                        }
                        Text(isLoading ? L10n.Login.buttonConnecting : L10n.Login.button)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isValidInput ? Color.blue : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(!isValidInput || isLoading)
                .padding(.horizontal, 30)
                .padding(.bottom, 50)
            }
            .navigationBarHidden(true)
            .alert(L10n.Login.errorTitle, isPresented: $showError) {
                Button(L10n.Login.errorOk, role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private var isValidInput: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private func login() {
        isLoading = true
        
        var formattedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !formattedURL.hasPrefix("http://") && !formattedURL.hasPrefix("https://") {
            formattedURL = "http://" + formattedURL
        }
        if formattedURL.hasSuffix("/") {
            formattedURL = String(formattedURL.dropLast())
        }
        
        Task {
            do {
                let isValid = try await ImmichAPIService.shared.validateConnection(
                    serverURL: formattedURL,
                    apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                
                await MainActor.run {
                    isLoading = false
                    if isValid {
                        settingsManager.login(
                            serverURL: formattedURL,
                            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
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
