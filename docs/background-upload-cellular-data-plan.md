# Background Upload Cellular Data Implementation Plan

1. Add the Foundation-only `BackgroundUploadPolicy` and `BackgroundUploadNetworkInterface` to `YAIIU/Shared`, then include that source in the YAIIU and BackgroundUploadExtension targets.
2. Add a failing XCTest for policy decisions before implementation and run the focused test to prove the missing contract.
3. Add `SharedSettings.allowCellularBackgroundUpload` with a true fallback, App Group synchronization, and reset behavior; mirror it through `SettingsManager` and `BackgroundUploadManager`.
4. Add the localized Settings toggle and accessor for all eight supported languages.
5. Start `NWPathMonitor` in `BackgroundUploadExtension`, map `NWPath` to the shared interface enum, and gate only `createNewUploadJobs`; leave retry and acknowledgement unconditional.
6. Run the focused XCTest and extension/app simulator build, inspect the diff, and retain the documented simulator/device limitation for real background execution.

The policy remains pure and independently testable; platform-specific network monitoring stays in the extension. Existing installations retain cellular uploads unless the user turns the toggle off.
