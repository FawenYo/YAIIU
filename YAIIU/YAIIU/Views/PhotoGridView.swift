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

/// Keeps the compact processing strip from flashing for reconciliations that
/// finish without work (e.g. iCloud thumbnail downloads reported as updates).
enum PhotoGridProcessingStripPolicy {
    struct Transition: Equatable {
        let revealed: Bool
        let after: Duration
    }

    static let revealDelay: Duration = .milliseconds(800)
    // Bridges the short idle gap between back-to-back runs of genuine work.
    static let hideDelay: Duration = .milliseconds(400)

    static func transition(isProcessing: Bool, isRevealed: Bool) -> Transition? {
        switch (isProcessing, isRevealed) {
        case (true, false):
            return Transition(revealed: true, after: revealDelay)
        case (false, true):
            return Transition(revealed: false, after: hideDelay)
        default:
            return nil
        }
    }

    static func isVisible(isRevealed: Bool, baselineInProgress: Bool) -> Bool {
        isRevealed && !baselineInProgress
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

// MARK: - Drag-to-Select Gesture

/// A horizontal pan on the grid's collection view for drag-to-select.
/// Disables scrolling while active and auto-scrolls near the edges.
private final class DragSelectionGesture: NSObject, UIGestureRecognizerDelegate {
    var isEnabled = false
    var onBegan: ((Int) -> Void)?
    var onChanged: ((Int) -> Void)?
    var onEnded: (() -> Void)?

    private weak var collectionView: UICollectionView?
    private var pan: UIPanGestureRecognizer?

    private var displayLink: CADisplayLink?
    private var autoScrollSpeed: CGFloat = 0
    private let edgeInset: CGFloat = 60
    private let maxScrollSpeed: CGFloat = 800

    deinit {
        displayLink?.invalidate()
    }

    func install(on collectionView: UICollectionView) {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        gesture.delegate = self
        collectionView.addGestureRecognizer(gesture)
        pan = gesture
        self.collectionView = collectionView
    }

    private func item(at point: CGPoint) -> Int? {
        collectionView?.indexPathForItem(at: point)?.item
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
        guard let scrollView = collectionView else { return }
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
        guard let scrollView = collectionView,
              let gesture = pan,
              gesture.state == .changed || gesture.state == .began else {
            stopAutoScroll()
            return
        }

        let dt = CGFloat(link.targetTimestamp - link.timestamp)
        var offset = scrollView.contentOffset
        let inset = scrollView.adjustedContentInset

        offset.y += autoScrollSpeed * dt
        let minY = -inset.top
        let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        offset.y = min(max(offset.y, minY), maxY)
        scrollView.contentOffset = offset

        if let index = item(at: gesture.location(in: scrollView)) {
            onChanged?(index)
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard isEnabled, let scrollView = collectionView else { return }
        let loc = gesture.location(in: scrollView)

        switch gesture.state {
        case .began:
            // Disable only the scroll pan: toggling isScrollEnabled left the
            // iOS 26 scroll edge effect opaque until the next real scroll.
            scrollView.panGestureRecognizer.isEnabled = false
            if let index = item(at: loc) { onBegan?(index) }
        case .changed:
            if let index = item(at: loc) { onChanged?(index) }
            let touchRelative = CGPoint(x: loc.x, y: loc.y - scrollView.contentOffset.y)
            updateAutoScroll(frameRelativeTouch: touchRelative)
        case .ended, .cancelled, .failed:
            stopAutoScroll()
            scrollView.panGestureRecognizer.isEnabled = true
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

// MARK: - Photo Grid Collection View

/// Square cells in a fixed number of columns, sized from the current width.
private final class SquareGridLayout: UICollectionViewFlowLayout {
    let columnCount: Int
    let spacing: CGFloat
    let horizontalPadding: CGFloat

    init(columnCount: Int, spacing: CGFloat, horizontalPadding: CGFloat) {
        self.columnCount = columnCount
        self.spacing = spacing
        self.horizontalPadding = horizontalPadding
        super.init()
        minimumInteritemSpacing = spacing
        minimumLineSpacing = spacing
        sectionInset = UIEdgeInsets(top: 0, left: horizontalPadding, bottom: 0, right: horizontalPadding)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepare() {
        if let collectionView {
            let usable = collectionView.bounds.width - horizontalPadding * 2 - spacing * CGFloat(columnCount - 1)
            let scale = collectionView.traitCollection.displayScale
            // Round down to whole pixels so rounding never wraps the last column.
            let side = max(1, floor(usable / CGFloat(columnCount) * scale) / scale)
            itemSize = CGSize(width: side, height: side)
        }
        super.prepare()
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}

/// UIKit grid with reused cells. LazyVGrid kept every scrolled-past cell's
/// view graph alive, so memory grew with scroll distance on large libraries.
private struct PhotoGridCollectionView<Cell: View>: UIViewRepresentable {
    let itemCount: Int
    /// Changes when the grid must return to the top (filter change, manual refresh).
    let resetToken: UUID
    let isSelectionMode: Bool
    let columnCount: Int
    let spacing: CGFloat
    let horizontalPadding: CGFloat
    let cell: (Int) -> Cell
    let onScrolledPastTopChanged: (Bool) -> Void
    let onRefresh: () async -> Void
    let onDragBegan: (Int) -> Void
    let onDragChanged: (Int) -> Void
    let onDragEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = SquareGridLayout(
            columnCount: columnCount, spacing: spacing, horizontalPadding: horizontalPadding
        )
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.register(PhotoGridCell.self, forCellWithReuseIdentifier: Coordinator.reuseIdentifier)
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator

        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)), for: .valueChanged)
        collectionView.refreshControl = refreshControl

        context.coordinator.dragSelection.install(on: collectionView)
        context.coordinator.applyDragHandlers()
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        let previous = coordinator.parent
        coordinator.parent = self
        coordinator.inputsVersion &+= 1
        coordinator.applyDragHandlers()

        if resetToken != previous.resetToken {
            collectionView.reloadData()
            // A pull-to-refresh is already at the top; moving the offset under
            // the active refresh control makes its animation stutter.
            if collectionView.refreshControl?.isRefreshing != true {
                collectionView.layoutIfNeeded()
                collectionView.setContentOffset(
                    CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false
                )
            }
        } else if itemCount != previous.itemCount {
            collectionView.reloadData()
        } else {
            // Rebind visible cells to the latest SwiftUI inputs; cell views react
            // to index/refresh changes themselves. Prefetched off-screen cells are
            // rebound in willDisplay.
            for indexPath in collectionView.indexPathsForVisibleItems {
                if let cell = collectionView.cellForItem(at: indexPath) as? PhotoGridCell {
                    coordinator.configure(cell, item: indexPath.item)
                }
            }
        }
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        static var reuseIdentifier: String { "PhotoGridCell" }

        var parent: PhotoGridCollectionView
        let dragSelection = DragSelectionGesture()
        private var isScrolledPastTop = false
        /// Bumped on every SwiftUI update; cells record the version they were built from.
        var inputsVersion = 0

        init(parent: PhotoGridCollectionView) {
            self.parent = parent
        }

        func applyDragHandlers() {
            dragSelection.isEnabled = parent.isSelectionMode
            dragSelection.onBegan = parent.onDragBegan
            dragSelection.onChanged = parent.onDragChanged
            dragSelection.onEnded = parent.onDragEnded
        }

        func configure(_ cell: PhotoGridCell, item: Int) {
            // Identity per item gives each reuse fresh SwiftUI state and lifecycle.
            cell.contentConfiguration = UIHostingConfiguration {
                parent.cell(item).id(item)
            }
            .margins(.all, 0)
            cell.configuredVersion = inputsVersion
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.itemCount
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Self.reuseIdentifier, for: indexPath)
            if let cell = cell as? PhotoGridCell {
                configure(cell, item: indexPath.item)
            }
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            // Cell prefetching can configure a cell before a later update changed its inputs.
            guard let cell = cell as? PhotoGridCell, cell.configuredVersion != inputsVersion else { return }
            configure(cell, item: indexPath.item)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let isPast = scrollView.contentOffset.y + scrollView.adjustedContentInset.top > 0
            guard isPast != isScrolledPastTop else { return }
            isScrolledPastTop = isPast
            parent.onScrolledPastTopChanged(isPast)
        }

        @objc func handleRefresh(_ sender: UIRefreshControl) {
            Task { @MainActor in
                await parent.onRefresh()
                sender.endRefreshing()
            }
        }
    }
}

private final class PhotoGridCell: UICollectionViewCell {
    var configuredVersion = -1
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
    @State private var isProcessingStripRevealed = false
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
    /// nil means the full, matching-generation count is not yet trustworthy.
    @State private var cachedNotUploadedCount: Int?
    @State private var waitingForPostUploadRefresh = false
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
    
    private let prefetchBuffer = 12

    /// Point side of one square cell; nil until the container is measured.
    private var gridCellSide: CGFloat? {
        guard gridContainerWidth > 0 else { return nil }
        let spacing = CGFloat(Self.columnCount - 1) * Self.gridSpacing
        let usable = gridContainerWidth - Self.gridHorizontalPadding * 2 - spacing
        return max(1, usable / CGFloat(Self.columnCount))
    }

    /// One pixel size for the uniform three-column grid, used by both visible
    /// thumbnail requests and PhotoKit preheating/cancellation.
    private var thumbnailTargetSize: CGSize {
        guard let gridCellSide else { return ThumbnailCache.defaultTargetSize }
        return ThumbnailCache.targetSize(forGridCellWidth: gridCellSide, displayScale: displayScale)
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
    /// Limited Photos users still need a functioning filtered gallery.
    /// Only the count requires a full-access inventory.
    /// Never store or log this value. It only scopes the in-memory snapshot.
    private var statusDestinationIdentity: String {
        settingsManager.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            + "|" + settingsManager.apiKey
    }

    private var canBuildNotUploadedFilter: Bool {
        PhotoLibraryStatusCount.canBuildNotUploadedFilter(
            hasLoadedStatusSnapshot: hashManager.hasLoadedSyncStatusCache,
            hasPhotoLibraryFetch: photoLibraryManager.fetchResult != nil,
            isPhotoLibraryLoading: photoLibraryManager.isLoading
        )
    }

    private var canPresentNotUploadedCount: Bool {
        !waitingForPostUploadRefresh && PhotoLibraryStatusCount.canPresentCount(
            statusCacheReady: hashManager.isSyncStatusCacheReady,
            inventoryUpToDate: photoLibraryManager.isInventoryReconciled,
            isServerSyncing: isSyncing,
            isHashProcessing: hashManager.isProcessing,
            isUploading: uploadManager.isUploading,
            hasFullPhotoAccess: photoLibraryManager.authorizationStatus == .authorized,
            hasPhotoLibraryFetch: photoLibraryManager.fetchResult != nil,
            isPhotoLibraryLoading: photoLibraryManager.isLoading
        )
    }

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
                .toolbar(.visible, for: .navigationBar)
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
                            // Keep this navigation item dedicated to filtering:
                            // processing labels are drawn on a separate content
                            // row so they can never compress or cover the menu.
                            filterMenuButton
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
            hashManager.bindProvisionalSyncStatus(to: statusDestinationIdentity)
            if !hasAppeared {
                hasAppeared = true
                photoLibraryManager.requestAuthorization { status in
                    if status != .authorized && status != .limited {
                        hashManager.clearPreparingState()
                    }
                }
            }
            performAutoSync()
            scheduleCountRefresh()
            if currentFilter == .favorites || currentFilter == .album {
                refreshPhotoKitFilter()
            }
        }
        .onChange(of: settingsManager.serverURL) { _, _ in
            hashManager.bindProvisionalSyncStatus(to: statusDestinationIdentity)
            scheduleCountRefresh()
        }
        .onChange(of: settingsManager.apiKey) { _, _ in
            hashManager.bindProvisionalSyncStatus(to: statusDestinationIdentity)
            scheduleCountRefresh()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                // Photos permission can be changed in Settings while the
                // existing grid stays alive. Update the published gate first.
                photoLibraryManager.refreshAuthorizationStatus()
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
            cachedNotUploadedCount = nil
            recomputeTask?.cancel()
            countComputeVersion &+= 1
            if newValue { waitingForPostUploadRefresh = true }
            if oldValue && !newValue {
                waitingForPostUploadRefresh = true
                Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 500_000_000) }
                    catch { return }
                    await hashManager.refreshStatusCacheAsync()
                    guard !uploadManager.isUploading else { return }
                    waitingForPostUploadRefresh = false
                    scheduleCountRefresh()
                }
            }
        }
        .onChange(of: isSyncing) { _, syncing in
            if syncing {
                cachedNotUploadedCount = nil
                recomputeTask?.cancel()
                countComputeVersion &+= 1
            } else {
                scheduleCountRefresh()
            }
        }
        .onChange(of: hashManager.isProcessing) { oldValue, newValue in
            if newValue {
                cachedNotUploadedCount = nil
                recomputeTask?.cancel()
                countComputeVersion &+= 1
                // Pause only PhotoKit preheating. Do not clear visible cache or
                // cancel existing image requests (the PR #90 spinner regression).
                stopPrefetching()
            } else if oldValue {
                scheduleCountRefresh()
                syncPendingICloudIds()
                if foregroundRefreshPending {
                    foregroundRefreshPending = false
                    startBackgroundProcessing()
                }
            }
        }
        // The count must track the same source as the per-photo icons
        // (syncStatusCache). finishProcessing() flips isProcessing before the
        // authoritative DB reload lands, so reacting to the cache replacement
        // ensures the count converges to the final state instead of a
        // mid-flight snapshot. Hash-phase per-asset transitions never change
        // uploaded membership, so only count-affecting changes are observed.
        // Use onReceive, not onChange(of:): onChange only fires when SwiftUI's
        // diff sees a new value during body re-eval, which can be skipped.
        .onReceive(hashManager.$countAffectingStatusGeneration.receive(on: RunLoop.main)) { _ in
            cachedNotUploadedCount = nil
            syncStatusGeneration &+= 1
            scheduleCountRefresh()
        }
        .onReceive(hashManager.$isSyncStatusCacheReady.receive(on: RunLoop.main)) { _ in
            scheduleCountRefresh()
        }
        .onReceive(hashManager.$hasLoadedSyncStatusCache.receive(on: RunLoop.main)) { loaded in
            if loaded && currentFilter == .notUploaded {
                // Resume building the filtered index as soon as the initial
                // SQLite snapshot becomes available, even during backfill.
                scheduleCountRefresh()
            }
        }
        .onReceive(photoLibraryManager.$assetFetchGeneration.receive(on: RunLoop.main)) { _ in
            cachedNotUploadedCount = nil
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
            // Old ranges refer to the previous fetch and were never stopped, so every
            // PhotoKit notification (iCloud thumbnail downloads arrive constantly while
            // scrolling) leaked a preheat window. Drop all preheats; visible cells
            // re-preheat their neighbors on the next appear.
            ThumbnailCache.shared.stopAllPrefetching()
            lastPrefetchedRange = nil
            lastPrefetchedFilteredAssets = []
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
        .onReceive(photoLibraryManager.$inventoryChangeRevision.receive(on: RunLoop.main)) { revision in
            guard revision > 0 else { return }
            cachedNotUploadedCount = nil
            recomputeTask?.cancel()
            countComputeVersion &+= 1
            // Reconcile PhotoKit's journal and adjustment versions before publishing a
            // count from local_photo_assets. The existing gate coalesces bursts
            // and preserves pending work while hashing is active.
            startBackgroundProcessing()
        }
        .onReceive(photoLibraryManager.$libraryRevision.receive(on: RunLoop.main)) { _ in
            cachedNotUploadedCount = nil
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
        if PhotoGridProcessingStripPolicy.isVisible(
            isRevealed: isProcessingStripRevealed,
            baselineInProgress: photoLibraryManager.foregroundBaselineProgress != nil
        ) {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.vertical, 2)

                Text(getCompactProcessingStatusText())
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGray6))
            .allowsHitTesting(false)
            .accessibilityLabel(getProcessingStatusText())
        } else {
            EmptyView()
        }
    }

    private func getCompactProcessingStatusText() -> String {
        switch processingStage {
        case let .analyzing(current, total):
            return current > 0 && total > 0
                ? "\(current)/\(total)"
                : L10n.PhotoGrid.processingPreparing
        case let .checking(current, total):
            return current > 0 && total > 0
                ? "\(current)/\(total)"
                : L10n.PhotoGrid.processingPreparing
        default:
            return L10n.PhotoGrid.processingPreparing
        }
    }
    
    private func getProcessingStatusText() -> String {
        switch processingStage {
        case let .analyzing(current, total):
            return total > 0 && current > 0
                ? "\(current)/\(total)"
                : L10n.PhotoGrid.processingPreparing
        case let .checking(current, total):
            return total > 0 && current > 0
                ? L10n.PhotoGrid.processingComparing(current, total)
                : L10n.PhotoGrid.processingPreparing
        default:
            return L10n.PhotoGrid.processingPreparing
        }
    }

    private func getProcessingDetailText() -> String {
        if let progress = photoLibraryManager.foregroundBaselineProgress {
            return L10n.PhotoGrid.processingBaseline(progress)
        }
        return L10n.PhotoGrid.processingReadingPhotoLibrary
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
        // Keep an existing gallery browsable during a large metadata baseline.
        // A dedicated content-row status and conservative upload/count readiness
        // gates remain active; show this placeholder only before first paint.
        if hashManager.isProcessing,
           photoLibraryManager.fetchResult == nil,
           photoLibraryManager.foregroundBaselineProgress != nil {
            VStack(spacing: 20) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)

                Text(L10n.PhotoGrid.processingTitle)
                    .font(.title3.weight(.semibold))

                Text(getProcessingDetailText())
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
                "\(L10n.PhotoGrid.processingTitle), \(getProcessingDetailText()), \(L10n.PhotoGrid.processingWaitingDetail)"
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
        // A newer live PhotoKit event can arrive while the journal is replaying.
        // Acknowledge only the revision this pass was initiated to cover.
        let inventoryRevision = manager.inventoryChangeRevision
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
                    manager.acknowledgeInventoryReconciliation(through: inventoryRevision)
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
                // Keep both progress stages below the NavigationView toolbar.
                // Filter / Select controls always retain their full toolbar row.
                PhotoKitBaselineBanner()
                processingStatusView
                if currentFilter != .all {
                    filterIndicatorView
                }

                simpleGridView
                    // Scroll content under the tab bar, as SwiftUI's ScrollView did;
                    // the collection view insets its content for the safe area.
                    .ignoresSafeArea(.container, edges: .bottom)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .task(id: hashManager.isProcessing) {
                guard let transition = PhotoGridProcessingStripPolicy.transition(
                    isProcessing: hashManager.isProcessing,
                    isRevealed: isProcessingStripRevealed
                ) else { return }
                try? await Task.sleep(for: transition.after)
                guard !Task.isCancelled else { return }
                isProcessingStripRevealed = transition.revealed
            }
            .onDisappear { isProcessingStripRevealed = false }
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
    @State private var isScrolledPastFirstRow = false
    
    /// Navigation title: hidden in selection mode, shows date when scrolled, default title otherwise
    private var navigationTitle: String {
        if isSelectionMode {
            return ""
        }
        if isScrolledPastFirstRow, !currentVisibleDate.isEmpty {
            return currentVisibleDate
        }
        return L10n.PhotoGrid.title
    }
    
    private var simpleGridView: some View {
        PhotoGridCollectionView(
            itemCount: displayCount,
            resetToken: gridResetToken,
            isSelectionMode: isSelectionMode,
            columnCount: Self.columnCount,
            spacing: Self.gridSpacing,
            horizontalPadding: Self.gridHorizontalPadding,
            cell: { displayIndex in
                gridItemView(assetIndex: resolveActualIndex(displayIndex), displayIndex: displayIndex)
            },
            onScrolledPastTopChanged: { isScrolledPastFirstRow = $0 },
            onRefresh: { await refreshPhotosAsync() },
            onDragBegan: { handleDragBegan(at: $0) },
            onDragChanged: { handleDragChanged(at: $0) },
            onDragEnded: { handleDragEnded() }
        )
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
            statusCache: hashManager.syncStatusCache,
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
            onEvent: { event in
                handleCellEvent(event, displayIndex: displayIndex, assetIndex: assetIndex)
            }
        )
        .clipped()
    }

    private func handleCellEvent(_ event: GridCellEvent, displayIndex: Int, assetIndex: Int) {
        switch event {
        case .tap:
            if isSelectionMode {
                guard canSelectDisplayedPhotos else { return }
                toggleSelection(at: assetIndex)
            } else {
                // Detail navigation still needs the current fetch generation.
                openPhotoDetail(at: displayIndex)
            }
        case .longPress:
            guard canSelectDisplayedPhotos else { return }
            if !isSelectionMode {
                isSelectionMode = true
                if let id = assetForDisplay(at: assetIndex)?.localIdentifier {
                    selectedAssets.insert(id)
                }
            }
        case .appear:
            onItemAppear(displayIndex: displayIndex, assetIndex: assetIndex)
        case .disappear:
            onItemDisappear(displayIndex: displayIndex, assetIndex: assetIndex)
        }
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
            } else if currentFilter == .notUploaded && !canPresentNotUploadedCount {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.65)
                    Text(L10n.PhotoGrid.filterUpdating)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .accessibilityLabel(L10n.PhotoGrid.filterUpdating)
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
                        if option == .notUploaded,
                           canPresentNotUploadedCount,
                           let count = cachedNotUploadedCount {
                            Text("\(option.localizedTitle) (\(count))")
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

    /// The badge comes from the durable PhotoKit-ID inventory joined to SQLite
    /// upload state. Only the actual Not Uploaded gallery needs an ordered
    /// identifier scan to build its display positions; never enumerate Photos
    /// merely to display a menu badge.
    @MainActor
    private func recomputeCounts() {
        let manager = photoLibraryManager
        let hash = hashManager

        recomputeTask?.cancel()

        countComputeVersion += 1
        let version = countComputeVersion

        // Never treat an empty/not-yet-loaded status map as evidence that all
        // photos still need uploading. A provisional status snapshot may still
        // build the user's Not Uploaded index while its count remains hidden.
        if !canPresentNotUploadedCount { cachedNotUploadedCount = nil }
        guard canBuildNotUploadedFilter else { return }
        guard canPresentNotUploadedCount || currentFilter == .notUploaded else { return }

        if currentFilter == .notUploaded,
           manager.orderedIdentifiersGeneration != manager.assetFetchGeneration {
            manager.requestIdentifierSnapshot()
            return
        }

        // An indexed gallery is a presentation cache, never an authoritative
        // badge count. Rebind reusable positions, but always refresh the badge
        // independently using SQLite (even when the gallery is already cached).
        let shouldQueryAuthoritativeCount = canPresentNotUploadedCount
        let canReuseIndices =
            manager.orderedIdentifiersGeneration == manager.assetFetchGeneration &&
            fetchStorage.canReuseNotUploadedIndices(
                indexGeneration: manager.assetIndexGeneration,
                statusGeneration: syncStatusGeneration
            ) && manager.fetchResult != nil
        if canReuseIndices, let result = manager.fetchResult {
            cachedNotUploadedFetchResult = result
            cachedNotUploadedGeneration = manager.assetFetchGeneration
            if currentFilter == .notUploaded {
                filteredIndices = cachedNotUploadedIndices
                filteredFetchResult = result
                fetchStorage.filteredIndexGeneration = manager.assetIndexGeneration
                filteredIndicesGeneration = manager.assetFetchGeneration
                isFilterLoading = false
            }
        }

        // Task { } inherits the caller's @MainActor isolation, regardless
        // of priority. Keep the full-library status scan off the UI thread.
        recomputeTask = Task.detached(priority: .utility) { [self] in
            let (statusCache, identifiers, generation, snapshotGeneration, indexGeneration, statusGeneration, requiresIndices) = await MainActor.run {
                (hash.syncStatusCache, manager.orderedLocalIdentifiers,
                 manager.assetFetchGeneration, manager.orderedIdentifiersGeneration,
                 manager.assetIndexGeneration, self.syncStatusGeneration,
                 self.currentFilter == .notUploaded && !canReuseIndices)
            }
            guard !Task.isCancelled else { return }

            // The sole source of truth for the menu badge. Building filtered
            // indices never substitutes an in-memory count for this SQL result.
            let sqlCount = shouldQueryAuthoritativeCount
                ? DatabaseManager.shared.countNotUploadedVisibleAssets() : nil
            guard !Task.isCancelled else { return }
            if !requiresIndices || snapshotGeneration != generation {
                guard let count = sqlCount else { return }
                await MainActor.run {
                    guard !Task.isCancelled, version == self.countComputeVersion,
                          manager.assetFetchGeneration == generation,
                          self.syncStatusGeneration == statusGeneration,
                          self.canPresentNotUploadedCount else { return }
                    // This count cannot be used as a PhotoKit display index.
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
            let hadItems = await MainActor.run { (self.cachedNotUploadedCount ?? 0) > 0 }
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
                      self.canBuildNotUploadedFilter,
                      let result = manager.fetchResult else { return }

                let previousCount = self.cachedNotUploadedCount ?? 0
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
                self.cachedNotUploadedCount = self.canPresentNotUploadedCount ? sqlCount : nil
                // Retain a valid indexed result even when another filter is
                // active; returning to Not Uploaded should be instantaneous.
                self.cachedNotUploadedIndices = notUploadedIndices
                self.cachedNotUploadedFetchResult = result
                self.fetchStorage.cachedNotUploadedIndexGeneration = manager.assetIndexGeneration
                self.fetchStorage.cachedNotUploadedStatusGeneration = appliedStatusGeneration
                self.cachedNotUploadedGeneration = manager.assetFetchGeneration

                if self.currentFilter == .notUploaded {
                    let indicesChanged = self.filteredIndices != notUploadedIndices
                    // Reloading every visible cell is only needed when positions
                    // or the fetch they index into actually changed.
                    let needsRebind = indicesChanged || self.filteredFetchResult !== result
                    if self.showingPhotoDetail && indicesChanged {
                        self.showingPhotoDetail = false
                    }
                    if indicesChanged {
                        self.filteredIndices = notUploadedIndices
                    }
                    self.filteredFetchResult = result
                    self.fetchStorage.filteredIndexGeneration = manager.assetIndexGeneration
                    self.filteredIndicesGeneration = manager.assetFetchGeneration
                    self.isFilterLoading = false
                    if needsRebind {
                        self.refreshToken = UUID()
                    }
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
        isScrolledPastFirstRow = false
        
        refreshToken = UUID()
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
    
    /// Display indices come from the collection view's own hit testing.
    private func handleDragBegan(at idx: Int) {
        guard canSelectDisplayedPhotos, idx < displayCount else { return }
        let actualIdx = resolveActualIndex(idx)
        
        dragState.baseSelection = selectedAssets
        dragState.anchorIndex = idx
        dragState.currentIndex = idx
        
        if let id = assetForDisplay(at: actualIdx)?.localIdentifier {
            dragState.isDeselecting = selectedAssets.contains(id)
        }
        
        applyDragRange(from: idx, to: idx)
    }
    
    private func handleDragChanged(at idx: Int) {
        guard canSelectDisplayedPhotos, let anchor = dragState.anchorIndex, idx < displayCount else { return }
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
        // The in-memory identifier snapshot avoids PhotoKit object faulting,
        // but is only position-compatible with the fetch it was built from.
        let manager = photoLibraryManager
        let identifiers: [String]? =
            fetchResult === manager.fetchResult &&
            manager.orderedIdentifiersGeneration == manager.assetFetchGeneration &&
            manager.orderedLocalIdentifiers.count == fetchResult.count
            ? manager.orderedLocalIdentifiers : nil

        isSelectingAll = true
        selectionTask?.cancel()
        // Task { } would inherit MainActor; enumerating a large library blocks the UI.
        selectionTask = Task.detached(priority: .userInitiated) { [self] in
            var ids = Set<String>()
            func include(_ id: String) {
                if (statusCache[id] ?? .pending) != .uploaded {
                    ids.insert(id)
                }
            }
            if let visibleIndices {
                ids.reserveCapacity(visibleIndices.count)
                for index in visibleIndices {
                    if Task.isCancelled { return }
                    guard index >= 0, index < fetchResult.count else { continue }
                    include(identifiers?[index] ?? fetchResult.object(at: index).localIdentifier)
                }
            } else if let identifiers {
                ids.reserveCapacity(identifiers.count / 4)
                for id in identifiers {
                    if Task.isCancelled { return }
                    include(id)
                }
            } else {
                ids.reserveCapacity(fetchResult.count / 4)
                fetchResult.enumerateObjects { asset, _, stop in
                    if Task.isCancelled {
                        stop.pointee = true
                        return
                    }
                    include(asset.localIdentifier)
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

private enum GridCellEvent {
    case tap, longPress, appear, disappear
}

private struct PhotoGridItemView: View {
    let photoLibraryManager: PhotoLibraryManager
    /// Read in body rather than subscribed per cell, so a status flush costs
    /// no Combine delivery per cell.
    let statusCache: [String: PhotoSyncStatus]
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
    let onEvent: (GridCellEvent) -> Void
    
    @State private var asset: PHAsset?
    @State private var isCellActive = false
    @State private var appliedEditGeneration: Int?
    @State private var observedAssetIdentifier: String?
    @State private var observedContentRevision: PhotoAssetContentRevision?
    
    var body: some View {
        Group {
            if let asset = asset {
                let isThisAssetSelected = showingPhotoDetail && selectedPhotoIndex == displayIndex
                
                PhotoThumbnailView(
                    asset: asset,
                    isSelected: selectedAssets.contains(asset.localIdentifier),
                    isSelectionMode: isSelectionMode,
                    syncStatus: statusCache[asset.localIdentifier] ?? .pending,
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
            onEvent(.tap)
        }
        .onLongPressGesture {
            onEvent(.longPress)
        }
        .onAppear {
            isCellActive = true
            loadAsset()
            onEvent(.appear)
        }
        .onDisappear {
            isCellActive = false
            // Prefetched or recycled cells must not keep PhotoKit objects.
            asset = nil
            appliedEditGeneration = nil
            observedAssetIdentifier = nil
            observedContentRevision = nil
            onEvent(.disappear)
        }
        .onChange(of: assetIndex) { _, _ in
            // Rebind only visible rows. Offscreen rows have released their assets.
            if isCellActive { loadAsset() }
        }
        .onChange(of: refreshToken) { _, _ in
            // Update visible cells after a PhotoKit fetch replacement without
            // rematerializing assets for cells that are not on screen.
            if isCellActive { loadAsset() }
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
