# Background Upload Cellular Data

## Purpose
YAIIU background uploads may create new PhotoKit upload jobs only when the current network satisfies the user's cellular-data preference. This prevents unexpected cellular data use while preserving retry and acknowledgement processing for jobs already owned by PhotoKit.

## Design
`BackgroundUploadPolicy.canCreateNewJobs(allowCellular:interface:)` is a Foundation-only pure function in `YAIIU/Shared/BackgroundUploadPolicy.swift`, compiled into both the app and extension. Wi-Fi is always accepted when connected. Cellular is accepted only when cellular data is allowed. Other interfaces and unavailable paths are always rejected. `BackgroundUploadExtension` owns an `NWPathMonitor`, converts the latest path into the shared enum, and checks policy immediately before discovering/creating new jobs. Retry and acknowledgement run before this gate and are never skipped by the preference.

## Settings
`SharedSettings.allowCellularBackgroundUpload` uses the App Group key `immich_allow_cellular_background_upload`. Missing values default to `true` for backwards compatibility. `SettingsManager` mirrors the value in app defaults, exposes `updateAllowCellularBackgroundUpload(_:)`, and syncs it to the extension. Logout/reset restores the default.

## Localization
The Settings toggle uses `backgroundUpload.allowCellular`, translated in all supported locales: English, Traditional Chinese, Simplified Chinese, Japanese, Korean, Spanish, German, and French.

## Limits
The extension network monitor starts when the extension is initialized. Until the initial path callback arrives, new jobs are conservatively withheld and `process()` returns `.processing` so Photos can invoke the extension again. A confirmed unsatisfied path is treated as unavailable and leaves new jobs withheld without requesting processing. Already-created jobs continue through retry/acknowledgement. The setting does not disable foreground uploads or PhotoKit jobs already scheduled by the system.

## Testing
`YAIIUTests/BackgroundUploadPolicyTests.swift` covers disallowed cellular/non-Wi-Fi interfaces, allowed Wi-Fi/cellular/other interfaces, and unavailable connectivity. Run the focused test with:

```sh
xcodebuild -project YAIIU/YAIIU.xcodeproj -scheme YAIIU \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:YAIIUTests/BackgroundUploadPolicyTests test
```
