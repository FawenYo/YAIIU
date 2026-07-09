# Remove Forced App Restart After Onboarding — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the forced app restart after first-run onboarding by proactively requesting full photo-library authorization in a new dedicated onboarding step, so the background upload extension can later be enabled without `PHPhotosErrorDomain` 3202.

**Architecture:** Insert a new `PhotoPermissionView` gate between `InitialSetupView` and `OnboardingImportView`. It requests full `.readWrite` access and reminds the user that full (not "Select Photos") access is required. Delete `RestartRequiredView` and all restart plumbing. Enabling background upload stays manual in Settings, guarded by `.authorized`.

**Tech Stack:** Swift, SwiftUI, PhotoKit (`PHPhotoLibrary`), Xcode project (manual pbxproj file references), `.strings` localization across 8 locales.

**Testing note:** This repo has no automated test target; verification is compile + manual run per CLAUDE.md. "Verify" steps mean an Xcode build and, for the final task, a physical iOS 26.1+ device run. Commit after each task.

---

## File Structure

- Create: `YAIIU/YAIIU/Views/PhotoPermissionView.swift` — dedicated onboarding permission step.
- Modify: `YAIIU/YAIIU/Services/SettingsManager.swift` — add `hasCompletedPhotoPermission`; remove `needsAppRestart`.
- Modify: `YAIIU/YAIIU/ContentView.swift` — new gate order; remove restart branch.
- Modify: `YAIIU/YAIIU/Views/OnboardingImportView.swift` — remove `showRestartOnComplete` + restart call.
- Delete: `YAIIU/YAIIU/Views/RestartRequiredView.swift`.
- Modify: `YAIIU/YAIIU/Utilities/Localization.swift` — add `PhotoPermission`; remove `RestartRequired`.
- Modify: `YAIIU/YAIIU/Views/BackgroundUploadSettingsView.swift` — add Settings deep-link on auth error.
- Modify: 8× `Localizable.strings` — add `photoPermission.*`; remove `restartRequired.*`.
- Modify: `YAIIU/YAIIU.xcodeproj/project.pbxproj` — add PhotoPermissionView refs; remove RestartRequiredView refs.

---

### Task 1: Add `hasCompletedPhotoPermission` flag and remove restart plumbing in SettingsManager

**Files:**
- Modify: `YAIIU/YAIIU/Services/SettingsManager.swift`

- [ ] **Step 1: Add published flag and key**

In the `@Published` block (after line 11 `hasCompletedInitialSetup`), add:

```swift
    @Published var hasCompletedPhotoPermission: Bool = false
```

Remove this line (currently line 12):

```swift
    @Published var needsAppRestart: Bool = false
```

In the private keys block, after `hasCompletedInitialSetupKey`, add:

```swift
    private let hasCompletedPhotoPermissionKey = "immich_has_completed_photo_permission"
```

Remove this key line:

```swift
    private let needsAppRestartKey = "immich_needs_app_restart"
```

- [ ] **Step 2: Update `loadSettings()`**

Add after the `hasCompletedInitialSetup = ...` load line:

```swift
        hasCompletedPhotoPermission = UserDefaults.standard.bool(forKey: hasCompletedPhotoPermissionKey)
```

Remove the `needsAppRestart` load line and the clear-on-launch block:

```swift
        needsAppRestart = UserDefaults.standard.bool(forKey: needsAppRestartKey)

        // Clear restart flag on app launch - user has restarted the app
        if needsAppRestart {
            needsAppRestart = false
            UserDefaults.standard.set(false, forKey: needsAppRestartKey)
        }
```

- [ ] **Step 3: Update `saveSettings()`**

Add after the `hasCompletedInitialSetup` save line:

```swift
        UserDefaults.standard.set(hasCompletedPhotoPermission, forKey: hasCompletedPhotoPermissionKey)
```

Remove:

```swift
        UserDefaults.standard.set(needsAppRestart, forKey: needsAppRestartKey)
```

- [ ] **Step 4: Reset flag on login and add completion method**

In `login()`, after `self.hasCompletedInitialSetup = false`, add:

```swift
        self.hasCompletedPhotoPermission = false
```

After the existing `completeInitialSetup()` method, add and remove `requestAppRestart()`:

```swift
    func completePhotoPermission() {
        self.hasCompletedPhotoPermission = true
        saveSettings()
    }
```

Remove the entire `requestAppRestart()` method:

```swift
    func requestAppRestart() {
        self.needsAppRestart = true
        saveSettings()
    }
```

- [ ] **Step 5: Build to verify it compiles**

Run: `cd YAIIU && xcodebuild -project YAIIU.xcodeproj -scheme YAIIU -destination 'generic/platform=iOS' build 2>&1 | tail -5`
Expected: build fails ONLY on `ContentView.swift` / `OnboardingImportView.swift` still referencing `needsAppRestart` / `requestAppRestart`. (These are fixed in later tasks.) SettingsManager.swift itself must have no errors.

- [ ] **Step 6: Commit**

```bash
git add YAIIU/YAIIU/Services/SettingsManager.swift
git commit -m "feat: add hasCompletedPhotoPermission flag, remove restart plumbing"
```

---

### Task 2: Create PhotoPermissionView

**Files:**
- Create: `YAIIU/YAIIU/Views/PhotoPermissionView.swift`

- [ ] **Step 1: Create the view file**

Create `YAIIU/YAIIU/Views/PhotoPermissionView.swift`:

```swift
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
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
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
```

- [ ] **Step 2: Register the file in the Xcode project**

Modify `YAIIU/YAIIU.xcodeproj/project.pbxproj`. Reuse the RestartRequiredView slots being freed is not safe (different IDs); instead add four new entries with fresh IDs `2A0000900000000000000001` (build file) and `2A0000910000000000000001` (file ref).

After the OnboardingImportView PBXBuildFile line (line 33), add:

```
		2A0000900000000000000001 /* PhotoPermissionView.swift in Sources */ = {isa = PBXBuildFile; fileRef = 2A0000910000000000000001 /* PhotoPermissionView.swift */; };
```

After the OnboardingImportView PBXFileReference line (line 113), add:

```
		2A0000910000000000000001 /* PhotoPermissionView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PhotoPermissionView.swift; sourceTree = "<group>"; };
```

In the Views group children (near the OnboardingImportView group child, line 230), add:

```
				2A0000910000000000000001 /* PhotoPermissionView.swift */,
```

In the Sources build phase (near the OnboardingImportView Sources line, line 498), add:

```
				2A0000900000000000000001 /* PhotoPermissionView.swift in Sources */,
```

- [ ] **Step 3: Add L10n.PhotoPermission enum**

In `YAIIU/YAIIU/Utilities/Localization.swift`, before the `// MARK: - Restart Required` block (line 403), add:

```swift
    // MARK: - Photo Permission
    enum PhotoPermission {
        static var title: String { "photoPermission.title".localized }
        static var description: String { "photoPermission.description".localized }
        static var grantButton: String { "photoPermission.grantButton".localized }
        static var limitedWarning: String { "photoPermission.limitedWarning".localized }
        static var openSettings: String { "photoPermission.openSettings".localized }
        static var continue_: String { "photoPermission.continue".localized }
    }
```

- [ ] **Step 4: Add strings to all 8 locales**

Add the following keys near the `initialSetup.*` block in each file. Use the localized values below.

`en.lproj`:
```
"photoPermission.title" = "Allow Photo Access";
"photoPermission.description" = "YAIIU needs full access to your photo library to upload photos to Immich. Background upload requires access to all photos, not just a selected subset.";
"photoPermission.grantButton" = "Allow Full Access";
"photoPermission.limitedWarning" = "Full photo access is required. \"Selected Photos\" is not enough for background upload.";
"photoPermission.openSettings" = "Open Settings";
"photoPermission.continue" = "Continue";
```

`zh-Hant.lproj`:
```
"photoPermission.title" = "允許照片存取";
"photoPermission.description" = "YAIIU 需要完整的照片庫存取權限才能上傳照片到 Immich。背景上傳需要存取所有照片，而非僅選取的部分照片。";
"photoPermission.grantButton" = "允許完整存取";
"photoPermission.limitedWarning" = "需要完整照片權限。「選取的照片」不足以支援背景上傳。";
"photoPermission.openSettings" = "開啟設定";
"photoPermission.continue" = "繼續";
```

`zh-Hans.lproj`:
```
"photoPermission.title" = "允许照片访问";
"photoPermission.description" = "YAIIU 需要完整的照片库访问权限才能上传照片到 Immich。后台上传需要访问所有照片，而非仅选取的部分照片。";
"photoPermission.grantButton" = "允许完整访问";
"photoPermission.limitedWarning" = "需要完整照片权限。「选中的照片」不足以支持后台上传。";
"photoPermission.openSettings" = "打开设置";
"photoPermission.continue" = "继续";
```

`ja.lproj`:
```
"photoPermission.title" = "写真へのアクセスを許可";
"photoPermission.description" = "YAIIU が Immich に写真をアップロードするには、写真ライブラリへのフルアクセスが必要です。バックグラウンドアップロードには、選択した一部の写真ではなく、すべての写真へのアクセスが必要です。";
"photoPermission.grantButton" = "フルアクセスを許可";
"photoPermission.limitedWarning" = "フルアクセスが必要です。「選択した写真」ではバックグラウンドアップロードに不十分です。";
"photoPermission.openSettings" = "設定を開く";
"photoPermission.continue" = "続ける";
```

`ko.lproj`:
```
"photoPermission.title" = "사진 접근 허용";
"photoPermission.description" = "YAIIU가 Immich에 사진을 업로드하려면 사진 보관함에 대한 전체 접근 권한이 필요합니다. 백그라운드 업로드는 선택한 일부 사진이 아닌 모든 사진에 대한 접근이 필요합니다.";
"photoPermission.grantButton" = "전체 접근 허용";
"photoPermission.limitedWarning" = "전체 사진 권한이 필요합니다. \"선택한 사진\"으로는 백그라운드 업로드를 지원할 수 없습니다.";
"photoPermission.openSettings" = "설정 열기";
"photoPermission.continue" = "계속";
```

`de.lproj`:
```
"photoPermission.title" = "Fotozugriff erlauben";
"photoPermission.description" = "YAIIU benötigt vollen Zugriff auf deine Fotomediathek, um Fotos zu Immich hochzuladen. Der Hintergrund-Upload benötigt Zugriff auf alle Fotos, nicht nur auf eine Auswahl.";
"photoPermission.grantButton" = "Vollzugriff erlauben";
"photoPermission.limitedWarning" = "Voller Fotozugriff ist erforderlich. \"Ausgewählte Fotos\" reicht für den Hintergrund-Upload nicht aus.";
"photoPermission.openSettings" = "Einstellungen öffnen";
"photoPermission.continue" = "Weiter";
```

`es.lproj`:
```
"photoPermission.title" = "Permitir acceso a fotos";
"photoPermission.description" = "YAIIU necesita acceso completo a tu fototeca para subir fotos a Immich. La subida en segundo plano requiere acceso a todas las fotos, no solo a una selección.";
"photoPermission.grantButton" = "Permitir acceso completo";
"photoPermission.limitedWarning" = "Se requiere acceso completo a las fotos. \"Fotos seleccionadas\" no es suficiente para la subida en segundo plano.";
"photoPermission.openSettings" = "Abrir Ajustes";
"photoPermission.continue" = "Continuar";
```

`fr.lproj`:
```
"photoPermission.title" = "Autoriser l'accès aux photos";
"photoPermission.description" = "YAIIU a besoin d'un accès complet à votre photothèque pour envoyer des photos vers Immich. L'envoi en arrière-plan nécessite l'accès à toutes les photos, et pas seulement à une sélection.";
"photoPermission.grantButton" = "Autoriser l'accès complet";
"photoPermission.limitedWarning" = "Un accès complet aux photos est requis. « Photos sélectionnées » ne suffit pas pour l'envoi en arrière-plan.";
"photoPermission.openSettings" = "Ouvrir les Réglages";
"photoPermission.continue" = "Continuer";
```

- [ ] **Step 5: Build to verify PhotoPermissionView compiles**

Run: `cd YAIIU && xcodebuild -project YAIIU.xcodeproj -scheme YAIIU -destination 'generic/platform=iOS' build 2>&1 | tail -5`
Expected: no errors in `PhotoPermissionView.swift` or `Localization.swift`. Remaining errors, if any, only in `ContentView.swift` / `OnboardingImportView.swift` (fixed next). If `RestartRequiredView.swift` errors because `L10n.RestartRequired` still exists — leave it; it is deleted in Task 4.

- [ ] **Step 6: Commit**

```bash
git add YAIIU/YAIIU/Views/PhotoPermissionView.swift YAIIU/YAIIU/Utilities/Localization.swift YAIIU/YAIIU/Resources/*/Localizable.strings YAIIU/YAIIU.xcodeproj/project.pbxproj
git commit -m "feat: add PhotoPermissionView onboarding step with full-access reminder"
```

---

### Task 3: Wire PhotoPermissionView into ContentView and remove restart branch

**Files:**
- Modify: `YAIIU/YAIIU/ContentView.swift:15-35`

- [ ] **Step 1: Replace the gating block**

Replace the current `Group { ... }` gating body (lines 15-35) with:

```swift
        Group {
            if settingsManager.isLoggedIn {
                if !settingsManager.hasCompletedInitialSetup {
                    InitialSetupView()
                } else if !settingsManager.hasCompletedPhotoPermission {
                    PhotoPermissionView()
                } else if !settingsManager.hasCompletedOnboarding {
                    OnboardingImportView()
                } else {
                    MainTabView()
                }
            } else {
                LoginView()
            }
        }
```

This removes the `needsAppRestart` -> `RestartRequiredView` branch and the
`showRestartOnComplete` iOS-version conditional.

- [ ] **Step 2: Build to verify ContentView compiles**

Run: `cd YAIIU && xcodebuild -project YAIIU.xcodeproj -scheme YAIIU -destination 'generic/platform=iOS' build 2>&1 | tail -5`
Expected: no errors in `ContentView.swift`. `OnboardingImportView()` now called with no args — if it still declares `showRestartOnComplete`, that is fine (it has a default value); Task 4 removes the param. Errors may remain only in `RestartRequiredView.swift` (deleted next).

- [ ] **Step 3: Commit**

```bash
git add YAIIU/YAIIU/ContentView.swift
git commit -m "feat: insert PhotoPermissionView gate, remove restart branch in ContentView"
```

---

### Task 4: Remove restart hook from OnboardingImportView and delete RestartRequiredView

**Files:**
- Modify: `YAIIU/YAIIU/Views/OnboardingImportView.swift:9,330-336,345-348`
- Delete: `YAIIU/YAIIU/Views/RestartRequiredView.swift`
- Modify: `YAIIU/YAIIU.xcodeproj/project.pbxproj`
- Modify: `YAIIU/YAIIU/Utilities/Localization.swift:403-409`
- Modify: 8× `Localizable.strings`

- [ ] **Step 1: Remove `showRestartOnComplete` param and restart call**

In `OnboardingImportView.swift`, remove line 9:

```swift
    var showRestartOnComplete: Bool = false
```

Replace `completeOnboarding()` (lines 330-336) with:

```swift
    private func completeOnboarding() {
        settingsManager.completeOnboarding()
    }
```

The `#Preview` (lines 345-348) already constructs `OnboardingImportView()` with no args — leave it.

- [ ] **Step 2: Delete RestartRequiredView.swift**

```bash
git rm YAIIU/YAIIU/Views/RestartRequiredView.swift
```

- [ ] **Step 3: Remove RestartRequiredView from pbxproj**

In `YAIIU/YAIIU.xcodeproj/project.pbxproj`, delete these four lines (identified by ID `2A0000570000000000000001` and `2A0000580000000000000001`):

```
		2A0000570000000000000001 /* RestartRequiredView.swift in Sources */ = {isa = PBXBuildFile; fileRef = 2A0000580000000000000001 /* RestartRequiredView.swift */; };
```
```
		2A0000580000000000000001 /* RestartRequiredView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RestartRequiredView.swift; sourceTree = "<group>"; };
```
```
				2A0000580000000000000001 /* RestartRequiredView.swift */,
```
```
				2A0000570000000000000001 /* RestartRequiredView.swift in Sources */,
```

- [ ] **Step 4: Remove L10n.RestartRequired enum**

In `Localization.swift`, delete the entire block (lines 403-409):

```swift
    // MARK: - Restart Required
    enum RestartRequired {
        static var title: String { "restartRequired.title".localized }
        static var description: String { "restartRequired.description".localized }
        static var instructions: String { "restartRequired.instructions".localized }
        static var closeApp: String { "restartRequired.closeApp".localized }
    }
```

- [ ] **Step 5: Remove restartRequired strings from all 8 locales**

In each `Localizable.strings` file, delete the four `restartRequired.*` lines:

```
"restartRequired.title" = "...";
"restartRequired.description" = "...";
"restartRequired.instructions" = "...";
"restartRequired.closeApp" = "...";
```

Run to confirm none remain:

```bash
grep -rl "restartRequired" YAIIU/YAIIU/Resources
```
Expected: no output.

- [ ] **Step 6: Build to verify full compile**

Run: `cd YAIIU && xcodebuild -project YAIIU.xcodeproj -scheme YAIIU -destination 'generic/platform=iOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: remove RestartRequiredView and restart hook from onboarding"
```

---

### Task 5: Add Settings deep-link when background upload enable fails on authorization

**Files:**
- Modify: `YAIIU/YAIIU/Views/BackgroundUploadSettingsView.swift`

- [ ] **Step 1: Track auth-error state in the ViewModel**

In `BackgroundUploadSettingsViewModel`, add a published flag after `errorMessage` (line 78):

```swift
    @Published var showOpenSettings: Bool = false
```

In `toggleBackgroundUpload`, in the `catch` block (currently sets `self.errorMessage`), set the flag when the error is the authorization error:

```swift
                } catch {
                    await MainActor.run {
                        self.isLoading = false
                        self.isEnabled = manager.isEnabled
                        self.errorMessage = error.localizedDescription
                        if case BackgroundUploadError.photoLibraryNotAuthorized = error {
                            self.showOpenSettings = true
                        } else {
                            self.showOpenSettings = false
                        }
                    }
                }
```

- [ ] **Step 2: Show the deep-link button in the error section**

In `BackgroundUploadSettingsView.body`, replace the error `Section` (lines 41-51) with:

```swift
            if let errorMessage = viewModel.errorMessage {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(errorMessage)
                            .font(.body)
                            .foregroundColor(.red)
                    }
                    if viewModel.showOpenSettings {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "gear")
                                Text(L10n.PhotoPermission.openSettings)
                            }
                        }
                    }
                }
            }
```

- [ ] **Step 3: Build to verify**

Run: `cd YAIIU && xcodebuild -project YAIIU.xcodeproj -scheme YAIIU -destination 'generic/platform=iOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add YAIIU/YAIIU/Views/BackgroundUploadSettingsView.swift
git commit -m "feat: add Settings deep-link when background upload enable needs full access"
```

---

### Task 6: Manual device verification (iOS 26.1+)

**Files:** none (verification only)

- [ ] **Step 1: Fresh-install happy path**

Delete the app from a physical iOS 26.1+ device. Build and run. Log in.
Expected sequence: `InitialSetupView` (sync) -> `PhotoPermissionView` (tap "Allow Full Access", grant full access in system prompt, tap Continue) -> `OnboardingImportView` (skip or import) -> `MainTabView`. **No restart screen appears.**

- [ ] **Step 2: Enable background upload without 3202**

Go to Settings -> background upload toggle -> turn ON.
Expected: toggle succeeds, no error. Confirm via logs that no `PHPhotosErrorDomain` 3202 is thrown and `setUploadJobExtensionEnabled(true)` succeeds.

- [ ] **Step 3: Persistence across relaunch**

Force-quit and reopen the app.
Expected: goes straight to `MainTabView`; background upload still shows enabled; no permission or restart prompt.

- [ ] **Step 4: Limited-access negative path**

Reinstall. During `PhotoPermissionView`, choose "Select Photos" (limited). 
Expected: warning card + "Open Settings" button shown; Continue still advances to onboarding. In Settings, toggling background upload ON shows the full-access error + "Open Settings" button, no crash.

- [ ] **Step 5: If 3202 still occurs in Step 2 — fallback**

Only if Step 2 reproduces 3202: add a one-time retry in
`BackgroundUploadManager.enableBackgroundUpload()` — on catching the 3202 error, wait briefly
(e.g. `try? await Task.sleep(nanoseconds: 500_000_000)`), re-read `PHPhotoLibrary.shared()`,
and retry `setUploadJobExtensionEnabled(true)` once before surfacing the error. Commit
separately as `fix: retry background upload enable on transient 3202`.

- [ ] **Step 6: Final verification commit (if any fixes made)**

```bash
git add -A
git commit -m "test: verified fresh-install onboarding without forced restart on device"
```

---

## Self-Review Notes

- Spec §"Onboarding Flow": Task 3 implements the new gate order. ✓
- Spec §Components 1-8: Tasks 1-5 cover PhotoPermissionView, ContentView, SettingsManager, OnboardingImportView, RestartRequiredView delete, Localization, BackgroundUploadManager guard (kept, no change needed beyond existing), BackgroundUploadSettingsView deep-link. ✓
- Spec §Component 6 (improve error message): existing `backgroundUpload.error.photoLibraryNotAuthorized` already reads "Full photo library access is required..." in en/zh-Hant — already adequate, no string change needed. Deep-link (Task 5) is the added reminder. ✓
- Spec §"ContentView SettingsView also has a toggle": the duplicate toggle in `ContentView.swift` SettingsView keeps its existing inline error text; deep-link added only in the dedicated `BackgroundUploadSettingsView` per the spec's stated acceptable option. Not a gap.
- Spec §Testing: Task 6 covers all four paths + fallback. ✓
- Method names consistent: `completePhotoPermission()` / `hasCompletedPhotoPermission` used identically in Tasks 1 and 3. ✓
- No placeholders; all code shown in full.
