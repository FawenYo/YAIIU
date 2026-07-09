# Remove Forced App Restart After Onboarding

Date: 2026-07-09

## Problem

On a fresh install (iOS 26.1+), after the user finishes login and onboarding, the app
forces a full restart via `RestartRequiredView` (which calls `exit(0)`). The user must
manually reopen the app before reaching the main UI.

This restart was introduced as a blanket workaround for `PHPhotosErrorDomain` error 3202,
which occurs when enabling the background upload extension
(`setUploadJobExtensionEnabled(true)`) shortly after a fresh install.

The workaround has two problems:

1. **Bad UX** — forcing the user to kill and reopen the app during first-run setup.
2. **Decoupled from the real failure** — the restart happens at the end of onboarding, but
   3202 actually fires later, at the moment the user manually toggles background upload ON
   in Settings. Enabling the extension does not happen during onboarding at all.

## Root Cause

Per Apple's documentation (`background_upload.md`, "Enable the extension"):

> Your app must have full library access before enabling the extension. Call
> `requestAuthorization(for: .readWrite)` with the `.readWrite` access level and verify the
> status is `.authorized`.

`setUploadJobExtensionEnabled(true)` requires **full** photo library authorization
(`.authorized` — not `.limited`) in a process where the Photos framework holds clean
authorized state.

In the current flow, the first photo authorization request happens lazily in
`PhotoGridView.onAppear`, and that call accepts `.limited` as sufficient for browsing. Full
authorization is never proactively requested early in the process lifetime. The forced
restart gave the extension a fresh process with clean authorized state as a crutch.

## Approach

Two coordinated changes:

1. **Proactively request full `.readWrite` authorization during onboarding**, in a new
   dedicated permission step, so the process holds full authorized state before the user
   ever reaches the main app or the Settings toggle.
2. **Remove the forced restart entirely.**

Background upload enabling stays **manual** — the user decides in Settings whether to turn
it on. We do not auto-enable the extension.

Because `.limited` (partial photo selection) is insufficient for the extension, the user
must be explicitly guided to grant **full** photo access, and the app must handle the case
where the user picks "Select Photos" (`.limited`) or denies.

## Onboarding Flow (after change)

```
Login
  -> InitialSetupView        (server asset sync — unchanged)
  -> PhotoPermissionView     (NEW — request full photo access)
  -> OnboardingImportView    (optional DB import — unchanged, restart hook removed)
  -> MainTabView
```

The `hasCompletedInitialSetup` / `hasCompletedOnboarding` gates are preserved. A new gate is
added between them for the permission step.

## Components

### 1. PhotoPermissionView (new)

`YAIIU/YAIIU/Views/PhotoPermissionView.swift`

Single-purpose onboarding step. Responsibilities:

- Explain **why** full photo access is needed: the app uploads photos to Immich, and
  background upload requires access to all photos (not just a selected subset).
- On an explicit button tap, call `PHPhotoLibrary.requestAuthorization(for: .readWrite)`.
- Inspect the resulting status:
  - `.authorized` — success state; enable the Continue button.
  - `.limited` — warning: full access is required for background upload; show a button
    that deep-links to `UIApplication.openSettingsURLString`. User may still Continue
    (the app functions with limited access for foreground browsing, but background upload
    will be unavailable until upgraded).
  - `.denied` / `.restricted` — warning + Settings deep-link. User may still Continue.
  - `.notDetermined` — initial state; show the primary "Grant access" button.
- On leaving the step, call the setup manager to mark the permission step complete.

The view does **not** hard-block progression on non-full access. It informs and provides a
path to fix, but lets the user proceed so they are never trapped in setup.

State handling: read current status on appear via `PHPhotoLibrary.authorizationStatus(for:
.readWrite)` so a returning user (who already granted) sees the success state immediately.

### 2. ContentView (modify)

`YAIIU/YAIIU/ContentView.swift`

- Insert the `PhotoPermissionView` gate between `hasCompletedInitialSetup` and
  `hasCompletedOnboarding`.
- Remove the `needsAppRestart` -> `RestartRequiredView` branch.
- Remove the `showRestartOnComplete` iOS-version conditional around `OnboardingImportView`;
  it is always constructed the same way now.

New gate order:

```
if !hasCompletedInitialSetup      -> InitialSetupView
else if !hasCompletedPhotoPermission -> PhotoPermissionView
else if !hasCompletedOnboarding   -> OnboardingImportView
else                              -> MainTabView
```

### 3. SettingsManager (modify)

`YAIIU/YAIIU/Services/SettingsManager.swift`

- Add `hasCompletedPhotoPermission` published flag, backing UserDefaults key, load/save
  lines, reset on `login()`, and a `completePhotoPermission()` method mirroring the existing
  `completeInitialSetup()` / `completeOnboarding()`.
- Remove `needsAppRestart` property, `needsAppRestartKey`, its load/save lines, the launch
  clear-on-load block, and the `requestAppRestart()` method.

### 4. OnboardingImportView (modify)

`YAIIU/YAIIU/Views/OnboardingImportView.swift`

- Remove the `showRestartOnComplete` parameter.
- In `completeOnboarding()`, remove the `requestAppRestart()` call. It now only calls
  `settingsManager.completeOnboarding()`.

### 5. RestartRequiredView (delete)

- Delete `YAIIU/YAIIU/Views/RestartRequiredView.swift`.
- Remove its Xcode project reference.

### 6. BackgroundUploadManager (modify — safety net)

`YAIIU/YAIIU/Services/BackgroundUploadManager.swift`

- Keep the existing `status == .authorized` guard in `enableBackgroundUpload()`.
- No auto-enable. Enabling remains user-driven via Settings.
- The reactive error path already throws `BackgroundUploadError.photoLibraryNotAuthorized`
  when status is not full. Improve the message to explicitly state that full access (not
  "Select Photos") is required. See L10n changes.

### 7. BackgroundUploadSettingsView (modify — safety net)

`YAIIU/YAIIU/Views/BackgroundUploadSettingsView.swift`

- When enabling fails with `photoLibraryNotAuthorized`, in addition to the error text,
  surface a button that deep-links to `UIApplication.openSettingsURLString` so the user can
  upgrade to full access. (The ContentView `SettingsView` also contains a background upload
  toggle; apply the same treatment there for consistency, or keep the error text there and
  the deep-link only in the dedicated `BackgroundUploadSettingsView`.)

### 8. Localization (modify)

- Add `L10n.PhotoPermission` enum in `YAIIU/YAIIU/Utilities/Localization.swift` with keys
  for: title, description (explaining full access need), grant button, granted state,
  limited/denied warning, open-settings button, continue button.
- Remove the `L10n.RestartRequired` enum.
- Improve `backgroundUpload.error.photoLibraryNotAuthorized` string to mention full access.
- Add/remove the corresponding keys in all 8 `Localizable.strings` files:
  `en, zh-Hant, zh-Hans, ja, ko, de, es, fr`. Remove the `restartRequired.*` keys from each.

## Data Flow

1. User logs in -> `SettingsManager.login()` resets all three setup flags to false.
2. `InitialSetupView` runs server sync -> `completeInitialSetup()` -> flag true.
3. `PhotoPermissionView` requests `.readWrite`; regardless of result the user taps Continue
   -> `completePhotoPermission()` -> flag true. Full authorization (if granted here) means
   the process now holds clean `.authorized` state for the rest of its lifetime.
4. `OnboardingImportView` optional import -> `completeOnboarding()` -> flag true.
5. `MainTabView` shown. No restart.
6. Later, in Settings, user toggles background upload ON. Because full authorization was
   granted early in this process, `setUploadJobExtensionEnabled(true)` succeeds without 3202.

## Error Handling

- Permission `.limited` / `.denied` / `.restricted`: non-blocking warning + Settings
  deep-link in `PhotoPermissionView`; reactive error + deep-link at the Settings toggle.
- Background upload enable still guarded by `.authorized`; throws a clear, full-access
  error message when insufficient.

## Testing (real device, iOS 26.1+)

1. Fresh install -> login -> `InitialSetupView` -> `PhotoPermissionView`: grant **full**
   access -> `OnboardingImportView` -> lands in `MainTabView`. **No restart.**
2. Settings -> toggle background upload ON -> confirm **no 3202**; extension enables;
   `PHPhotoLibrary.shared().uploadJobExtensionEnabled == true`.
3. Relaunch app -> extension still enabled; no restart prompt anywhere.
4. Negative path: at `PhotoPermissionView`, pick "Select Photos" (`.limited`) -> warning +
   Settings deep-link shown -> Continue still works -> in Settings, toggling background
   upload ON shows the full-access error + deep-link, does not crash.

## Open Risk / Fallback

If test step 2 still reproduces 3202 on device even with early full authorization, add a
one-time retry inside `enableBackgroundUpload()` (short delay and/or re-fetch of the shared
library instance before a single retry). This fallback is only added if the device test
reproduces 3202 — not implemented preemptively (YAGNI).

## Out of Scope

- Auto-enabling background upload during onboarding.
- Any change to the immich-proxy component.
- Migration for existing users (they already passed the old restart; the removed
  `needsAppRestart` key simply becomes unused and is cleared on next login).
