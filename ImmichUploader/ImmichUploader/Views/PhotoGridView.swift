import SwiftUI
import Photos

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
    @State private var visibleRange: Range<Int>?
    
    // Photo detail view states
    @State private var selectedPhotoForDetail: PHAsset?
    @State private var showingPhotoDetail = false
    @State private var selectedThumbnail: UIImage?
    @Namespace private var photoTransitionNamespace
    
    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]
    
    /// Number of items to prefetch ahead/behind visible area
    private let prefetchBuffer = 30
    
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
                            processingStatusView
                        }
                    }
                    
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if !isSelectionMode {
                            Button(L10n.PhotoGrid.select) {
                                isSelectionMode = true
                            }
                            .disabled(photoLibraryManager.assets.isEmpty)
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
            
            // Full screen photo detail overlay
            if showingPhotoDetail, let selectedAsset = selectedPhotoForDetail {
                PhotoDetailView(
                    asset: selectedAsset,
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
            }
        }
        .onChange(of: photoLibraryManager.assets) { oldValue, newValue in
            if !newValue.isEmpty && oldValue.isEmpty {
                startBackgroundProcessing()
                // Prefetch initial thumbnails
                prefetchThumbnails(around: 0)
            }
        }
        .onChange(of: uploadManager.isUploading) { oldValue, newValue in
            if oldValue == true && newValue == false {
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await MainActor.run {
                        hashManager.refreshStatusCache()
                    }
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
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(Array(photoLibraryManager.assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                        let syncStatus = hashManager.getSyncStatus(for: asset.localIdentifier)
                        PhotoThumbnailView(
                            asset: asset,
                            isSelected: selectedAssets.contains(asset.localIdentifier),
                            isSelectionMode: isSelectionMode,
                            syncStatus: syncStatus,
                            namespace: photoTransitionNamespace
                        )
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                        .id(asset.localIdentifier)
                        .onTapGesture {
                            if isSelectionMode {
                                toggleSelection(for: asset)
                            } else {
                                // Open photo detail view with animation
                                openPhotoDetail(asset: asset)
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
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
    
    /// Opens the photo detail view with animation
    private func openPhotoDetail(asset: PHAsset) {
        selectedPhotoForDetail = asset
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            showingPhotoDetail = true
        }
    }
    
    /// Called when a grid item appears - triggers prefetching
    private func onItemAppear(index: Int) {
        prefetchThumbnails(around: index)
    }
    
    /// Prefetch thumbnails around the visible index
    private func prefetchThumbnails(around index: Int) {
        let assets = photoLibraryManager.assets
        guard !assets.isEmpty else { return }
        
        let startIndex = max(0, index - prefetchBuffer)
        let endIndex = min(assets.count, index + prefetchBuffer)
        
        guard startIndex < endIndex else { return }
        
        let assetsToPreload = Array(assets[startIndex..<endIndex])
        ThumbnailCache.shared.prefetchThumbnails(for: assetsToPreload)
    }
    
    private func refreshPhotosAsync() async {
        await withCheckedContinuation { continuation in
            photoLibraryManager.fetchAssets()
            hashManager.refreshStatusCache()
            // Clear thumbnail cache to force reload
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
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
}

#Preview {
    PhotoGridView()
        .environmentObject(SettingsManager())
        .environmentObject(UploadManager())
}
