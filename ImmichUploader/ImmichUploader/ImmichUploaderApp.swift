import SwiftUI

@main
struct ImmichUploaderApp: App {
    @StateObject private var settingsManager = SettingsManager()
    @StateObject private var uploadManager = UploadManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settingsManager)
                .environmentObject(uploadManager)
        }
    }
}
