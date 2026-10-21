import SwiftUI
import Photos
import Combine
import UIKit

// MARK: - Photo Filter Options

enum PhotoFilterOption: String, CaseIterable, Identifiable, Sendable {
    case all
    case notUploaded
    case favorites
    case album
    
    var id: String { rawValue }
    
    var localizedTitle: String {
        switch self {
        case .all:
            return L10n.PhotoGrid.filterAll
        case .notUploaded:
            return L10n.PhotoGrid.filterNotUploaded
        case .favorites:
            return L10n.PhotoGrid.filterFavorites
        case .album:
            return L10n.PhotoGrid.filterAlbum
        }
    }
    
    var iconName: String {
        switch self {
        case .all:
            return "photo.on.rectangle"
        case .notUploaded:
            return "icloud.slash"
        case .favorites:
            return "heart.fill"
        case .album:
            return "rectangle.stack"
        }
    }
}

enum PhotoGridProcessingStage: Equatable {
    case syncingServer
    case readingPhotoLibrary
    case preparingComparison
    case analyzing(current: Int, total: Int)
    case checking(current: Int, total: Int)
    case defaultStatus

    var showsDedicatedScreen: Bool {
        switch self {
        case .syncingServer, .readingPhotoLibrary, .preparingComparison, .defaultStatus:
            return true
        case .analyzing, .checking:
            return false
        }
    }

    static func resolve(
        statusMessage: String,
        processed: Int,
        total: Int,
        isSyncing: Bool,
        foregroundWorkPreparing: Bool
    ) -> Self {
        if isSyncing {
            return .syncingServer
        }
        if foregroundWorkPreparing {
            return .readingPhotoLibrary
        }
        if statusMessage.contains("分析") || statusMessage.contains("Analyzing") {
            return total > 0 && processed > 0
                ? .analyzing(current: processed, total: total)
                : .preparingComparison
        }
        if statusMessage.contains("確認") || statusMessage.contains("Checking") {
            return total > 0 && processed > 0
                ? .checking(current: processed, total: total)
                : .checking(current: 0, total: 0)
        }
        if statusMessage.contains("準備") || statusMessage.contains("Preparing") {
            return .preparingComparison
        }
        return .defaultStatus
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
                let ratio = min(1, max(0, (edgeInset - pt.y) / edgeInset))
                autoScrollSpeed = -maxScrollSpeed * ratio
                startAutoScroll()
            } else if pt.y > frameHeight - edgeInset {
                let ratio = min(1, max(0, (pt.y - (frameHeight - edgeInset)) / edgeInset))
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
                let touchRelative = CGPoint(x: loc.x, y: loc.y - scrollView.contentOffset.y)
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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var uploadManager: UploadManager
    @ObservedObject private var photoLibraryManager = PhotoLibraryManager.shared
    @ObservedObject private var hashManager = HashManager.shared

    @State private var selectedAssets: Set<String> = []
    @State private var isSelectionMode = false
    @State private var showingPermissionAlert = false
    @State private var showingUploadConfirmation = false
    @State private var hasAppeared = false
    @State private var lastPrefetchedRange: Range<Int>?
    @State private var lastPrefetchedTargetSize: CGSize?
    /// At most 25 PhotoKit assets from the filtered display window.
    @State private var lastPrefetchedFilteredAssets: [PHAsset] = []
    @State private var isSyncing = false
    @State private var currentFilter: PhotoFilterOption = .all
    @State private var selectedAlbum: PhotoAlbumOption?
    @State private var albumChoices: [PhotoAlbumOption] = []
    @State private var albumSearch = ""
    @State private var isAlbumPickerPresented = false
    @State private var isLoadingAlbums = false
    @State private var foregroundWorkPreparing = false
    @State private var foregroundRefreshPending = false
    @State private var isFilterLoading = false
    @State private var albumLoadTask: Task<Void, Never>?
    @State private var photoFilterTask: Task<Void, Never>?
    @State private var libraryRefreshTask: Task<Void, Never>?
    @State private var photoFilterVersion = 0
    
    @State private var filteredIndices: [Int] = []
    /// Keep indexed fetch ownership out of State's saved value history. Existing
    /// index/generation state and refreshToken publish replacements together.
    @State private var fetchStorage = PhotoGridFetchStorage<PHFetchResult<PHAsset>>()
    private var filteredFetchResult: PHFetchResult<PHAsset>? {
        get { fetchStorage.filtered }
        nonmutating set { fetchStorage.filtered = newValue }
    }
    @State private var filteredIndicesGeneration: Int?
    /// Retain the last not-uploaded indices together with their owning fetch
    /// so switching filters never shows a false zero while rebuilding.
    @State private var cachedNotUploadedIndices: [Int] = []
    private var cachedNotUploadedFetchResult: PHFetchResult<PHAsset>? {
        get { fetchStorage.cachedNotUploaded }
        nonmutating set { fetchStorage.cachedNotUploaded = newValue }
    }
    @State private var cachedNotUploadedGeneration: Int?
    @State private var cachedNotUploadedCount: Int = 0
    @State private var countRefreshTask: Task<Void, Never>?
    @State private var recomputeTask: Task<Void, Never>?
    @State private var countComputeVersion: Int = 0
    @State private var syncStatusGeneration = 0
    @State private var isSelectingAll = false
    @State private var selectionTask: Task<Void, Never>?
    
    @State private var refreshToken: UUID = UUID()
    /// Reset scroll/grid identity only for deliberate filter changes or
    /// pull-to-refresh, not for every PhotoKit or sync status refresh.
    @State private var gridResetToken: UUID = UUID()
    @State private var processingTask: Task<Void, Never>?
    @State private var selectedPhotoIndex: Int = 0
    @State private var showingPhotoDetail = false
    @State private var photoDetailIndexGeneration: Int?
    @Namespace private var photoTransitionNamespace
    
    @StateObject private var dragState = DragSelectionState()
    @State private var gridContainerWidth: CGFloat = 0
    
    private static let columnCount = 3
    private static let gridSpacing: CGFloat = 2
    private static let gridHorizontalPadding: CGFloat = 1
    
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Self.gridSpacing), count: Self.columnCount)
    }
    
    private let prefetchBuffer = 12

    /// One pixel size for the uniform three-column grid, used by both visible
    /// thumbnail requests and PhotoKit preheating/cancellation.
    private var thumbnailTargetSize: CGSize {
        guard gridContainerWidth > 0 else { return ThumbnailCache.defaultTargetSize }
        let spacing = CGFloat(Self.columnCount - 1) * Self.gridSpacing
        let usable = gridContainerWidth - Self.gridHorizontalPadding * 2 - spacing
        let cellWidth = max(1, usable / CGFloat(Self.columnCount))
        return ThumbnailCache.targetSize(forGridCellWidth: cellWidth, displayScale: displayScale)
    }
    
    private var displayCount: Int {
        switch currentFilter {
        case .all:
            return photoLibraryManager.assetCount
        case .notUploaded, .favorites, .album:
            // During PhotoKit refreshes, display the last *valid* snapshot rather
            // than presenting a false empty gallery for several seconds.
            return filteredFetchResult == nil ? 0 : filteredIndices.count
        }
    }

    /// A background PhotoKit refresh does not invalidate the old, retained
    /// filtered fetch. Users can still select its visible assets by identifier.
    private var canSelectDisplayedPhotos: Bool {
        displayCount > 0 && (currentFilter == .all || filteredFetchResult != nil)
    }

    private var visibleAlbumChoices: [PhotoAlbumOption] {
        guard !albumSearch.isEmpty else { return albumChoices }
        return albumChoices.filter { $0.title.localizedCaseInsensitiveContains(albumSearch) }
    }

    private var isTabBarHidden: Bool {
        showingPhotoDetail || isSelectionMode
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
                                selectionTask?.cancel()
                                selectionTask = nil
                                isSelectingAll = false
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
                            .disabled(!canSelectDisplayedPhotos)
                        }
                    }

                    ToolbarItemGroup(placement: .bottomBar) {
                        if isSelectionMode {
                            Button(L10n.PhotoGrid.selectAllNotUploaded) {
                                selectAllNotUploaded()
                            }
                            .disabled(hashManager.isProcessing || isSelectingAll || !canSelectDisplayedPhotos)

                            Spacer()

                            Button(L10n.PhotoGrid.upload(selectedAssets.count)) {
                                showingUploadConfirmation = true
                            }
                            .disabled(selectedAssets.isEmpty || isSelectingAll)
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
            .sheet(isPresented: $isAlbumPickerPresented) {
                albumPickerSheet
            }
            .toolbar(isTabBarHidden ? .hidden : .visible, for: .tabBar)
            .animation(.easeInOut(duration: 0.2), value: isTabBarHidden)
            
            if showingPhotoDetail && displayCount > 0 {
                PhotoDetailView(
                    photoLibraryManager: photoLibraryManager,
                    displayIndices: currentFilter == .all ? nil : filteredIndices,
                    displayIndexGeneration: photoDetailIndexGeneration,
                    initialIndex: selectedPhotoIndex,
                    namespace: photoTransitionNamespace,
                    refreshToken: refreshToken,
                    isPresented: $showingPhotoDetail
                )
                .zIndex(1)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            processingScreen
        }
        .onAppear {
            if !hasAppeared {
                hasAppeared = true
                photoLibraryManager.requestAuthorization { status in
                    if status != .authorized && status != .limited {
                        hashManager.clearPreparingState()
                    }
                }
            }
            performAutoSync()
            if currentFilter == .favorites || currentFilter == .album {
                refreshPhotoKitFilter()
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                performAutoSync()
                if currentFilter == .favorites || currentFilter == .album {
                    refreshPhotoKitFilter()
                }
            }
        }
        .onDisappear {
            selectionTask?.cancel()
            selectionTask = nil
            isSelectingAll = false
            countRefreshTask?.cancel()
            countRefreshTask = nil
            recomputeTask?.cancel()
            recomputeTask = nil
            processingTask?.cancel()
            processingTask = nil
            albumLoadTask?.cancel()
            photoFilterTask?.cancel()
            libraryRefreshTask?.cancel()
            stopPrefetching()
        }
        .onChange(of: photoLibraryManager.assetCount) { oldValue, newValue in
            if newValue > 0 && oldValue == 0 {
                prefetchThumbnails(aroundDisplayIndex: 0)
            }
            // The last asset can disappear while its detail view is open.
            // Clear the presentation state even though the displayCount guard
            // has already removed PhotoDetailView from the hierarchy.
            if newValue == 0 && showingPhotoDetail && currentFilter == .all {
                showingPhotoDetail = false
            }
        }
        .onChange(of: photoLibraryManager.isLoading) { oldValue, newValue in
            if oldValue == true && newValue == false {
                processingTask?.cancel()
                processingTask = Task(priority: .background) {
                    if Task.isCancelled { return }

                    await MainActor.run {
                        guard !Task.isCancelled, !photoLibraryManager.isLoading else { return }
                        recomputeCounts()
                    }
                }

                // performAutoSync() on first appear can race ahead of the initial
                // asset fetch and no-op in startBackgroundProcessing() because
                // assetCount was still 0. Retry now that assets have loaded so
                // upload-status icons populate without requiring a manual refresh.
                startBackgroundProcessing()
            }
        }
        .onChange(of: uploadManager.isUploading) { oldValue, newValue in
            if oldValue == true && newValue == false {
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await MainActor.run {
                        // refreshStatusCache() republishes syncStatusCache, which
                        // the .onReceive listener already turns into a debounced
                        // recomputeCounts(), so no direct call is needed here.
                        hashManager.refreshStatusCache()
                    }
                }
            }
        }
        .onChange(of: hashManager.isProcessing) { oldValue, newValue in
            if newValue {
                // Pause only PhotoKit preheating. Do not clear visible cache or
                // cancel existing image requests (the PR #90 spinner regression).
                stopPrefetching()
            } else if oldValue {
                syncPendingICloudIds()
                if foregroundRefreshPending {
                    foregroundRefreshPending = false
                    startBackgroundProcessing()
                }
            }
        }
        // The count must track the same source as the per-photo icons
        // (syncStatusCache). finishProcessing() flips isProcessing before the
        // authoritative DB reload lands, so reacting to the cache itself ensures
        // the count converges to the final state instead of a mid-flight snapshot.
        // During hashing the cache mutates per asset, so coalesce the bursts into
        // a single recompute after activity settles to avoid main-thread churn.
        // Use the same publisher the per-photo icons subscribe to (onReceive),
        // not onChange(of:). onChange only fires when SwiftUI's diff sees a new
        // value during body re-eval, which can be skipped; onReceive fires on
        // every publish, so the count tracks the icons exactly.
        .onReceive(hashManager.$syncStatusCache.receive(on: RunLoop.main)) { _ in
            syncStatusGeneration &+= 1
            scheduleCountRefresh()
        }
        .onReceive(photoLibraryManager.$assetFetchGeneration.receive(on: RunLoop.main)) { _ in
            // A filtered index is a position within one particular PHFetchResult.
            // Invalidate it immediately when that fetch is replaced, before a
            // delayed identifier enumeration can publish its replacement.
            photoFilterTask?.cancel()
            photoFilterVersion += 1
            selectionTask?.cancel()
            isSelectingAll = false
            // A new PhotoKit fetch invalidates indices, not local identifiers.
            // Keep the user's in-progress selection while upload completion or
            // library edits trigger a refresh. Filter membership is reconciled
            // when the new identifier snapshot arrives.
            // Content-only changes (including iCloud download completion) keep
            // positions valid. Close filtered detail only when positions may
            // have changed; filter membership is checked after recomputation.
            if showingPhotoDetail && currentFilter != .all &&
               photoDetailIndexGeneration != photoLibraryManager.assetIndexGeneration {
                showingPhotoDetail = false
            }
            // Rebind valid positions to the latest assets without rebuilding
            // the visible list after each iCloud/content update.
            if fetchStorage.filteredIndexGeneration == photoLibraryManager.assetIndexGeneration,
               photoLibraryManager.orderedIdentifiersGeneration == photoLibraryManager.assetFetchGeneration {
                filteredFetchResult = photoLibraryManager.fetchResult
                filteredIndicesGeneration = photoLibraryManager.assetFetchGeneration
                isFilterLoading = false
            } else {
                // Retain the previous snapshot while new positions are built.
                filteredIndicesGeneration = nil
                if currentFilter != .all { isFilterLoading = true }
            }
            // Old full-library ranges refer to the previous fetch. Avoid
            // interpreting them against the newly swapped result.
            lastPrefetchedRange = nil
            if !lastPrefetchedFilteredAssets.isEmpty {
                ThumbnailCache.shared.stopPrefetching(
                    for: lastPrefetchedFilteredAssets,
                    targetSize: lastPrefetchedTargetSize ?? thumbnailTargetSize
                )
                lastPrefetchedFilteredAssets = []
            }
            lastPrefetchedTargetSize = nil
            refreshToken = UUID()
        }
        .onReceive(photoLibraryManager.$orderedIdentifiersGeneration.receive(on: RunLoop.main)) { generation in
            // A fresh PhotoKit index snapshot is now usable for this generation.
            // Hash status may not change at the same time, so don't depend on
            // syncStatusCache notifications to republish the filtered gallery.
            guard let generation,
                  generation == photoLibraryManager.assetFetchGeneration else { return }
            if currentFilter == .notUploaded {
                recomputeCounts()
            } else if currentFilter == .favorites || currentFilter == .album {
                refreshPhotoKitFilter()
            }
        }
        .onReceive(photoLibraryManager.$libraryRevision.receive(on: RunLoop.main)) { _ in
            // Coalesce PhotoKit notifications (including album membership edits).
            libraryRefreshTask?.cancel()
            libraryRefreshTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                // PhotoKit refreshes must not clear an active selection, but
                // identifiers of assets actually deleted from the library
                // should not remain selected. Only reconcile a finished
                // identifier snapshot, never the transient empty one.
                if isSelectionMode && !selectedAssets.isEmpty &&
                   (currentFilter == .all || currentFilter == .notUploaded) {
                    if photoLibraryManager.orderedIdentifiersGeneration == photoLibraryManager.assetFetchGeneration {
                        selectedAssets.formIntersection(Set(photoLibraryManager.orderedLocalIdentifiers))
                    } else {
                        // Selection identity must also survive deletions and
                        // Limited Photos access changes while using the All grid.
                        photoLibraryManager.requestIdentifierSnapshot()
                    }
                }
                recomputeCounts()
                if currentFilter == .favorites || currentFilter == .album {
                    refreshPhotoKitFilter()
                }
            }
        }
    }

    private func scheduleCountRefresh() {
        countRefreshTask?.cancel()
        countRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            recomputeCounts()
        }
    }
    
    @ViewBuilder
    private var processingStatusView: some View {
        if hashManager.isProcessing {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.vertical, 2)

                if let compactStatus = getCompactProcessingStatusText() {
                    Text(compactStatus)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(getProcessingStatusText())
        } else {
            EmptyView()
        }
    }

    private func getCompactProcessingStatusText() -> String? {
        switch processingStage {
        case let .analyzing(current, total):
            return current > 0 && total > 0 ? "\(current)/\(total)" : nil
        case let .checking(current, total):
            return current > 0 && total > 0 ? "\(current)/\(total)" : nil
        default:
            return nil
        }
    }
    
    private func getProcessingStatusText() -> String {
        let stage = PhotoGridProcessingStage.resolve(
            statusMessage: hashManager.statusMessage,
            processed: hashManager.processedAssetsCount,
            total: hashManager.totalAssetsToProcess,
            isSyncing: isSyncing,
            foregroundWorkPreparing: foregroundWorkPreparing
        )
        switch stage {
        case .syncingServer:
            return L10n.PhotoGrid.processingSyncingServer
        case .readingPhotoLibrary:
            if let progress = photoLibraryManager.foregroundBaselineProgress {
                return L10n.PhotoGrid.processingBaseline(progress.completed, progress.total)
            }
            return L10n.PhotoGrid.processingReadingPhotoLibrary
        case .preparingComparison:
            return L10n.PhotoGrid.processingPreparingComparison
        case let .analyzing(current, total):
            return total > 0 && current > 0
                ? "\(current)/\(total)"
                : L10n.PhotoGrid.processingPreparingComparison
        case let .checking(current, total):
            return total > 0 && current > 0
                ? L10n.PhotoGrid.processingComparing(current, total)
                : L10n.PhotoGrid.processingChecking
        case .defaultStatus:
            return L10n.PhotoGrid.processingWorking
        }
    }

    private var processingStage: PhotoGridProcessingStage {
        PhotoGridProcessingStage.resolve(
            statusMessage: hashManager.statusMessage,
            processed: hashManager.processedAssetsCount,
            total: hashManager.totalAssetsToProcess,
            isSyncing: isSyncing,
            foregroundWorkPreparing: foregroundWorkPreparing
        )
    }

    @ViewBuilder
    private var processingScreen: some View {
        if hashManager.isProcessing && processingStage.showsDedicatedScreen {
            VStack(spacing: 20) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)

                Text(L10n.PhotoGrid.processingTitle)
                    .font(.title3.weight(.semibold))

                Text(getProcessingStatusText())
                    .font(.headline)
                    .foregroundStyle(.secondary)

                if let progress = photoLibraryManager.foregroundBaselineProgress,
                   progress.total > 0 {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 280)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }

                Text(L10n.PhotoGrid.processingWaitingDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground).ignoresSafeArea())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(L10n.PhotoGrid.processingTitle), \(getProcessingStatusText()), \(L10n.PhotoGrid.processingWaitingDetail)"
            )
            .transition(.opacity)
            .zIndex(2)
        }
    }
    
    private func startBackgroundProcessing() {
        // Asset count zero is valid (all photos could be hidden or removed).
        // Wait until PhotoLibraryManager has a real fetch result before
        // creating an authoritative foreground persistent-change checkpoint.
        guard !photoLibraryManager.isLoading,
              photoLibraryManager.fetchResult != nil else { return }
        // The server-sync path may already have set the 'Preparing...' UI
        // placeholder; only an admitted hash run should defer new work.
        guard !hashManager.hasActivePipeline, !foregroundWorkPreparing else {
            foregroundRefreshPending = true
            return
        }

        foregroundWorkPreparing = true
        hashManager.setPreparingState()
        let manager = photoLibraryManager
        logInfo("Foreground PhotoKit work preparation started", category: .hash)
        Task.detached(priority: .utility) {
            // PhotoKit hash invalidation must not race with a server checksum
            // check that is about to write its verification result.
            logInfo("Foreground PhotoKit work waiting for verification gate", category: .hash)
            await ServerAssetVerificationGate.shared.acquire()
            logInfo("Foreground PhotoKit verification gate acquired", category: .hash)
            let work = manager.prepareForegroundPhotoWork()
            await ServerAssetVerificationGate.shared.release()
            logInfo("Foreground PhotoKit verification gate released", category: .hash)
            await MainActor.run {
                logInfo("Foreground PhotoKit preparation completed", category: .hash)
                foregroundWorkPreparing = false
                if hashManager.hasActivePipeline {
                    // Another legitimate hash run won admission while PhotoKit
                    // was preparing; leave the new work queued for the next pass.
                    foregroundRefreshPending = true
                    return
                }
                switch work {
                case .incremental(let identifiers):
                    // A zero-length delta still starts server status checks.
                    hashManager.startBackgroundProcessing(identifiers: identifiers)
                case .fallbackSnapshot(let snapshots):
                    hashManager.startBackgroundProcessing(snapshots: snapshots)
                case .unavailable:
                    hashManager.clearPreparingState()
                }
                if foregroundRefreshPending && !hashManager.hasActivePipeline {
                    foregroundRefreshPending = false
                    startBackgroundProcessing()
                }
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
                
                simpleGridView
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onChange(of: refreshToken) { _, _ in
                // Visible cells are rebound without onAppear after PhotoKit changes.
                refreshCurrentVisibleDate()
            }
            .onAppear { gridContainerWidth = geometry.size.width }
            .onChange(of: geometry.size.width) { _, w in gridContainerWidth = w }
            .onChange(of: thumbnailTargetSize) { _, _ in
                stopPrefetching()
                if displayCount > 0 {
                    prefetchThumbnails(aroundDisplayIndex: visibleDisplayIndices.min() ?? 0)
                }
            }
            .onDisappear {
                visibleDisplayIndices.removeAll()
            }
        }
    }
    
    // MARK: - Grid View with Dynamic Title
    
    @State private var currentVisibleDate: String = ""
    @State private var visibleDisplayIndices: Set<Int> = []
    @State private var firstRowTopOffset: CGFloat = 0
    
    /// Navigation title: hidden in selection mode, shows date when scrolled, default title otherwise
    private var navigationTitle: String {
        if isSelectionMode {
            return ""
        }
        if firstRowTopOffset < 0, !currentVisibleDate.isEmpty {
            return currentVisibleDate
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
            // Keep existing visible cells during PhotoKit refreshes. Reset
            // grid/scroll position only when the user explicitly changes filter.
            .id(gridResetToken)
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
        
        refreshCurrentVisibleDate()
    }

    private func refreshCurrentVisibleDate() {
        guard let minDisplayIndex = visibleDisplayIndices.min(),
              minDisplayIndex < displayCount else { return }
        let minAssetIndex = resolveActualIndex(minDisplayIndex)
        guard let date = assetForDisplay(at: minAssetIndex)?.creationDate else { return }
        
        let newText = DateFormatting.formatSectionDate(date)
        if newText != currentVisibleDate {
            currentVisibleDate = newText
        }
    }
    
    private func resolveActualIndex(_ displayIndex: Int) -> Int {
        switch currentFilter {
        case .all:
            return displayIndex
        case .notUploaded, .favorites, .album:
            guard displayIndex < filteredIndices.count else { return displayIndex }
            return filteredIndices[displayIndex]
        }
    }
    
    /// Resolve against the fetch that created the filtered index, not the
    /// manager's potentially newer fetch during in-progress enumeration.
    private func assetForDisplay(at actualIndex: Int) -> PHAsset? {
        if currentFilter == .all {
            return photoLibraryManager.asset(at: actualIndex)
        }
        guard let result = filteredFetchResult,
              actualIndex >= 0, actualIndex < result.count else { return nil }
        return result.object(at: actualIndex)
    }

    // MARK: - Grid Item View
    
    @ViewBuilder
    private func gridItemView(assetIndex: Int, displayIndex: Int) -> some View {
        PhotoGridItemView(
            photoLibraryManager: photoLibraryManager,
            hashManager: hashManager,
            filteredFetchSnapshot: currentFilter == .all ? nil : fetchStorage.filteredSnapshot,
            displayIndex: displayIndex,
            assetIndex: assetIndex,
            isSelectionMode: isSelectionMode,
            selectedAssets: $selectedAssets,
            namespace: photoTransitionNamespace,
            refreshToken: refreshToken,
            thumbnailTargetSize: thumbnailTargetSize,
            showingPhotoDetail: showingPhotoDetail,
            selectedPhotoIndex: selectedPhotoIndex,
            onTap: {
                if isSelectionMode {
                    guard canSelectDisplayedPhotos else { return }
                    toggleSelection(at: assetIndex)
                } else {
                    // Detail navigation still needs the current fetch generation.
                    openPhotoDetail(at: displayIndex)
                }
            },
            onLongPress: {
                guard canSelectDisplayedPhotos else { return }
                if !isSelectionMode {
                    isSelectionMode = true
                    if let id = assetForDisplay(at: assetIndex)?.localIdentifier {
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
        HStack(spacing: 8) {
            Image(systemName: currentFilter.iconName)
                .foregroundColor(.orange)
            Text(currentFilter == .album ? (selectedAlbum?.title ?? L10n.PhotoGrid.filterAlbum) : currentFilter.localizedTitle)
                .font(.subheadline)
                .lineLimit(1)
            // A PhotoKit refresh can be in flight while we still display a
            // valid previous PHFetchResult. Keep its count visible instead of
            // replacing the number with an indefinite loading spinner.
            // Only show progress before the first filtered snapshot exists.
            if isFilterLoading && filteredFetchResult == nil {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Text(L10n.PhotoGrid.filterActive(displayCount))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
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
                        if option == .album {
                            albumSearch = ""
                            isAlbumPickerPresented = true
                        } else {
                            applyFilter(option)
                        }
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
                            } else {
                                Image(systemName: option.iconName)
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

    private var albumPickerSheet: some View {
        NavigationStack {
            List {
                if isLoadingAlbums {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if visibleAlbumChoices.isEmpty {
                    Text(L10n.PhotoGrid.filterNoAlbums)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(visibleAlbumChoices) { album in
                        Button {
                            selectedAlbum = album
                            isAlbumPickerPresented = false
                            applyFilter(.album)
                        } label: {
                            HStack {
                                Text(album.title)
                                    .foregroundColor(.primary)
                                Spacer()
                                if currentFilter == .album && selectedAlbum?.id == album.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.PhotoGrid.filterChooseAlbum)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $albumSearch)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.PhotoGrid.cancel) {
                        isAlbumPickerPresented = false
                    }
                }
            }
            .task {
                loadAlbumChoices()
            }
        }
    }

    private func loadAlbumChoices() {
        albumLoadTask?.cancel()
        isLoadingAlbums = true
        albumLoadTask = Task {
            let albums = await Task.detached(priority: .utility) {
                PhotoLibraryManager.availableAlbums()
            }.value
            guard !Task.isCancelled else { return }
            albumChoices = albums
            isLoadingAlbums = false
        }
    }

    // MARK: - Filter Cache Management

    private func applyFilter(_ filter: PhotoFilterOption) {
        stopPrefetching()
        gridResetToken = UUID()
        selectionTask?.cancel()
        isSelectingAll = false
        selectedAssets.removeAll()
        dragState.reset()
        photoFilterTask?.cancel()
        photoFilterVersion += 1
        isFilterLoading = false
        currentFilter = filter
        filteredIndices = []
        filteredFetchResult = nil
        fetchStorage.filteredIndexGeneration = nil
        filteredIndicesGeneration = nil
        if showingPhotoDetail { showingPhotoDetail = false }
        if filter != .album {
            selectedAlbum = nil
        }

        switch filter {
        case .notUploaded:
            if let previousFetch = cachedNotUploadedFetchResult {
                filteredIndices = cachedNotUploadedIndices
                filteredFetchResult = previousFetch
                fetchStorage.filteredIndexGeneration = fetchStorage.cachedNotUploadedIndexGeneration
                filteredIndicesGeneration = cachedNotUploadedGeneration
            }
            let isCurrent = filteredIndicesGeneration == photoLibraryManager.assetFetchGeneration
            isFilterLoading = !isCurrent && photoLibraryManager.assetCount > 0
            logInfo(
                "Not-uploaded filter opened: visible=\(displayCount), current=\(isCurrent), " +
                "assets=\(photoLibraryManager.assetCount), generation=\(photoLibraryManager.assetFetchGeneration)",
                category: .app
            )
            recomputeCounts()
        case .favorites, .album:
            refreshPhotoKitFilter()
        case .all:
            refreshToken = UUID()
        }
    }

    /// Only enumerate the selected PhotoKit collection off the main actor. The
    /// resulting indices refer to the main gallery's original fetch order.
    private func refreshPhotoKitFilter() {
        guard currentFilter == .favorites || currentFilter == .album else { return }
        photoFilterTask?.cancel()
        photoFilterVersion += 1
        let version = photoFilterVersion
        let filter = currentFilter
        let generation = photoLibraryManager.assetFetchGeneration
        let identifiers = photoLibraryManager.orderedLocalIdentifiers
        let albumID = selectedAlbum?.id
        let shouldReconcileSelection = isSelectionMode && !selectedAssets.isEmpty

        // An all-assets fetch is published before its corresponding identifier
        // snapshot is built. Do not interpret index-based filters in that gap.
        guard photoLibraryManager.orderedIdentifiersGeneration == generation else {
            filteredIndicesGeneration = nil
            isFilterLoading = photoLibraryManager.assetCount > 0
            photoLibraryManager.requestIdentifierSnapshot()
            return
        }

        selectionTask?.cancel()
        isSelectingAll = false
        isFilterLoading = true

        photoFilterTask = Task.detached(priority: .utility) {
            let indices: [Int]
            switch filter {
            case .favorites:
                indices = PhotoLibraryManager.favoriteIndices(in: identifiers)
            case .album:
                if let albumID {
                    indices = PhotoLibraryManager.albumIndices(in: identifiers, albumID: albumID)
                } else {
                    indices = []
                }
            default:
                indices = []
            }

            guard !Task.isCancelled else { return }

            // Build membership off-main only if a selection existed at task
            // start; most filter refreshes need no extra set of identifiers.
            // Later selection edits are reconciled against the CURRENT set
            // when publishing, not against an obsolete selection snapshot.
            let visibleIdentifiers: Set<String>? = shouldReconcileSelection
                ? Set(indices.map { identifiers[$0] }) : nil
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard !Task.isCancelled, version == self.photoFilterVersion,
                      self.currentFilter == filter,
                      self.photoLibraryManager.assetFetchGeneration == generation,
                      self.photoLibraryManager.orderedIdentifiersGeneration == generation else { return }

                if self.showingPhotoDetail && self.filteredIndices != indices {
                    // PhotoDetailView stores its PHAsset in @State; dismiss rather
                    // than leave it showing a removed/incorrect album item.
                    self.showingPhotoDetail = false
                }
                if self.isSelectionMode, let visibleIdentifiers {
                    self.selectedAssets.formIntersection(visibleIdentifiers)
                }
                self.filteredIndices = indices
                self.filteredFetchResult = self.photoLibraryManager.fetchResult
                self.fetchStorage.filteredIndexGeneration = self.photoLibraryManager.assetIndexGeneration
                self.filteredIndicesGeneration = generation
                self.isFilterLoading = false
                self.refreshToken = UUID()
            }
        }
    }

    private func syncPendingICloudIds() {
        let serverURL = settingsManager.activeServerURL
        let apiKey = settingsManager.apiKey
        guard !serverURL.isEmpty && !apiKey.isEmpty else { return }
        // Drain once: repeated view refreshes must not submit the same
        // metadata updates while an earlier request is still in flight.
        let updates = hashManager.pendingICloudIdUpdates
        guard !updates.isEmpty else { return }
        hashManager.pendingICloudIdUpdates = []

        logInfo("Syncing \(updates.count) pending iCloud ID updates to server", category: .api)

        Task {
            let batchSize = 500
            var successCount = 0
            var skipCount = 0

            for batchStart in stride(from: 0, to: updates.count, by: batchSize) {
                let batch = Array(updates[batchStart..<min(batchStart + batchSize, updates.count)])
                let items = batch.map { update in
                    MetadataUpdateItem(
                        assetId: update.immichId,
                        key: RemoteAssetMetadataItem.mobileAppKey,
                        value: MobileAppMetadata(
                            iCloudId: update.iCloudId,
                            createdAt: nil,
                            sourceChecksum: update.sourceChecksum
                        )
                    )
                }

                do {
                    try await ImmichAPIService.shared.updateBulkAssetMetadata(
                        items: items,
                        serverURL: serverURL,
                        apiKey: apiKey
                    )
                    successCount += batch.count
                } catch ImmichAPIError.serverError(let statusCode, _) where statusCode == 400 || statusCode == 403 {
                    // Skip batch containing partner assets we don't own
                    skipCount += batch.count
                } catch {
                    logWarning("Failed to update iCloud ID batch: \(error.localizedDescription)", category: .api)
                    // The hash check was committed before metadata upload.
                    // A transient failure must persistently make these assets
                    // discoverable by the next run, not just requeue in memory
                    // (which the next processing start can otherwise clear).
                    let identifiers = batch.map(\.localIdentifier)
                    let restored = await Task.detached(priority: .utility) {
                        DatabaseManager.shared.invalidateHashChecksForLocalIdentifiers(identifiers)
                    }.value
                    if !restored {
                        logError("Could not persist metadata retry for \(batch.count) assets", category: .database)
                    }
                }
            }

            logInfo("iCloud ID sync done: \(successCount) updated, \(skipCount) skipped (no access)", category: .api)
        }
    }

    /// Single off-main pass that derives both the not-uploaded count and the
    /// filtered index set from the current syncStatusCache. Iterates the cached
    /// orderedLocalIdentifiers array (in-memory) rather than re-enumerating the
    /// lazy PHFetchResult, which is orders of magnitude faster on large
    /// libraries and lets the badge stay in sync with the per-photo icons.
    @MainActor
    private func recomputeCounts() {
        let manager = photoLibraryManager
        let hash = hashManager

        recomputeTask?.cancel()

        countComputeVersion += 1
        let version = countComputeVersion

        if currentFilter != .all,
           manager.orderedIdentifiersGeneration != manager.assetFetchGeneration {
            manager.requestIdentifierSnapshot()
            return
        }

        // PhotoKit content changes do not change upload membership. Rebind the
        // cached positions when both their order and status map are unchanged.
        if manager.orderedIdentifiersGeneration == manager.assetFetchGeneration,
           fetchStorage.canReuseNotUploadedIndices(
               indexGeneration: manager.assetIndexGeneration, statusGeneration: syncStatusGeneration
           ), let result = manager.fetchResult {
            cachedNotUploadedFetchResult = result
            cachedNotUploadedGeneration = manager.assetFetchGeneration
            if currentFilter == .notUploaded {
                filteredIndices = cachedNotUploadedIndices
                filteredFetchResult = result
                fetchStorage.filteredIndexGeneration = manager.assetIndexGeneration
                filteredIndicesGeneration = manager.assetFetchGeneration
                isFilterLoading = false
            }
            return
        }

        // Task { } inherits the caller's @MainActor isolation, regardless
        // of priority. Keep the full-library status scan off the UI thread.
        recomputeTask = Task.detached(priority: .utility) { [self] in
            let (statusCache, identifiers, generation, snapshotGeneration, indexGeneration, statusGeneration, totalCount) = await MainActor.run {
                (hash.syncStatusCache, manager.orderedLocalIdentifiers,
                 manager.assetFetchGeneration, manager.orderedIdentifiersGeneration,
                 manager.assetIndexGeneration, self.syncStatusGeneration, manager.assetCount)
            }
            guard !Task.isCancelled else { return }
            if snapshotGeneration != generation {
                guard let count = PhotoLibraryManager.notUploadedCount(
                    totalCount: totalCount, statuses: statusCache, shouldStop: { Task.isCancelled }
                ) else { return }
                await MainActor.run {
                    guard !Task.isCancelled, version == self.countComputeVersion,
                          manager.assetFetchGeneration == generation,
                          self.syncStatusGeneration == statusGeneration,
                          manager.orderedIdentifiersGeneration != generation else { return }
                    // A count does not certify cached positions. Indexed filters
                    // wait for their own complete, matching-generation snapshot.
                    self.cachedNotUploadedCount = count
                }
                return
            }

            var notUploadedIndices: [Int] = []
            notUploadedIndices.reserveCapacity(identifiers.count / 4)
            var uploadedCount = 0
            for (index, id) in identifiers.enumerated() {
                if Task.isCancelled { return }
                if statusCache[id] == .uploaded {
                    uploadedCount += 1
                } else {
                    notUploadedIndices.append(index)
                }
            }

            var statusEntryCount = statusCache.count
            var appliedStatusGeneration = statusGeneration
            // A transient status-cache replacement must not turn a populated
            // gallery into a false empty result. When a previously populated
            // list first reaches zero, confirm against the latest status map
            // after a short quiet interval before publishing it.
            let hadItems = await MainActor.run { self.cachedNotUploadedCount > 0 }
            if notUploadedIndices.isEmpty && hadItems {
                do {
                    try await Task.sleep(nanoseconds: 400_000_000)
                } catch { return }
                guard !Task.isCancelled else { return }
                let (latestStatuses, latestGeneration, latestSnapshot, latestIndexGeneration, latestStatusGeneration) = await MainActor.run {
                    (hash.syncStatusCache, manager.assetFetchGeneration, manager.orderedIdentifiersGeneration,
                     manager.assetIndexGeneration, self.syncStatusGeneration)
                }
                guard latestIndexGeneration == indexGeneration, latestSnapshot == latestGeneration else { return }
                appliedStatusGeneration = latestStatusGeneration
                notUploadedIndices.removeAll(keepingCapacity: true)
                uploadedCount = 0
                statusEntryCount = latestStatuses.count
                for (index, id) in identifiers.enumerated() {
                    if Task.isCancelled { return }
                    if latestStatuses[id] == .uploaded {
                        uploadedCount += 1
                    } else {
                        notUploadedIndices.append(index)
                    }
                }
            }

            await MainActor.run {
                // A later change may supersede either the PhotoKit generation
                // or this particular status-cache scan.
                guard !Task.isCancelled,
                      version == self.countComputeVersion,
                      manager.assetIndexGeneration == indexGeneration,
                      manager.orderedIdentifiersGeneration == manager.assetFetchGeneration,
                      self.syncStatusGeneration == appliedStatusGeneration,
                      let result = manager.fetchResult else { return }

                let previousCount = self.cachedNotUploadedCount
                let newCount = notUploadedIndices.count
                if newCount == 0 && previousCount > 0 {
                    logWarning(
                        "Not-uploaded count dropped to zero: previous=\(previousCount), " +
                        "assets=\(identifiers.count), uploaded=\(uploadedCount), " +
                        "statusEntries=\(statusEntryCount), generation=\(generation), " +
                        "filter=\(self.currentFilter), activeHash=\(hash.isProcessing)",
                        category: .app
                    )
                } else if previousCount == 0 && newCount > 0 && self.currentFilter == .notUploaded {
                    logInfo(
                        "Not-uploaded count restored: count=\(newCount), " +
                        "assets=\(identifiers.count), statusEntries=\(statusEntryCount), " +
                        "generation=\(generation)",
                        category: .app
                    )
                }
                self.cachedNotUploadedCount = newCount
                // Retain a valid indexed result even when another filter is
                // active; returning to Not Uploaded should be instantaneous.
                self.cachedNotUploadedIndices = notUploadedIndices
                self.cachedNotUploadedFetchResult = result
                self.fetchStorage.cachedNotUploadedIndexGeneration = manager.assetIndexGeneration
                self.fetchStorage.cachedNotUploadedStatusGeneration = appliedStatusGeneration
                self.cachedNotUploadedGeneration = manager.assetFetchGeneration

                if self.currentFilter == .notUploaded {
                    if self.showingPhotoDetail && self.filteredIndices != notUploadedIndices {
                        self.showingPhotoDetail = false
                    }
                    self.filteredIndices = notUploadedIndices
                    self.filteredFetchResult = result
                    self.fetchStorage.filteredIndexGeneration = manager.assetIndexGeneration
                    self.filteredIndicesGeneration = manager.assetFetchGeneration
                    self.isFilterLoading = false
                    self.refreshToken = UUID()
                }
            }
        }
    }
    
    private func openPhotoDetail(at index: Int) {
        // Keep the visible snapshot interactive while content-only updates
        // rebuild filters. Structural changes still reject stale positions.
        let canOpen = currentFilter == .all
            ? (!isFilterLoading && index >= 0 && index < displayCount)
            : fetchStorage.canOpenFilteredDetail(
                at: index, displayCount: displayCount,
                indexGeneration: photoLibraryManager.assetIndexGeneration
            )
        guard canOpen else { return }
        selectedPhotoIndex = index
        photoDetailIndexGeneration = photoLibraryManager.assetIndexGeneration
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            showingPhotoDetail = true
        }
    }
    
    private func onItemAppear(displayIndex: Int, assetIndex: Int) {
        prefetchThumbnails(aroundDisplayIndex: displayIndex)
        updateVisibleDate(for: displayIndex, assetIndex: assetIndex, isAppearing: true)
    }
    
    private func onItemDisappear(displayIndex: Int, assetIndex: Int) {
        updateVisibleDate(for: displayIndex, assetIndex: assetIndex, isAppearing: false)
    }
    
    private func stopPrefetching() {
        let targetSize = lastPrefetchedTargetSize ?? thumbnailTargetSize
        if let range = lastPrefetchedRange {
            ThumbnailCache.shared.stopPrefetching(
                for: photoLibraryManager.assets(in: range), targetSize: targetSize
            )
            lastPrefetchedRange = nil
        }
        if !lastPrefetchedFilteredAssets.isEmpty {
            ThumbnailCache.shared.stopPrefetching(
                for: lastPrefetchedFilteredAssets, targetSize: targetSize
            )
            lastPrefetchedFilteredAssets = []
        }
        lastPrefetchedTargetSize = nil
    }

    private func prefetchThumbnails(aroundDisplayIndex displayIndex: Int) {
        // Avoid competing PhotoKit native allocations during resource hashing.
        guard !hashManager.isProcessing, !isFilterLoading,
              displayIndex < displayCount else { return }

        let start = max(0, displayIndex - prefetchBuffer)
        let end = min(displayCount, displayIndex + prefetchBuffer + 1)
        guard start < end else { return }

        let targetSize = thumbnailTargetSize
        if let previousSize = lastPrefetchedTargetSize, previousSize != targetSize {
            stopPrefetching()
        }
        lastPrefetchedTargetSize = targetSize

        if currentFilter == .all {
            let newRange = start..<end
            let previousRange = lastPrefetchedRange
            guard previousRange != newRange else { return }

            // Visible rows shift the preheat window by only one or two assets.
            // Do not repeatedly submit the entire 25-asset window to PhotoKit.
            if let previousRange {
                let stale = previousRange.filter { !newRange.contains($0) }
                if !stale.isEmpty {
                    ThumbnailCache.shared.stopPrefetching(
                        for: stale.compactMap { photoLibraryManager.asset(at: $0) },
                        targetSize: targetSize
                    )
                }
            }

            let fresh = newRange.filter { previousRange?.contains($0) != true }
            lastPrefetchedRange = newRange
            if !fresh.isEmpty {
                ThumbnailCache.shared.prefetchThumbnails(
                    for: fresh.compactMap { photoLibraryManager.asset(at: $0) },
                    targetSize: targetSize
                )
            }
            return
        }

        // For Favorites/album/not-uploaded views, neighboring display items can
        // be far apart in the full library. Preheat only those visible neighbors.
        guard filteredIndicesGeneration == photoLibraryManager.assetFetchGeneration else { return }
        let assets = filteredIndices[start..<end].compactMap {
            photoLibraryManager.asset(at: $0)
        }
        let currentIDs = Set(assets.map(\.localIdentifier))
        let oldIDs = Set(lastPrefetchedFilteredAssets.map(\.localIdentifier))
        let stale = lastPrefetchedFilteredAssets.filter { !currentIDs.contains($0.localIdentifier) }
        let fresh = assets.filter { !oldIDs.contains($0.localIdentifier) }
        if !stale.isEmpty { ThumbnailCache.shared.stopPrefetching(for: stale, targetSize: targetSize) }
        if !fresh.isEmpty { ThumbnailCache.shared.prefetchThumbnails(for: fresh, targetSize: targetSize) }
        lastPrefetchedFilteredAssets = assets
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
        // Preserve the original intentional scroll reset on manual refresh,
        // while keeping background PhotoKit updates free of grid-wide flashes.
        gridResetToken = UUID()

        recomputeCounts()
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
        guard canSelectDisplayedPhotos, let idx = displayIndex(at: point) else { return }
        let actualIdx = resolveActualIndex(idx)
        
        dragState.baseSelection = selectedAssets
        dragState.anchorIndex = idx
        dragState.currentIndex = idx
        
        if let id = assetForDisplay(at: actualIdx)?.localIdentifier {
            dragState.isDeselecting = selectedAssets.contains(id)
        }
        
        applyDragRange(from: idx, to: idx)
    }
    
    private func handleDragChanged(at point: CGPoint) {
        guard canSelectDisplayedPhotos, let anchor = dragState.anchorIndex else { return }
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
            guard let id = assetForDisplay(at: actual)?.localIdentifier else { continue }
            if dragState.isDeselecting {
                next.remove(id)
            } else {
                next.insert(id)
            }
        }
        selectedAssets = next
    }
    
    private func selectAllNotUploaded() {
        let statusCache = hashManager.syncStatusCache
        guard canSelectDisplayedPhotos, !isSelectingAll,
              let fetchResult = currentFilter == .all
                ? photoLibraryManager.fetchResult : filteredFetchResult else { return }
        let selectedFilter = currentFilter
        // The visible indices belong to the retained fetch, not necessarily
        // the manager's newest PhotoKit generation.
        let visibleIndices: [Int]? = currentFilter == .all ? nil : filteredIndices

        isSelectingAll = true
        selectionTask?.cancel()
        selectionTask = Task(priority: .userInitiated) {
            var ids = Set<String>()
            if let visibleIndices {
                ids.reserveCapacity(visibleIndices.count)
                for index in visibleIndices {
                    if Task.isCancelled { return }
                    guard index >= 0, index < fetchResult.count else { continue }
                    let id = fetchResult.object(at: index).localIdentifier
                    if (statusCache[id] ?? .pending) != .uploaded {
                        ids.insert(id)
                    }
                }
            } else {
                ids.reserveCapacity(fetchResult.count / 4)
                fetchResult.enumerateObjects { asset, _, stop in
                    if Task.isCancelled {
                        stop.pointee = true
                        return
                    }
                    if (statusCache[asset.localIdentifier] ?? .pending) != .uploaded {
                        ids.insert(asset.localIdentifier)
                    }
                }
            }

            await MainActor.run {
                guard !Task.isCancelled else { return }
                let displayedFetch = self.currentFilter == .all
                    ? self.photoLibraryManager.fetchResult : self.filteredFetchResult
                if self.currentFilter == selectedFilter &&
                   displayedFetch === fetchResult && self.isSelectionMode {
                    self.selectedAssets = ids
                }
                self.isSelectingAll = false
            }
        }
    }

    private func toggleSelection(at index: Int) {
        guard let identifier = assetForDisplay(at: index)?.localIdentifier else { return }
        if selectedAssets.contains(identifier) {
            selectedAssets.remove(identifier)
        } else {
            selectedAssets.insert(identifier)
        }
    }
    
    private func uploadSelectedPhotos() {
        // Selected identifiers are stable across PhotoKit generations; resolve
        // them against the CURRENT library when the upload actually begins.
        guard !selectedAssets.isEmpty else { return }
        let identifiersToUpload = Array(selectedAssets)
        let manager = uploadManager

        // End this selection session immediately. The PhotoKit fetch below may
        // take time; its eventual completion must not cancel a NEW selection
        // session the user has started in the meantime.
        selectionTask?.cancel()
        selectionTask = nil
        isSelectingAll = false
        isSelectionMode = false
        selectedAssets.removeAll()
        dragState.reset()

        Task.detached(priority: .userInitiated) {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiersToUpload, options: nil)
            var assetsToUpload: [PHAsset] = []
            assetsToUpload.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                assetsToUpload.append(asset)
            }
            
            await MainActor.run {
                manager.uploadAssets(assetsToUpload)
            }
        }
    }
    
    // MARK: - Auto Sync
    
    private func performAutoSync() {
        let serverURL = settingsManager.activeServerURL
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
            apiKey: apiKey
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
    let filteredFetchSnapshot: PhotoGridFetchStorage<PHFetchResult<PHAsset>>.Snapshot?
    let displayIndex: Int
    let assetIndex: Int
    let isSelectionMode: Bool
    @Binding var selectedAssets: Set<String>
    let namespace: Namespace.ID
    let refreshToken: UUID
    let thumbnailTargetSize: CGSize
    let showingPhotoDetail: Bool
    let selectedPhotoIndex: Int
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onAppear: () -> Void
    let onDisappear: () -> Void
    
    @State private var asset: PHAsset?
    @State private var isCellActive = false
    @State private var appliedEditGeneration: Int?
    @State private var observedAssetIdentifier: String?
    @State private var observedContentRevision: PhotoAssetContentRevision?
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
                    targetSize: thumbnailTargetSize,
                    editGeneration: appliedEditGeneration,
                    isGeometrySource: !isThisAssetSelected
                )
                // The grid can reuse the same display index after an insert or
                // filter change. Never reuse the previous photo's @State image.
                .id(asset.localIdentifier)
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
            isCellActive = true
            loadAsset()
            onAppear()
        }
        .onDisappear {
            isCellActive = false
            // LazyVGrid may retain offscreen rows; drop their PhotoKit objects.
            asset = nil
            appliedEditGeneration = nil
            observedAssetIdentifier = nil
            observedContentRevision = nil
            onDisappear()
        }
        .onChange(of: assetIndex) { _, _ in
            // Rebind only visible rows. Offscreen rows have released their assets.
            if isCellActive { loadAsset() }
        }
        .onChange(of: refreshToken) { _, _ in
            // Update visible cells after a PhotoKit fetch replacement without
            // rematerializing assets in offscreen LazyVGrid state.
            if isCellActive { loadAsset() }
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
        let newAsset: PHAsset?
        if let binding = filteredFetchSnapshot {
            // An expired filtered binding stays empty. Falling back to the
            // manager would resolve this old index against a different fetch.
            let snapshot = binding.value
            newAsset = if let snapshot, assetIndex >= 0 && assetIndex < snapshot.count {
                snapshot.object(at: assetIndex)
            } else {
                nil
            }
        } else {
            newAsset = photoLibraryManager.asset(at: assetIndex)
        }
        asset = newAsset
        if let id = newAsset?.localIdentifier {
            let isCurrentFetch = filteredFetchSnapshot == nil ||
                filteredFetchSnapshot?.value === photoLibraryManager.fetchResult
            if isCurrentFetch {
                // Compare PhotoKit's actual cache invalidation revision, rather
                // than a mutable changed-ID set from the latest notification.
                let revision = ThumbnailCache.shared.contentRevision(for: id)
                let needsContentRefresh = PhotoAssetContentRevision.needsReload(
                    previousIdentifier: observedAssetIdentifier,
                    previousRevision: observedContentRevision,
                    currentIdentifier: id,
                    currentRevision: revision
                )
                if observedAssetIdentifier != id {
                    // .id(asset.localIdentifier) replaces the thumbnail on reuse.
                    appliedEditGeneration = nil
                } else if needsContentRefresh {
                    // Retain this token across unrelated updates until the next
                    // real edit, rather than hiding a not-yet-rendered change.
                    appliedEditGeneration = photoLibraryManager.assetFetchGeneration
                }
                observedAssetIdentifier = id
                observedContentRevision = revision
            }
            syncStatus = hashManager.getSyncStatus(for: id)
        } else {
            appliedEditGeneration = nil
            observedAssetIdentifier = nil
            observedContentRevision = nil
        }
    }
}

#Preview {
    PhotoGridView()
        .environmentObject(SettingsManager())
        .environmentObject(UploadManager())
}
