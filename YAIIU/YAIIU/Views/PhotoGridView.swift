import SwiftUI
import Photos

// MARK: - Photo Filter Options

enum PhotoFilterOption: String, CaseIterable, Identifiable {
    case all
    case notUploaded
    
    var id: String { rawValue }
    
    var localizedTitle: String {
        switch self {
        case .all:
            return L10n.PhotoGrid.filterAll
        case .notUploaded:
            return L10n.PhotoGrid.filterNotUploaded
        }
    }
    
    var iconName: String {
        switch self {
        case .all:
            return "photo.on.rectangle"
        case .notUploaded:
            return "icloud.slash"
        }
    }
}

// MARK: - PhotoGridView

struct PhotoGridView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var uploadManager: UploadManager
    @StateObject private var photoLibraryManager = PhotoLibraryManager()
    @ObservedObject private var hashManager = HashManager.shared
    
    @State private var selectedAssets: Set<String> = []
    @State private var isSelectionMode = false
    @State private var showingPermissionAlert = false
    @State private var showingUploadConfirmation = false
    @State private var hasAppeared = false
    @State private var isSyncing = false
    @State private var currentFilter: PhotoFilterOption = .all
    
    // Cached filter results
    @State private var filteredIndices: [Int] = []
    @State private var cachedNotUploadedCount: Int = 0
    @State private var isFilteringInProgress = false
    @State private var filterCacheVersion: Int = 0
    
    // Task management for background processing
    @State private var processingTask: Task<Void, Never>?
    
    // Photo detail view states
    @State private var selectedPhotoIndex: Int = 0
    @State private var showingPhotoDetail = false
    @Namespace private var photoTransitionNamespace
    
    // Navigation title state (driven by UICollectionView)
    @State private var currentVisibleDate: String = ""
    @State private var isFirstItemVisible: Bool = true
    
    // Scroll control for timeline scrubber
    @State private var scrollToIndex: Int? = nil
    
    // Pull-to-refresh state
    @State private var isRefreshing = false
    
    private var displayCount: Int {
        switch currentFilter {
        case .all:
            return photoLibraryManager.assetCount
        case .notUploaded:
            return filteredIndices.count
        }
    }
    
    /// Navigation title: shows "Photo Library" when first item visible, date otherwise
    private var navigationTitle: String {
        if isFirstItemVisible {
            return L10n.PhotoGrid.title
        }
        if !currentVisibleDate.isEmpty {
            return currentVisibleDate
        }
        return L10n.PhotoGrid.title
    }
    
    var body: some View {
        ZStack {
            NavigationView {
                Group {
                    if photoLibraryManager.authorizationStatus == .authorized ||
                       photoLibraryManager.authorizationStatus == .limited {
                        photoGridContent
                    } else if photoLibraryManager.authorizationStatus == .notDetermined {
                        requestPermissionView
                    } else {
                        deniedPermissionView
                    }
                }
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        if isSelectionMode {
                            Button(L10n.PhotoGrid.cancel) {
                                isSelectionMode = false
                                selectedAssets.removeAll()
                            }
                        } else {
                            HStack(spacing: 8) {
                                processingStatusView
                                filterMenuButton
                            }
                        }
                    }
                    
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if !isSelectionMode {
                            Button(L10n.PhotoGrid.select) {
                                isSelectionMode = true
                            }
                            .disabled(displayCount == 0)
                        } else {
                            Button(L10n.PhotoGrid.upload(selectedAssets.count)) {
                                showingUploadConfirmation = true
                            }
                            .disabled(selectedAssets.isEmpty)
                        }
                    }
                }
                .alert(L10n.PhotoGrid.confirmTitle, isPresented: $showingUploadConfirmation) {
                    Button(L10n.PhotoGrid.confirmCancel, role: .cancel) { }
                    Button(L10n.PhotoGrid.confirmUpload) {
                        uploadSelectedPhotos()
                    }
                } message: {
                    Text(L10n.PhotoGrid.confirmMessage(selectedAssets.count))
                }
            }
            .navigationViewStyle(.stack)
            .toolbar(showingPhotoDetail ? .hidden : .visible, for: .tabBar)
            .animation(.easeInOut(duration: 0.2), value: showingPhotoDetail)
            
            if showingPhotoDetail && displayCount > 0 {
                PhotoDetailView(
                    photoLibraryManager: photoLibraryManager,
                    displayIndices: currentFilter == .all ? nil : filteredIndices,
                    initialIndex: selectedPhotoIndex,
                    namespace: photoTransitionNamespace,
                    isPresented: $showingPhotoDetail
                )
                .zIndex(1)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .onAppear {
            if !hasAppeared {
                hasAppeared = true
                photoLibraryManager.requestAuthorization()
                performAutoSync()
            }
        }
        .onChange(of: photoLibraryManager.isLoading) { oldValue, newValue in
            if oldValue == true && newValue == false {
                processingTask?.cancel()
                processingTask = Task(priority: .background) {
                    if Task.isCancelled { return }
                    
                    await MainActor.run {
                        guard !Task.isCancelled, !photoLibraryManager.isLoading else { return }
                        updateNotUploadedCount()
                        if currentFilter == .notUploaded {
                            refreshFilterCache()
                        }
                    }
                }
            }
        }
        .onChange(of: uploadManager.isUploading) { oldValue, newValue in
            if oldValue == true && newValue == false {
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await MainActor.run {
                        hashManager.refreshStatusCache()
                        updateNotUploadedCount()
                        if currentFilter == .notUploaded {
                            refreshFilterCache()
                        }
                    }
                }
            }
        }
        .onChange(of: hashManager.isProcessing) { oldValue, newValue in
            if oldValue == true && newValue == false {
                updateNotUploadedCount()
                if currentFilter == .notUploaded {
                    refreshFilterCache()
                }
            }
        }
    }
    
    @ViewBuilder
    private var processingStatusView: some View {
        if hashManager.isProcessing {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                
                Text(getProcessingStatusText())
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } else {
            EmptyView()
        }
    }
    
    private func getProcessingStatusText() -> String {
        let progress = hashManager.processedAssetsCount
        let total = hashManager.totalAssetsToProcess
        
        if hashManager.statusMessage.contains("分析") || hashManager.statusMessage.contains("Analyzing") {
            if total > 0 && progress > 0 {
                return "\(progress)/\(total)"
            }
            return L10n.PhotoGrid.processingPreparing
        } else if hashManager.statusMessage.contains("確認") || hashManager.statusMessage.contains("Checking") {
            if total > 0 && progress > 0 {
                return L10n.PhotoGrid.processingComparing(progress, total)
            }
            return L10n.PhotoGrid.processingChecking
        } else if hashManager.statusMessage.contains("準備") || hashManager.statusMessage.contains("Preparing") {
            return L10n.PhotoGrid.processingPreparing
        } else {
            return L10n.PhotoGrid.processingDefault
        }
    }
    
    private func startBackgroundProcessing() {
        guard photoLibraryManager.assetCount > 0 else { return }
        
        let manager = photoLibraryManager
        Task.detached(priority: .utility) {
            let identifiers = manager.allLocalIdentifiers()
            await MainActor.run {
                HashManager.shared.startBackgroundProcessing(identifiers: identifiers)
            }
        }
    }
    
    // MARK: - Photo Grid Content
    
    private var photoGridContent: some View {
        VStack(spacing: 0) {
            if currentFilter != .all {
                filterIndicatorView
            }
            
            ZStack {
                // Main content: UICollectionView-based grid with Timeline Scrubber
                collectionGridView
                
                if isFilteringInProgress && currentFilter != .all {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                }
            }
        }
    }
    
    // MARK: - UICollectionView-based Grid
    
    private var collectionGridView: some View {
        ZStack(alignment: .trailing) {
            PhotoCollectionView(
                photoLibraryManager: photoLibraryManager,
                hashManager: hashManager,
                displayIndices: currentFilter == .all ? nil : filteredIndices,
                isSelectionMode: isSelectionMode,
                selectedAssets: $selectedAssets,
                onItemTap: { displayIndex in
                    handleItemTap(displayIndex: displayIndex)
                },
                onItemLongPress: { displayIndex in
                    handleItemLongPress(displayIndex: displayIndex)
                },
                onVisibleDateChanged: { date in
                    currentVisibleDate = date
                },
                onFirstItemVisibilityChanged: { isVisible in
                    isFirstItemVisible = isVisible
                },
                scrollToIndex: $scrollToIndex,
                onRefresh: {
                    performRefresh()
                },
                isRefreshing: $isRefreshing
            )
            
            // Timeline Scrubber (only show when not in selection mode and has photos)
            if !isSelectionMode && displayCount > 0 && currentFilter == .all {
                TimelineScrubberView(
                    photoLibraryManager: photoLibraryManager,
                    totalCount: displayCount,
                    onScrollToIndex: { index in
                        scrollToIndex = index
                    }
                )
            }
        }
    }
    
    // MARK: - Item Interaction Handlers
    
    private func handleItemTap(displayIndex: Int) {
        let actualIndex = resolveActualIndex(displayIndex)
        
        if isSelectionMode {
            toggleSelection(at: actualIndex)
        } else {
            openPhotoDetail(at: displayIndex)
        }
    }
    
    private func handleItemLongPress(displayIndex: Int) {
        let actualIndex = resolveActualIndex(displayIndex)
        
        if !isSelectionMode {
            isSelectionMode = true
            if let id = photoLibraryManager.localIdentifier(at: actualIndex) {
                selectedAssets.insert(id)
            }
        }
    }
    
    private func resolveActualIndex(_ displayIndex: Int) -> Int {
        switch currentFilter {
        case .all:
            return displayIndex
        case .notUploaded:
            guard displayIndex < filteredIndices.count else { return displayIndex }
            return filteredIndices[displayIndex]
        }
    }
    
    // MARK: - Filter UI
    
    private var filterIndicatorView: some View {
        HStack {
            Image(systemName: currentFilter.iconName)
                .foregroundColor(.orange)
            if isFilteringInProgress {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Text(L10n.PhotoGrid.filterActive(displayCount))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                currentFilter = .all
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }
    
    @ViewBuilder
    private var filterMenuButton: some View {
        if !hashManager.isProcessing {
            Menu {
                ForEach(PhotoFilterOption.allCases) { option in
                    Button {
                        applyFilter(option)
                    } label: {
                        Label {
                            if option == .notUploaded {
                                Text("\(option.localizedTitle) (\(cachedNotUploadedCount))")
                            } else {
                                Text(option.localizedTitle)
                            }
                        } icon: {
                            if currentFilter == option {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: currentFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .foregroundColor(currentFilter == .all ? .primary : .orange)
            }
        }
    }
    
    // MARK: - Filter Cache Management
    
    private func applyFilter(_ filter: PhotoFilterOption) {
        if isSelectionMode {
            selectedAssets.removeAll()
        }
        
        currentFilter = filter
        
        if filter == .notUploaded {
            refreshFilterCache()
        }
    }
    
    private func refreshFilterCache() {
        guard !isFilteringInProgress else { return }
        
        isFilteringInProgress = true
        filterCacheVersion += 1
        let currentVersion = filterCacheVersion
        
        let totalCount = photoLibraryManager.assetCount
        let statusCache = hashManager.syncStatusCache
        let manager = photoLibraryManager
        
        Task.detached(priority: .userInitiated) {
            var indices: [Int] = []
            indices.reserveCapacity(totalCount / 4)
            
            if let fetchResult = manager.fetchResult {
                fetchResult.enumerateObjects { (asset, index, _) in
                    let status = statusCache[asset.localIdentifier] ?? .pending
                    if status != .uploaded {
                        indices.append(index)
                    }
                }
            }
            
            await MainActor.run {
                guard currentVersion == self.filterCacheVersion else { return }
                
                self.filteredIndices = indices
                self.cachedNotUploadedCount = indices.count
                self.isFilteringInProgress = false
            }
        }
    }
    
    private func updateNotUploadedCount() {
        let totalCount = photoLibraryManager.assetCount
        let statusCache = hashManager.syncStatusCache
        
        let uploadedCount = statusCache.values.filter { $0 == .uploaded }.count
        let notUploadedCount = max(0, totalCount - uploadedCount)
        
        cachedNotUploadedCount = notUploadedCount
    }
    
    private func openPhotoDetail(at index: Int) {
        selectedPhotoIndex = index
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            showingPhotoDetail = true
        }
    }
    
    // MARK: - Permission Views
    
    private var requestPermissionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            
            Text(L10n.PhotoGrid.permissionTitle)
                .font(.headline)
            
            Text(L10n.PhotoGrid.permissionMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button(L10n.PhotoGrid.permissionGrant) {
                photoLibraryManager.requestAuthorization()
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    private var deniedPermissionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text(L10n.PhotoGrid.permissionDeniedTitle)
                .font(.headline)
            
            Text(L10n.PhotoGrid.permissionDeniedMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button(L10n.PhotoGrid.permissionOpenSettings) {
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsURL)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    // MARK: - Selection and Upload
    
    private func toggleSelection(at index: Int) {
        guard let identifier = photoLibraryManager.localIdentifier(at: index) else { return }
        if selectedAssets.contains(identifier) {
            selectedAssets.remove(identifier)
        } else {
            selectedAssets.insert(identifier)
        }
    }
    
    private func uploadSelectedPhotos() {
        let identifiersToUpload = Array(selectedAssets)
        let manager = uploadManager
        
        Task.detached(priority: .userInitiated) {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiersToUpload, options: nil)
            var assetsToUpload: [PHAsset] = []
            assetsToUpload.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                assetsToUpload.append(asset)
            }
            
            await MainActor.run {
                manager.uploadAssets(assetsToUpload)
                isSelectionMode = false
                selectedAssets.removeAll()
            }
        }
    }
    
    // MARK: - Pull-to-Refresh
    
    private func performRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        
        let serverURL = settingsManager.serverURL
        let apiKey = settingsManager.apiKey
        
        guard !serverURL.isEmpty, !apiKey.isEmpty else {
            // No server configured: just refresh the sync status cache
            hashManager.refreshStatusCache()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isRefreshing = false
            }
            return
        }
        
        ServerAssetSyncService.shared.syncServerAssets(
            serverURL: serverURL,
            apiKey: apiKey,
            forceFullSync: false
        ) { [self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let syncResult):
                    logInfo("Refresh sync completed: \(syncResult.syncType)", category: .sync)
                    self.hashManager.refreshStatusCache()
                    self.startBackgroundProcessing()
                case .failure(let error):
                    logError("Refresh sync failed: \(error.localizedDescription)", category: .sync)
                    self.hashManager.refreshStatusCache()
                }
                
                self.isRefreshing = false
            }
        }
    }
    
    // MARK: - Auto Sync
    
    private func performAutoSync() {
        let serverURL = settingsManager.serverURL
        let apiKey = settingsManager.apiKey
        
        guard !serverURL.isEmpty && !apiKey.isEmpty else {
            logDebug("Server sync skipped: server not configured", category: .sync)
            return
        }
        
        guard !isSyncing else {
            logDebug("Server sync skipped: sync already in progress", category: .sync)
            return
        }
        
        isSyncing = true
        
        ServerAssetSyncService.shared.syncServerAssets(
            serverURL: serverURL,
            apiKey: apiKey,
            forceFullSync: false
        ) { [self] result in
            DispatchQueue.main.async {
                self.isSyncing = false
                self.handleSyncResult(result)
            }
        }
    }
    
    private func handleSyncResult(_ result: Result<SyncResult, Error>) {
        switch result {
        case .success(let syncResult):
            logInfo("Auto sync completed: \(syncResult.syncType), total: \(syncResult.totalAssets), upserted: \(syncResult.upsertedCount), deleted: \(syncResult.deletedCount)", category: .sync)
            
            hashManager.refreshStatusCache()
            startBackgroundProcessing()
            
        case .failure(let error):
            logError("Auto sync failed: \(error.localizedDescription)", category: .sync)
        }
    }
}

#Preview {
    PhotoGridView()
        .environmentObject(SettingsManager())
        .environmentObject(UploadManager())
}
