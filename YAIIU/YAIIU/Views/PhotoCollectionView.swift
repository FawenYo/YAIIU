import SwiftUI
import Photos
import UIKit
import Combine

// MARK: - Photo Collection View (UICollectionView wrapper)

/// A UICollectionView-based photo grid that provides true lazy loading and efficient scrolling
struct PhotoCollectionView: UIViewRepresentable {
    let photoLibraryManager: PhotoLibraryManager
    let hashManager: HashManager
    let displayIndices: [Int]?
    let isSelectionMode: Bool
    @Binding var selectedAssets: Set<String>
    let onItemTap: (Int) -> Void
    let onItemLongPress: (Int) -> Void
    let onVisibleDateChanged: (String) -> Void
    let onFirstItemVisibilityChanged: (Bool) -> Void
    let scrollToIndex: Binding<Int?>
    let onRefresh: (() -> Void)?
    @Binding var isRefreshing: Bool
    
    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .systemBackground
        collectionView.delegate = context.coordinator
        collectionView.dataSource = context.coordinator
        collectionView.prefetchDataSource = context.coordinator
        collectionView.register(PhotoCollectionCell.self, forCellWithReuseIdentifier: PhotoCollectionCell.reuseIdentifier)
        
        // Configure for performance
        collectionView.isPrefetchingEnabled = true
        collectionView.contentInsetAdjustmentBehavior = .automatic
        
        // Hide native scroll indicators (we use custom timeline scrubber)
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        
        // Configure pull-to-refresh
        if onRefresh != nil {
            let refreshControl = UIRefreshControl()
            refreshControl.addTarget(
                context.coordinator,
                action: #selector(Coordinator.handleRefresh(_:)),
                for: .valueChanged
            )
            collectionView.refreshControl = refreshControl
        }
        
        // Store reference for coordinator
        context.coordinator.collectionView = collectionView
        
        // Subscribe to HashManager changes to reload visible cells when sync status updates
        context.coordinator.subscribeToHashManagerChanges(hashManager)
        
        return collectionView
    }
    
    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        
        // Track if selection changed
        let selectionChanged = coordinator.selectedAssets != selectedAssets
        let selectionModeChanged = coordinator.isSelectionMode != isSelectionMode
        
        // Update data source
        coordinator.photoLibraryManager = photoLibraryManager
        coordinator.hashManager = hashManager
        coordinator.displayIndices = displayIndices
        coordinator.isSelectionMode = isSelectionMode
        coordinator.selectedAssets = selectedAssets
        coordinator.onItemTap = onItemTap
        coordinator.onItemLongPress = onItemLongPress
        coordinator.onVisibleDateChanged = onVisibleDateChanged
        coordinator.onFirstItemVisibilityChanged = onFirstItemVisibilityChanged
        coordinator.onRefresh = onRefresh
        
        // Sync refresh control state with binding
        if let refreshControl = collectionView.refreshControl {
            if isRefreshing && !refreshControl.isRefreshing {
                refreshControl.beginRefreshing()
            } else if !isRefreshing && refreshControl.isRefreshing {
                refreshControl.endRefreshing()
            }
        }
        
        // Update layout for current size (only if changed)
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            let width = collectionView.bounds.width
            if width > 0 && coordinator.lastKnownWidth != width {
                coordinator.lastKnownWidth = width
                let itemsPerRow: CGFloat = 3
                let spacing: CGFloat = 2
                let totalSpacing = spacing * (itemsPerRow - 1)
                let itemWidth = floor((width - totalSpacing) / itemsPerRow)
                layout.itemSize = CGSize(width: itemWidth, height: itemWidth)
            }
        }
        
        // Handle scroll to index
        if let targetIndex = scrollToIndex.wrappedValue {
            let itemCount = displayIndices?.count ?? photoLibraryManager.assetCount
            if targetIndex >= 0 && targetIndex < itemCount {
                let indexPath = IndexPath(item: targetIndex, section: 0)
                collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
            }
            DispatchQueue.main.async {
                scrollToIndex.wrappedValue = nil
            }
        }
        
        // Reload data if count changed
        let newCount = displayIndices?.count ?? photoLibraryManager.assetCount
        if coordinator.lastKnownCount != newCount {
            coordinator.lastKnownCount = newCount
            collectionView.reloadData()
        } else if selectionChanged || selectionModeChanged {
            // Only reload visible cells if selection state changed
            let visibleIndexPaths = collectionView.indexPathsForVisibleItems
            if !visibleIndexPaths.isEmpty {
                // Use performBatchUpdates for better performance
                collectionView.performBatchUpdates {
                    collectionView.reloadItems(at: visibleIndexPaths)
                }
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    // MARK: - Coordinator
    
    class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDataSourcePrefetching, UICollectionViewDelegateFlowLayout {
        weak var collectionView: UICollectionView?
        var photoLibraryManager: PhotoLibraryManager
        var hashManager: HashManager
        var displayIndices: [Int]?
        var isSelectionMode: Bool
        var selectedAssets: Set<String>
        var onItemTap: (Int) -> Void
        var onItemLongPress: (Int) -> Void
        var onVisibleDateChanged: (String) -> Void
        var onFirstItemVisibilityChanged: (Bool) -> Void
        var onRefresh: (() -> Void)?
        var lastKnownCount: Int = 0
        var lastKnownWidth: CGFloat = 0
        
        // Combine subscription for HashManager changes
        private var hashManagerCancellable: AnyCancellable?
        private var lastSyncStatusCacheCount: Int = 0
        
        // Throttling for date updates
        private var lastDateUpdateTime: CFTimeInterval = 0
        private let dateUpdateInterval: CFTimeInterval = 1.0 / 15.0
        private var lastReportedDateText: String = ""
        private var lastReportedFirstVisible: Bool = true
        
        // Cache Calendar instance for better performance
        private let calendar = Calendar.current
        
        private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("yyyyMMMMd")
            return formatter
        }()
        
        private let monthDayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("MMMMd")
            return formatter
        }()
        
        init(_ parent: PhotoCollectionView) {
            self.photoLibraryManager = parent.photoLibraryManager
            self.hashManager = parent.hashManager
            self.displayIndices = parent.displayIndices
            self.isSelectionMode = parent.isSelectionMode
            self.selectedAssets = parent.selectedAssets
            self.onItemTap = parent.onItemTap
            self.onItemLongPress = parent.onItemLongPress
            self.onVisibleDateChanged = parent.onVisibleDateChanged
            self.onFirstItemVisibilityChanged = parent.onFirstItemVisibilityChanged
            self.onRefresh = parent.onRefresh
        }
        
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            onRefresh?()
        }
        
        /// Subscribe to HashManager's syncStatusCache changes to reload visible cells
        func subscribeToHashManagerChanges(_ hashManager: HashManager) {
            // Cancel existing subscription
            hashManagerCancellable?.cancel()
            
            // Subscribe to objectWillChange to detect syncStatusCache updates
            hashManagerCancellable = hashManager.objectWillChange
                .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.reloadVisibleCellsForSyncStatus()
                }
        }
        
        /// Reload only visible cells to update sync status badges
        private func reloadVisibleCellsForSyncStatus() {
            guard let collectionView = collectionView else { return }
            
            let visibleIndexPaths = collectionView.indexPathsForVisibleItems
            guard !visibleIndexPaths.isEmpty else { return }
            
            // Use performBatchUpdates for smooth animation
            collectionView.performBatchUpdates {
                collectionView.reloadItems(at: visibleIndexPaths)
            }
        }
        
        private func resolveActualIndex(_ displayIndex: Int) -> Int {
            if let indices = displayIndices {
                return displayIndex < indices.count ? indices[displayIndex] : displayIndex
            }
            return displayIndex
        }
        
        private var itemCount: Int {
            displayIndices?.count ?? photoLibraryManager.assetCount
        }
        
        // MARK: - UICollectionViewDataSource
        
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            return itemCount
        }
        
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotoCollectionCell.reuseIdentifier, for: indexPath) as! PhotoCollectionCell
            
            let displayIndex = indexPath.item
            let actualIndex = resolveActualIndex(displayIndex)
            
            if let asset = photoLibraryManager.asset(at: actualIndex) {
                let isSelected = selectedAssets.contains(asset.localIdentifier)
                let syncStatus = hashManager.getSyncStatus(for: asset.localIdentifier)
                cell.configure(
                    with: asset,
                    isSelected: isSelected,
                    isSelectionMode: isSelectionMode,
                    syncStatus: syncStatus
                )
            }
            
            return cell
        }
        
        // MARK: - UICollectionViewDelegate
        
        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            onItemTap(indexPath.item)
        }
        
        func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
            // Trigger long press callback
            onItemLongPress(indexPath.item)
            return nil
        }
        
        // MARK: - UICollectionViewDataSourcePrefetching
        
        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let assets = indexPaths.compactMap { indexPath -> PHAsset? in
                let actualIndex = resolveActualIndex(indexPath.item)
                return photoLibraryManager.asset(at: actualIndex)
            }
            ThumbnailCache.shared.prefetchThumbnails(for: assets)
        }
        
        func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            let assets = indexPaths.compactMap { indexPath -> PHAsset? in
                let actualIndex = resolveActualIndex(indexPath.item)
                return photoLibraryManager.asset(at: actualIndex)
            }
            ThumbnailCache.shared.stopPrefetching(for: assets)
        }
        
        // MARK: - UIScrollViewDelegate
        
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // Throttle date updates
            let now = CACurrentMediaTime()
            if now - lastDateUpdateTime >= dateUpdateInterval {
                lastDateUpdateTime = now
                updateVisibleDateTitle()
            }
        }
        
        private func updateVisibleDateTitle() {
            guard let collectionView = collectionView else { return }
            
            // Get sorted visible index paths (only compute once)
            let visibleIndexPaths = collectionView.indexPathsForVisibleItems
            guard !visibleIndexPaths.isEmpty else { return }
            
            // Find minimum index efficiently
            var minIndex = Int.max
            for indexPath in visibleIndexPaths {
                if indexPath.item < minIndex {
                    minIndex = indexPath.item
                }
            }
            
            // Check if first item is visible
            let isFirstVisible = minIndex == 0
            if isFirstVisible != lastReportedFirstVisible {
                lastReportedFirstVisible = isFirstVisible
                onFirstItemVisibilityChanged(isFirstVisible)
            }
            
            // Get date from topmost visible item
            let actualIndex = resolveActualIndex(minIndex)
            guard let date = photoLibraryManager.creationDate(at: actualIndex) else { return }
            
            let now = Date()
            
            let dateText: String
            if calendar.isDateInToday(date) {
                dateText = L10n.PhotoGrid.sectionToday
            } else if calendar.isDateInYesterday(date) {
                dateText = L10n.PhotoGrid.sectionYesterday
            } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
                dateText = monthDayFormatter.string(from: date)
            } else {
                dateText = dateFormatter.string(from: date)
            }
            
            // Only call callback if text changed
            if dateText != lastReportedDateText {
                lastReportedDateText = dateText
                onVisibleDateChanged(dateText)
            }
        }
    }
}

// MARK: - Photo Collection Cell

final class PhotoCollectionCell: UICollectionViewCell {
    static let reuseIdentifier = "PhotoCollectionCell"
    
    private let imageView = UIImageView()
    private let selectionIndicator = UIView()
    private let selectionCheckmark = UIImageView()
    private let syncStatusBadge = UIView()
    private let syncStatusIcon = UIImageView()
    private let rawBadge = UILabel()
    private let videoDurationBadge = UIView()
    private let videoDurationLabel = UILabel()
    private let videoIcon = UIImageView()
    private var currentAssetIdentifier: String?
    private var loadTask: Task<Void, Never>?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        if let identifier = currentAssetIdentifier {
            ThumbnailCache.shared.cancelThumbnail(for: identifier)
        }
        currentAssetIdentifier = nil
        imageView.image = nil
        selectionIndicator.isHidden = true
        rawBadge.isHidden = true
        videoDurationBadge.isHidden = true
        syncStatusBadge.isHidden = true
    }
    
    private func setupViews() {
        // Image view
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .systemGray5
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        
        // Selection indicator
        selectionIndicator.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.3)
        selectionIndicator.isHidden = true
        selectionIndicator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(selectionIndicator)
        
        // Selection checkmark circle
        let checkmarkCircle = UIView()
        checkmarkCircle.backgroundColor = .clear
        checkmarkCircle.layer.cornerRadius = 12
        checkmarkCircle.layer.borderWidth = 2
        checkmarkCircle.layer.borderColor = UIColor.white.cgColor
        checkmarkCircle.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(checkmarkCircle)
        
        selectionCheckmark.image = UIImage(systemName: "checkmark")
        selectionCheckmark.tintColor = .white
        selectionCheckmark.contentMode = .scaleAspectFit
        selectionCheckmark.isHidden = true
        selectionCheckmark.translatesAutoresizingMaskIntoConstraints = false
        checkmarkCircle.addSubview(selectionCheckmark)
        
        // Sync status badge
        syncStatusBadge.backgroundColor = .white
        syncStatusBadge.layer.cornerRadius = 11
        syncStatusBadge.layer.shadowColor = UIColor.black.cgColor
        syncStatusBadge.layer.shadowOpacity = 0.2
        syncStatusBadge.layer.shadowOffset = CGSize(width: 0, height: 1)
        syncStatusBadge.layer.shadowRadius = 1
        syncStatusBadge.isHidden = true
        syncStatusBadge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(syncStatusBadge)
        
        syncStatusIcon.contentMode = .scaleAspectFit
        syncStatusIcon.translatesAutoresizingMaskIntoConstraints = false
        syncStatusBadge.addSubview(syncStatusIcon)
        
        // RAW badge
        rawBadge.text = "RAW"
        rawBadge.font = .systemFont(ofSize: 9, weight: .bold)
        rawBadge.textColor = .white
        rawBadge.backgroundColor = .orange
        rawBadge.textAlignment = .center
        rawBadge.layer.cornerRadius = 3
        rawBadge.clipsToBounds = true
        rawBadge.isHidden = true
        rawBadge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rawBadge)
        
        // Video duration badge
        videoDurationBadge.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        videoDurationBadge.layer.cornerRadius = 4
        videoDurationBadge.isHidden = true
        videoDurationBadge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(videoDurationBadge)
        
        videoIcon.image = UIImage(systemName: "play.fill")
        videoIcon.tintColor = .white
        videoIcon.contentMode = .scaleAspectFit
        videoIcon.translatesAutoresizingMaskIntoConstraints = false
        videoDurationBadge.addSubview(videoIcon)
        
        videoDurationLabel.textColor = .white
        videoDurationLabel.font = .systemFont(ofSize: 11)
        videoDurationLabel.translatesAutoresizingMaskIntoConstraints = false
        videoDurationBadge.addSubview(videoDurationLabel)
        
        // Constraints
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            
            selectionIndicator.topAnchor.constraint(equalTo: contentView.topAnchor),
            selectionIndicator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            selectionIndicator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            selectionIndicator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            
            checkmarkCircle.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            checkmarkCircle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            checkmarkCircle.widthAnchor.constraint(equalToConstant: 24),
            checkmarkCircle.heightAnchor.constraint(equalToConstant: 24),
            
            selectionCheckmark.centerXAnchor.constraint(equalTo: checkmarkCircle.centerXAnchor),
            selectionCheckmark.centerYAnchor.constraint(equalTo: checkmarkCircle.centerYAnchor),
            selectionCheckmark.widthAnchor.constraint(equalToConstant: 12),
            selectionCheckmark.heightAnchor.constraint(equalToConstant: 12),
            
            syncStatusBadge.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            syncStatusBadge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            syncStatusBadge.widthAnchor.constraint(equalToConstant: 22),
            syncStatusBadge.heightAnchor.constraint(equalToConstant: 22),
            
            syncStatusIcon.centerXAnchor.constraint(equalTo: syncStatusBadge.centerXAnchor),
            syncStatusIcon.centerYAnchor.constraint(equalTo: syncStatusBadge.centerYAnchor),
            syncStatusIcon.widthAnchor.constraint(equalToConstant: 14),
            syncStatusIcon.heightAnchor.constraint(equalToConstant: 14),
            
            rawBadge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rawBadge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            rawBadge.widthAnchor.constraint(equalToConstant: 30),
            rawBadge.heightAnchor.constraint(equalToConstant: 16),
            
            videoDurationBadge.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            videoDurationBadge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            videoDurationBadge.heightAnchor.constraint(equalToConstant: 20),
            
            videoIcon.leadingAnchor.constraint(equalTo: videoDurationBadge.leadingAnchor, constant: 6),
            videoIcon.centerYAnchor.constraint(equalTo: videoDurationBadge.centerYAnchor),
            videoIcon.widthAnchor.constraint(equalToConstant: 10),
            videoIcon.heightAnchor.constraint(equalToConstant: 10),
            
            videoDurationLabel.leadingAnchor.constraint(equalTo: videoIcon.trailingAnchor, constant: 4),
            videoDurationLabel.trailingAnchor.constraint(equalTo: videoDurationBadge.trailingAnchor, constant: -6),
            videoDurationLabel.centerYAnchor.constraint(equalTo: videoDurationBadge.centerYAnchor),
        ])
        
        // Store checkmark circle reference
        self.checkmarkCircle = checkmarkCircle
    }
    
    private var checkmarkCircle: UIView!
    
    func configure(with asset: PHAsset, isSelected: Bool, isSelectionMode: Bool, syncStatus: PhotoSyncStatus) {
        currentAssetIdentifier = asset.localIdentifier
        
        // Show/hide selection UI
        checkmarkCircle.isHidden = !isSelectionMode
        selectionIndicator.isHidden = !isSelected
        selectionCheckmark.isHidden = !isSelected
        checkmarkCircle.backgroundColor = isSelected ? .systemBlue : UIColor.black.withAlphaComponent(0.3)
        
        // Configure sync status
        configureSyncStatus(syncStatus)
        
        // Configure video badge
        if asset.mediaType == .video {
            videoDurationBadge.isHidden = false
            videoDurationLabel.text = formatDuration(asset.duration)
        } else {
            videoDurationBadge.isHidden = true
        }
        
        // Load thumbnail
        loadTask = Task { @MainActor in
            ThumbnailCache.shared.getThumbnail(for: asset) { [weak self] image in
                guard let self = self, self.currentAssetIdentifier == asset.localIdentifier else { return }
                self.imageView.image = image
            }
        }
        
        // Check RAW status
        if let cachedRAW = RAWFormatChecker.shared.getCachedRAWStatus(for: asset.localIdentifier) {
            rawBadge.isHidden = !cachedRAW
        } else {
            rawBadge.isHidden = true
            Task.detached(priority: .utility) { [weak self] in
                let resources = PHAssetResource.assetResources(for: asset)
                let hasRAW = RAWFormatChecker.shared.hasRAWResource(for: asset.localIdentifier, resources: resources)
                await MainActor.run {
                    guard let self = self, self.currentAssetIdentifier == asset.localIdentifier else { return }
                    self.rawBadge.isHidden = !hasRAW
                }
            }
        }
    }
    
    private func configureSyncStatus(_ status: PhotoSyncStatus) {
        syncStatusBadge.isHidden = false
        
        switch status {
        case .pending:
            syncStatusIcon.image = UIImage(systemName: "cloud")
            syncStatusIcon.tintColor = .gray
        case .processing, .checking:
            syncStatusIcon.image = UIImage(systemName: "cloud")
            syncStatusIcon.tintColor = .systemBlue
        case .notUploaded:
            syncStatusIcon.image = UIImage(systemName: "icloud.and.arrow.up")
            syncStatusIcon.tintColor = .orange
        case .uploaded:
            syncStatusIcon.image = UIImage(systemName: "checkmark.icloud.fill")
            syncStatusIcon.tintColor = .systemGreen
        case .error:
            syncStatusIcon.image = UIImage(systemName: "exclamationmark.icloud")
            syncStatusIcon.tintColor = .red
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
