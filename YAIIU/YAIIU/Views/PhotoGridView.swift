import SwiftUI
import Photos
import Combine
import UIKit

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

// MARK: - Preference Keys

private struct FirstRowOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Drag Selection State

private final class DragSelectionState: ObservableObject {
    var anchorIndex: Int?
    var currentIndex: Int?
    /// Selection snapshot at drag start, used to restore items outside the drag range.
    var baseSelection: Set<String> = []
    var isDeselecting: Bool = false

    func reset() {
        anchorIndex = nil
        currentIndex = nil
        baseSelection.removeAll()
        isDeselecting = false
    }
}

// MARK: - ScrollViewGestureInjector

/// Injects a horizontal `UIPanGestureRecognizer` on the parent `UIScrollView`
/// for drag-to-select. Disables scrolling while the gesture is active.
private struct ScrollViewGestureInjector: UIViewRepresentable {
    let isEnabled: Bool
    let onBegan: (CGPoint) -> Void
    let onChanged: (CGPoint) -> Void
    let onEnded: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.installIfNeeded(on: uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled = false
        var onBegan: ((CGPoint) -> Void)?
        var onChanged: ((CGPoint) -> Void)?
        var onEnded: (() -> Void)?

        private weak var installedScrollView: UIScrollView?
        private var pan: UIPanGestureRecognizer?
        private var scrollWasEnabled = true

        private var displayLink: CADisplayLink?
        private var autoScrollSpeed: CGFloat = 0
        private let edgeInset: CGFloat = 60
        private let maxScrollSpeed: CGFloat = 800

        deinit {
            stopAutoScroll()
        }

        func installIfNeeded(on marker: UIView) {
            guard installedScrollView == nil || installedScrollView?.window == nil else { return }

            var candidate: UIView? = marker.superview
            while let v = candidate {
                if let sv = v as? UIScrollView {
                    install(on: sv)
                    return
                }
                candidate = v.superview
            }
        }

        private func install(on scrollView: UIScrollView) {
            if let old = pan {
                old.view?.removeGestureRecognizer(old)
            }
            let gesture = UIPanGestureRecognizer(
                target: self,
                action: #selector(handlePan(_:))
            )
            gesture.delegate = self
            scrollView.addGestureRecognizer(gesture)
            pan = gesture
            installedScrollView = scrollView
        }

        private func startAutoScroll() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(autoScrollTick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopAutoScroll() {
            displayLink?.invalidate()
            displayLink = nil
            autoScrollSpeed = 0
        }

        /// `pt` is in the scroll view's frame coordinate space.
        private func updateAutoScroll(frameRelativeTouch pt: CGPoint) {
            guard let scrollView = installedScrollView else { return }
            let frameHeight = scrollView.frame.height

            if pt.y < edgeInset {
                let ratio = max(0, (edgeInset - pt.y) / edgeInset)
                autoScrollSpeed = -maxScrollSpeed * ratio
                startAutoScroll()
            } else if pt.y > frameHeight - edgeInset {
                let ratio = max(0, (pt.y - (frameHeight - edgeInset)) / edgeInset)
                autoScrollSpeed = maxScrollSpeed * ratio
                startAutoScroll()
            } else {
                stopAutoScroll()
            }
        }

        @objc private func autoScrollTick(_ link: CADisplayLink) {
            guard let scrollView = installedScrollView,
                  let gesture = pan,
                  gesture.state == .changed || gesture.state == .began else {
                stopAutoScroll()
                return
            }

            let dt = CGFloat(link.targetTimestamp - link.timestamp)
            let delta = autoScrollSpeed * dt
            var offset = scrollView.contentOffset
            let inset = scrollView.adjustedContentInset

            offset.y += delta
            let minY = -inset.top
            let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
            offset.y = min(max(offset.y, minY), maxY)
            scrollView.contentOffset = offset

            let loc = gesture.location(in: scrollView)
            onChanged?(loc)
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard isEnabled, let scrollView = installedScrollView else { return }
            let loc = gesture.location(in: scrollView)

            switch gesture.state {
            case .began:
                scrollWasEnabled = scrollView.isScrollEnabled
                scrollView.isScrollEnabled = false
                onBegan?(loc)
            case .changed:
                onChanged?(loc)
                let touchInFrame = gesture.location(in: scrollView.superview ?? scrollView)
                let frameOriginY = scrollView.frame.origin.y
                let touchRelative = CGPoint(x: touchInFrame.x, y: touchInFrame.y - frameOriginY)
                updateAutoScroll(frameRelativeTouch: touchRelative)
            case .ended, .cancelled, .failed:
                stopAutoScroll()
                scrollView.isScrollEnabled = scrollWasEnabled
                onEnded?()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard isEnabled else { return false }
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else { return false }
            let vel = pan.velocity(in: view)
            return abs(vel.x) > abs(vel.y)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

// MARK: - Date Formatting

private enum DateFormatting {
    static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMd")
        return formatter
    }()
    
    static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMMd")
        return formatter
    }()
    
    static func formatSectionDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        
        if calendar.isDateInToday(date) {
            return L10n.PhotoGrid.sectionToday
        } else if calendar.isDateInYesterday(date) {
            return L10n.PhotoGrid.sectionYesterday
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return monthDayFormatter.string(from: date)
        } else {
            return fullDateFormatter.string(from: date)
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
    
    @State private var filteredIndices: [Int] = []
    @State private var cachedNotUploadedCount: Int = 0
    @State private var isFilteringInProgress = false
    @State private var filterCacheVersion: Int = 0
    
    @State private var refreshToken: UUID = UUID()
    @State private var processingTask: Task<Void, Never>?
    @State private var selectedPhotoIndex: Int = 0
    @State private var showingPhotoDetail = false
    @Namespace private var photoTransitionNamespace
    
    @StateObject private var dragState = DragSelectionState()
    @State private var gridContainerWidth: CGFloat = 0
    
    private static let columnCount = 3
    private static let gridSpacing: CGFloat = 2
    private static let gridHorizontalPadding: CGFloat = 1
    
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
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        if isSelectionMode {
                            Button(L10n.PhotoGrid.cancel) {
                                isSelectionMode = false
                                selectedAssets.removeAll()
                                dragState.reset()
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
                    refreshToken: refreshToken,
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
        guard photoLibraryManager.assetCount > 0 else {
            if hashManager.isProcessing {
                hashManager.clearPreparingState()
            }
            return
        }
        
        if !hashManager.isProcessing {
            hashManager.setPreparingState()
        }
        
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
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if currentFilter != .all {
                    filterIndicatorView
                }
                
                ZStack {
                    simpleGridView
                    
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
            .onAppear { gridContainerWidth = geometry.size.width }
            .onChange(of: geometry.size.width) { _, w in gridContainerWidth = w }
            .onDisappear {
                visibleDisplayIndices.removeAll()
            }
        }
    }
    
    // MARK: - Grid View with Dynamic Title
    
    @State private var currentVisibleDate: String = ""
    @State private var visibleDisplayIndices: Set<Int> = []
    @State private var firstRowTopOffset: CGFloat = 0
    
    /// Navigation title: shows "Photo Library" when first row top is visible, date otherwise
    private var navigationTitle: String {
        // Show date when first row has scrolled past the top edge
        if firstRowTopOffset < 0 {
            if !currentVisibleDate.isEmpty {
                return currentVisibleDate
            }
        }
        return L10n.PhotoGrid.title
    }
    
    private var simpleGridView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                ForEach(0..<displayCount, id: \.self) { displayIndex in
                    let actualIndex = resolveActualIndex(displayIndex)
                    gridItemView(assetIndex: actualIndex, displayIndex: displayIndex)
                        .background(
                            Group {
                                if displayIndex == 0 {
                                    firstRowTracker
                                }
                            }
                        )
                }
            }
            .padding(.horizontal, Self.gridHorizontalPadding)
            .background {
                ScrollViewGestureInjector(
                    isEnabled: isSelectionMode,
                    onBegan: { handleDragBegan(at: $0) },
                    onChanged: { handleDragChanged(at: $0) },
                    onEnded: { handleDragEnded() }
                )
                .frame(width: 0, height: 0)
            }
            .id(refreshToken)
        }
        .coordinateSpace(name: "scrollView")
        .refreshable {
            await refreshPhotosAsync()
        }
    }
    
    /// Invisible view to track the first row's position relative to scroll view
    private var firstRowTracker: some View {
        GeometryReader { geo in
            Color.clear
                .preference(
                    key: FirstRowOffsetKey.self,
                    value: geo.frame(in: .named("scrollView")).minY
                )
        }
        .onPreferenceChange(FirstRowOffsetKey.self) { offset in
            firstRowTopOffset = offset
        }
    }
    
    private func updateVisibleDate(for displayIndex: Int, assetIndex: Int, isAppearing: Bool) {
        if isAppearing {
            visibleDisplayIndices.insert(displayIndex)
        } else {
            visibleDisplayIndices.remove(displayIndex)
        }
        
        // Update date text based on current minimum visible item
        guard let minDisplayIndex = visibleDisplayIndices.min() else { return }
        let minAssetIndex = resolveActualIndex(minDisplayIndex)
        guard let date = photoLibraryManager.creationDate(at: minAssetIndex) else { return }
        
        let newText = DateFormatting.formatSectionDate(date)
        if newText != currentVisibleDate {
            currentVisibleDate = newText
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
    
    // MARK: - Grid Item View
    
    @ViewBuilder
    private func gridItemView(assetIndex: Int, displayIndex: Int) -> some View {
        PhotoGridItemView(
            photoLibraryManager: photoLibraryManager,
            hashManager: hashManager,
            displayIndex: displayIndex,
            assetIndex: assetIndex,
            isSelectionMode: isSelectionMode,
            selectedAssets: $selectedAssets,
            namespace: photoTransitionNamespace,
            refreshToken: refreshToken,
            showingPhotoDetail: showingPhotoDetail,
            selectedPhotoIndex: selectedPhotoIndex,
            onTap: {
                if isSelectionMode {
                    toggleSelection(at: assetIndex)
                } else {
                    openPhotoDetail(at: displayIndex)
                }
            },
            onLongPress: {
                if !isSelectionMode {
                    isSelectionMode = true
                    if let id = photoLibraryManager.localIdentifier(at: assetIndex) {
                        selectedAssets.insert(id)
                    }
                }
            },
            onAppear: {
                onItemAppear(displayIndex: displayIndex, assetIndex: assetIndex)
            },
            onDisappear: {
                onItemDisappear(displayIndex: displayIndex, assetIndex: assetIndex)
            }
        )
        .aspectRatio(1, contentMode: .fill)
        .clipped()
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
                applyFilter(.all)
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
        } else {
            // Force grid rebuild when switching back to "all"
            refreshToken = UUID()
        }
    }
    
    private func refreshFilterCache() {
        guard !isFilteringInProgress else { return }
        
        isFilteringInProgress = true
        filterCacheVersion += 1
        let currentVersion = filterCacheVersion
        
        let manager = photoLibraryManager
        let hash = hashManager
        
        // Capture statusCache inside the Task to get the latest snapshot
        Task.detached(priority: .userInitiated) {
            // Read latest values atomically to ensure consistency
            let (statusCache, totalCount, fetchResult) = await MainActor.run {
                (hash.syncStatusCache, manager.assetCount, manager.fetchResult)
            }
            
            var indices: [Int] = []
            indices.reserveCapacity(totalCount / 4)
            
            if let fetchResult = fetchResult {
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
                // Force grid rebuild to display correct thumbnails
                self.refreshToken = UUID()
            }
        }
    }
    
    private func updateNotUploadedCount() {
        let manager = photoLibraryManager
        let hash = hashManager
        
        Task.detached(priority: .utility) {
            // Read latest values atomically to ensure consistency
            let (statusCache, totalCount, fetchResult) = await MainActor.run {
                (hash.syncStatusCache, manager.assetCount, manager.fetchResult)
            }
            
            guard let fetchResult = fetchResult else {
                await MainActor.run {
                    self.cachedNotUploadedCount = totalCount
                }
                return
            }
            
            var uploadedCount = 0
            fetchResult.enumerateObjects { (asset, _, _) in
                if statusCache[asset.localIdentifier] == .uploaded {
                    uploadedCount += 1
                }
            }
            
            let notUploadedCount = totalCount - uploadedCount
            await MainActor.run {
                self.cachedNotUploadedCount = notUploadedCount
            }
        }
    }
    
    private func openPhotoDetail(at index: Int) {
        selectedPhotoIndex = index
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            showingPhotoDetail = true
        }
    }
    
    private func onItemAppear(displayIndex: Int, assetIndex: Int) {
        prefetchThumbnails(around: assetIndex)
        updateVisibleDate(for: displayIndex, assetIndex: assetIndex, isAppearing: true)
    }
    
    private func onItemDisappear(displayIndex: Int, assetIndex: Int) {
        updateVisibleDate(for: displayIndex, assetIndex: assetIndex, isAppearing: false)
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
        performAutoSync()
        
        await photoLibraryManager.fetchAssetsAsync()
        await hashManager.refreshStatusCacheAsync()
        
        // Reset scroll tracking state
        visibleDisplayIndices.removeAll()
        currentVisibleDate = ""
        firstRowTopOffset = 0
        
        refreshToken = UUID()
        
        updateNotUploadedCount()
        if currentFilter == .notUploaded {
            refreshFilterCache()
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
    
    // MARK: - Drag-to-Select
    
    private var cellSize: CGFloat {
        let usable = gridContainerWidth - Self.gridHorizontalPadding * 2
        let gaps = Self.gridSpacing * CGFloat(Self.columnCount - 1)
        return max((usable - gaps) / CGFloat(Self.columnCount), 1)
    }
    
    private func displayIndex(at point: CGPoint) -> Int? {
        let side = cellSize
        let stride = side + Self.gridSpacing
        let originX = Self.gridHorizontalPadding
        
        let col = Int((point.x - originX) / stride)
        let row = Int(point.y / stride)
        
        guard col >= 0, col < Self.columnCount, row >= 0 else { return nil }
        
        let index = row * Self.columnCount + col
        guard index >= 0, index < displayCount else { return nil }
        return index
    }
    
    private func handleDragBegan(at point: CGPoint) {
        guard let idx = displayIndex(at: point) else { return }
        let actualIdx = resolveActualIndex(idx)
        
        dragState.baseSelection = selectedAssets
        dragState.anchorIndex = idx
        dragState.currentIndex = idx
        
        if let id = photoLibraryManager.localIdentifier(at: actualIdx) {
            dragState.isDeselecting = selectedAssets.contains(id)
        }
        
        applyDragRange(from: idx, to: idx)
    }
    
    private func handleDragChanged(at point: CGPoint) {
        guard let anchor = dragState.anchorIndex else { return }
        guard let idx = displayIndex(at: point) else { return }
        guard idx != dragState.currentIndex else { return }
        
        dragState.currentIndex = idx
        applyDragRange(from: anchor, to: idx)
    }
    
    private func handleDragEnded() {
        dragState.reset()
    }
    
    private func applyDragRange(from: Int, to: Int) {
        let lo = min(from, to)
        let hi = max(from, to)
        
        var next = dragState.baseSelection
        for i in lo...hi {
            let actual = resolveActualIndex(i)
            guard let id = photoLibraryManager.localIdentifier(at: actual) else { continue }
            if dragState.isDeselecting {
                next.remove(id)
            } else {
                next.insert(id)
            }
        }
        selectedAssets = next
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
                dragState.reset()
            }
        }
    }
    
    // MARK: - Auto Sync
    
    private func performAutoSync() {
        let serverURL = settingsManager.serverURL
        let apiKey = settingsManager.apiKey
        
        if !hashManager.isProcessing {
            hashManager.setPreparingState()
        }
        
        guard !serverURL.isEmpty && !apiKey.isEmpty else {
            logDebug("Server sync skipped: server not configured", category: .sync)
            startBackgroundProcessing()
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
            
        case .failure(let error):
            logError("Auto sync failed: \(error.localizedDescription)", category: .sync)
        }
        startBackgroundProcessing()
    }
}

// MARK: - PhotoGridItemView

private struct PhotoGridItemView: View {
    let photoLibraryManager: PhotoLibraryManager
    let hashManager: HashManager
    let displayIndex: Int
    let assetIndex: Int
    let isSelectionMode: Bool
    @Binding var selectedAssets: Set<String>
    let namespace: Namespace.ID
    let refreshToken: UUID
    let showingPhotoDetail: Bool
    let selectedPhotoIndex: Int
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onAppear: () -> Void
    let onDisappear: () -> Void
    
    @State private var asset: PHAsset?
    @State private var syncStatus: PhotoSyncStatus = .pending
    
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
                    refreshToken: refreshToken,
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
            loadAsset()
            onAppear()
        }
        .onDisappear {
            onDisappear()
        }
        .onChange(of: assetIndex) { _, _ in
            // Reload asset when index changes (e.g., filter updates)
            loadAsset()
        }
        .onReceive(hashManager.$syncStatusCache.receive(on: RunLoop.main)) { newCache in
            guard let id = asset?.localIdentifier else { return }
            let newStatus = newCache[id] ?? .pending
            if syncStatus != newStatus {
                syncStatus = newStatus
            }
        }
    }
    
    private func loadAsset() {
        let newAsset = photoLibraryManager.asset(at: assetIndex)
        asset = newAsset
        if let id = newAsset?.localIdentifier {
            syncStatus = hashManager.getSyncStatus(for: id)
        }
    }
}

#Preview {
    PhotoGridView()
        .environmentObject(SettingsManager())
        .environmentObject(UploadManager())
}
