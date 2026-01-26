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
    @State private var lastPrefetchedRange: Range<Int>?
    @State private var isSyncing = false
    @State private var currentFilter: PhotoFilterOption = .all
    
    // Cached filter results for performance
    @State private var cachedFilteredAssets: [PHAsset] = []
    @State private var cachedNotUploadedCount: Int = 0
    @State private var isFilteringInProgress = false
    @State private var filterCacheVersion: Int = 0
    
    // Photo detail view states
    @State private var selectedPhotoIndex: Int = 0
    @State private var showingPhotoDetail = false
    @Namespace private var photoTransitionNamespace
    
    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]
    
    /// Number of items to prefetch ahead/behind visible area
    private let prefetchBuffer = 30
    
    /// Display assets - returns cached results for filtered view
    private var displayAssets: [PHAsset] {
        switch currentFilter {
        case .all:
            return photoLibraryManager.assets
        case .notUploaded:
            return cachedFilteredAssets
        }
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
                .navigationTitle(L10n.PhotoGrid.title)
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
                            .disabled(displayAssets.isEmpty)
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
            
            // Full screen photo detail overlay with swipe navigation support
            if showingPhotoDetail && !displayAssets.isEmpty {
                PhotoDetailView(
                    assets: displayAssets,
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
                // Trigger automatic server sync on first appearance
                performAutoSync()
            }
        }
        .onChange(of: photoLibraryManager.assets) { oldValue, newValue in
            if !newValue.isEmpty && oldValue.isEmpty {
                // Prefetch initial thumbnails
                prefetchThumbnails(around: 0)
            }
        }
        .onChange(of: photoLibraryManager.isLoading) { oldValue, newValue in
            // When loading completes, refresh hash processing with full asset list
            if oldValue == true && newValue == false {
                Task(priority: .background) {
                    let identifiers = photoLibraryManager.assets.map { $0.localIdentifier }
                    await MainActor.run {
                        hashManager.startBackgroundProcessing(identifiers: identifiers)
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
                        // Refresh filter cache after upload completes
                        updateNotUploadedCount()
                        if currentFilter == .notUploaded {
                            refreshFilterCache()
                        }
                    }
                }
            }
        }
        .onChange(of: hashManager.isProcessing) { oldValue, newValue in
            // Update count when hash processing completes
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
        guard !photoLibraryManager.assets.isEmpty else { return }
        let identifiers = photoLibraryManager.assets.map { $0.localIdentifier }
        hashManager.startBackgroundProcessing(identifiers: identifiers)
    }
    
    private var photoGridContent: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Filter indicator when not showing all photos
                if currentFilter != .all {
                    filterIndicatorView
                }
                
                ZStack {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(Array(displayAssets.enumerated()), id: \.element.localIdentifier) { index, asset in
                                let syncStatus = hashManager.getSyncStatus(for: asset.localIdentifier)
                                // When detail view is showing, the selected thumbnail should not be the geometry source
                                let isThisAssetSelected = showingPhotoDetail && selectedPhotoIndex == index
                                PhotoThumbnailView(
                                    asset: asset,
                                    isSelected: selectedAssets.contains(asset.localIdentifier),
                                    isSelectionMode: isSelectionMode,
                                    syncStatus: syncStatus,
                                    namespace: photoTransitionNamespace,
                                    isGeometrySource: !isThisAssetSelected
                                )
                                .aspectRatio(1, contentMode: .fill)
                                .clipped()
                                .id(asset.localIdentifier)
                                .onTapGesture {
                                    if isSelectionMode {
                                        toggleSelection(for: asset)
                                    } else {
                                        // Open photo detail view with animation
                                        openPhotoDetail(at: index)
                                    }
                                }
                                .onLongPressGesture {
                                    if !isSelectionMode {
                                        isSelectionMode = true
                                        selectedAssets.insert(asset.localIdentifier)
                                    }
                                }
                                .onAppear {
                                    // Prefetch thumbnails when item appears
                                    onItemAppear(index: index)
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .refreshable {
                        await refreshPhotosAsync()
                    }
                    
                    // Loading overlay when filtering
                    if isFilteringInProgress && currentFilter != .all {
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
    
    /// Filter indicator bar showing current filter status
    private var filterIndicatorView: some View {
        HStack {
            Image(systemName: currentFilter.iconName)
                .foregroundColor(.orange)
            if isFilteringInProgress {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Text(L10n.PhotoGrid.filterActive(displayAssets.count))
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
    
    /// Filter menu button for toolbar
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
    
    /// Apply filter with background processing
    private func applyFilter(_ filter: PhotoFilterOption) {
        // Clear selection when changing filter
        if isSelectionMode {
            selectedAssets.removeAll()
        }
        
        currentFilter = filter
        
        if filter == .notUploaded {
            refreshFilterCache()
        }
    }
    
    /// Refresh the filter cache in background
    private func refreshFilterCache() {
        guard !isFilteringInProgress else { return }
        
        isFilteringInProgress = true
        filterCacheVersion += 1
        let currentVersion = filterCacheVersion
        
        // Capture required data for background processing
        let allAssets = photoLibraryManager.assets
        let statusCache = hashManager.syncStatusCache
        
        Task.detached(priority: .userInitiated) {
            // Perform filtering on background thread
            var filteredResults: [PHAsset] = []
            var notUploadedTotal = 0
            
            for asset in allAssets {
                let status = statusCache[asset.localIdentifier] ?? .pending
                if status != .uploaded {
                    filteredResults.append(asset)
                    notUploadedTotal += 1
                }
            }
            
            // Update UI on main thread
            await MainActor.run {
                // Only update if this is still the latest filter request
                guard currentVersion == self.filterCacheVersion else { return }
                
                self.cachedFilteredAssets = filteredResults
                self.cachedNotUploadedCount = notUploadedTotal
                self.isFilteringInProgress = false
            }
        }
    }
    
    /// Update not uploaded count without full filter refresh
    private func updateNotUploadedCount() {
        let allAssets = photoLibraryManager.assets
        let statusCache = hashManager.syncStatusCache
        
        Task.detached(priority: .utility) {
            var count = 0
            for asset in allAssets {
                let status = statusCache[asset.localIdentifier] ?? .pending
                if status != .uploaded {
                    count += 1
                }
            }
            
            await MainActor.run {
                self.cachedNotUploadedCount = count
            }
        }
    }
    
    /// Opens the photo detail view with animation at specified index
    private func openPhotoDetail(at index: Int) {
        selectedPhotoIndex = index
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            showingPhotoDetail = true
        }
    }
    
    /// Called when a grid item appears - triggers prefetching
    private func onItemAppear(index: Int) {
        prefetchThumbnails(around: index)
    }
    
    private func prefetchThumbnails(around index: Int) {
        let assets = photoLibraryManager.assets
        guard !assets.isEmpty else { return }
        
        let startIndex = max(0, index - prefetchBuffer)
        let endIndex = min(assets.count, index + prefetchBuffer)
        
        guard startIndex < endIndex else { return }
        
        let newRange = startIndex..<endIndex
        
        // Stop caching assets that are no longer in the prefetch window
        if let oldRange = lastPrefetchedRange {
            let assetsToStop = oldRange.filter { !newRange.contains($0) }
                .compactMap { $0 < assets.count ? assets[$0] : nil }
            if !assetsToStop.isEmpty {
                ThumbnailCache.shared.stopPrefetching(for: assetsToStop)
            }
        }
        
        lastPrefetchedRange = newRange
        
        let assetsToPreload = Array(assets[newRange])
        ThumbnailCache.shared.prefetchThumbnails(for: assetsToPreload)
    }
    
    private func refreshPhotosAsync() async {
        await performAutoSyncAsync()
        
        await withCheckedContinuation { continuation in
            photoLibraryManager.fetchAssets()
            hashManager.refreshStatusCache()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                continuation.resume()
            }
        }
    }
    
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
    
    private func toggleSelection(for asset: PHAsset) {
        if selectedAssets.contains(asset.localIdentifier) {
            selectedAssets.remove(asset.localIdentifier)
        } else {
            selectedAssets.insert(asset.localIdentifier)
        }
    }
    
    private func uploadSelectedPhotos() {
        let assetsToUpload = photoLibraryManager.assets.filter {
            selectedAssets.contains($0.localIdentifier)
        }
        
        uploadManager.uploadAssets(assetsToUpload)
        
        isSelectionMode = false
        selectedAssets.removeAll()
    }
    
    // MARK: - Auto Sync
    
    /// Performs automatic server sync in background without showing alerts.
    /// Automatically determines whether to use delta sync or full sync based on last sync time.
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
    
    /// Async version of performAutoSync for use with pull-to-refresh.
    private func performAutoSyncAsync() async {
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
        
        await MainActor.run { isSyncing = true }
        
        await withCheckedContinuation { continuation in
            ServerAssetSyncService.shared.syncServerAssets(
                serverURL: serverURL,
                apiKey: apiKey,
                forceFullSync: false
            ) { [self] result in
                DispatchQueue.main.async {
                    self.isSyncing = false
                    self.handleSyncResult(result)
                    continuation.resume()
                }
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
