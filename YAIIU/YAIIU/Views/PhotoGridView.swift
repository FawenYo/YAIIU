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
    
    // Cached filter results: stores indices of assets that pass the filter
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
    
    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]
    
    private let prefetchBuffer = 30
    
    private var displayCount: Int {
        switch currentFilter {
        case .all:
            return photoLibraryManager.assetCount
        case .notUploaded:
            return filteredIndices.count
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
        .onChange(of: photoLibraryManager.assetCount) { oldValue, newValue in
            if newValue > 0 && oldValue == 0 {
                prefetchThumbnails(around: 0)
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
        let identifiers = photoLibraryManager.allLocalIdentifiers()
        hashManager.startBackgroundProcessing(identifiers: identifiers)
    }
    
    private var photoGridContent: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if currentFilter != .all {
                    filterIndicatorView
                }
                
                ZStack {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(0..<displayCount, id: \.self) { displayIndex in
                                let actualIndex = resolveActualIndex(displayIndex)
                                let syncStatus: PhotoSyncStatus = {
                                    if let id = photoLibraryManager.localIdentifier(at: actualIndex) {
                                        return hashManager.getSyncStatus(for: id)
                                    }
                                    return .pending
                                }()
                                PhotoGridItemView(
                                    photoLibraryManager: photoLibraryManager,
                                    displayIndex: displayIndex,
                                    assetIndex: actualIndex,
                                    isSelectionMode: isSelectionMode,
                                    selectedAssets: $selectedAssets,
                                    syncStatus: syncStatus,
                                    namespace: photoTransitionNamespace,
                                    showingPhotoDetail: showingPhotoDetail,
                                    selectedPhotoIndex: selectedPhotoIndex,
                                    onTap: {
                                        if isSelectionMode {
                                            toggleSelection(at: actualIndex)
                                        } else {
                                            openPhotoDetail(at: displayIndex)
                                        }
                                    },
                                    onLongPress: {
                                        if !isSelectionMode {
                                            isSelectionMode = true
                                            if let id = photoLibraryManager.localIdentifier(at: actualIndex) {
                                                selectedAssets.insert(id)
                                            }
                                        }
                                    },
                                    onAppear: {
                                        onItemAppear(index: displayIndex)
                                    }
                                )
                                .aspectRatio(1, contentMode: .fill)
                                .clipped()
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .refreshable {
                        await refreshPhotosAsync()
                    }
                    
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
    
    /// Resolves display index to actual asset index based on current filter
    private func resolveActualIndex(_ displayIndex: Int) -> Int {
        switch currentFilter {
        case .all:
            return displayIndex
        case .notUploaded:
            guard displayIndex < filteredIndices.count else { return displayIndex }
            return filteredIndices[displayIndex]
        }
    }
    
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
        let manager = photoLibraryManager
        
        Task.detached(priority: .utility) {
            var count = 0
            if let fetchResult = manager.fetchResult {
                fetchResult.enumerateObjects { (asset, _, _) in
                    let status = statusCache[asset.localIdentifier] ?? .pending
                    if status != .uploaded {
                        count += 1
                    }
                }
            }
            
            await MainActor.run {
                self.cachedNotUploadedCount = count
            }
        }
    }
    
    private func openPhotoDetail(at index: Int) {
        selectedPhotoIndex = index
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            showingPhotoDetail = true
        }
    }
    
    private func onItemAppear(index: Int) {
        prefetchThumbnails(around: index)
    }
    
    private func prefetchThumbnails(around index: Int) {
        let count = photoLibraryManager.assetCount
        guard count > 0 else { return }
        
        let startIndex = max(0, index - prefetchBuffer)
        let endIndex = min(count, index + prefetchBuffer)
        
        guard startIndex < endIndex else { return }
        
        let newRange = startIndex..<endIndex
        
        if let oldRange = lastPrefetchedRange {
            let indicesToStop = oldRange.filter { !newRange.contains($0) }
            let assetsToStop = indicesToStop.compactMap { photoLibraryManager.asset(at: $0) }
            if !assetsToStop.isEmpty {
                ThumbnailCache.shared.stopPrefetching(for: assetsToStop)
            }
        }
        
        lastPrefetchedRange = newRange
        
        let assetsToPreload = photoLibraryManager.assets(in: newRange)
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

// MARK: - PhotoGridItemView

private struct PhotoGridItemView: View {
    let photoLibraryManager: PhotoLibraryManager
    let displayIndex: Int
    let assetIndex: Int
    let isSelectionMode: Bool
    @Binding var selectedAssets: Set<String>
    let syncStatus: PhotoSyncStatus
    let namespace: Namespace.ID
    let showingPhotoDetail: Bool
    let selectedPhotoIndex: Int
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onAppear: () -> Void
    
    @State private var asset: PHAsset?
    
    var body: some View {
        Group {
            if let asset = asset {
                let isThisAssetSelected = showingPhotoDetail && selectedPhotoIndex == displayIndex
                
                PhotoThumbnailView(
                    asset: asset,
                    isSelected: selectedAssets.contains(asset.localIdentifier),
                    isSelectionMode: isSelectionMode,
                    syncStatus: syncStatus,
                    namespace: namespace,
                    isGeometrySource: !isThisAssetSelected
                )
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .onLongPressGesture {
            onLongPress()
        }
        .onAppear {
            asset = photoLibraryManager.asset(at: assetIndex)
            onAppear()
        }
    }
}

#Preview {
    PhotoGridView()
        .environmentObject(SettingsManager())
        .environmentObject(UploadManager())
}
