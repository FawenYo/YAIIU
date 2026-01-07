import SwiftUI
import Photos
import os.lock

final class RAWFormatChecker {
    static let shared = RAWFormatChecker()
    
    private static let rawIdentifiers: Set<String> = [
        "raw-image", "dng", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2"
    ]
    
    private var cache: [String: Bool] = [:]
    private var cacheLock = os_unfair_lock()
    
    private init() {}
    
    static func isRAWResource(_ resource: PHAssetResource) -> Bool {
        if resource.type == .alternatePhoto {
            return true
        }
        
        let uti = resource.uniformTypeIdentifier.lowercased()
        return rawIdentifiers.contains { uti.contains($0) }
    }
    
    func hasRAWResource(for assetIdentifier: String, resources: [PHAssetResource]) -> Bool {
        os_unfair_lock_lock(&cacheLock)
        if let cached = cache[assetIdentifier] {
            os_unfair_lock_unlock(&cacheLock)
            return cached
        }
        os_unfair_lock_unlock(&cacheLock)
        
        let hasRAW = resources.contains { Self.isRAWResource($0) }
        
        os_unfair_lock_lock(&cacheLock)
        cache[assetIdentifier] = hasRAW
        os_unfair_lock_unlock(&cacheLock)
        
        return hasRAW
    }
    
    func getCachedRAWStatus(for assetIdentifier: String) -> Bool? {
        os_unfair_lock_lock(&cacheLock)
        defer { os_unfair_lock_unlock(&cacheLock) }
        return cache[assetIdentifier]
    }
    
    func clearCache() {
        os_unfair_lock_lock(&cacheLock)
        cache.removeAll()
        os_unfair_lock_unlock(&cacheLock)
    }
}

struct PhotoThumbnailView: View {
    let asset: PHAsset
    let isSelected: Bool
    let isSelectionMode: Bool
    let syncStatus: PhotoSyncStatus
    let namespace: Namespace.ID?
    /// When true, this view is the source of the matched geometry effect.
    /// Set to false when the detail view is showing to avoid duplicate sources.
    let isGeometrySource: Bool
    
    @State private var thumbnail: UIImage?
    @State private var hasRAW: Bool = false
    @State private var videoDuration: TimeInterval = 0
    @State private var isVideo: Bool = false
    @State private var loadTask: Task<Void, Never>?
    @State private var isViewActive: Bool = false
    
    init(asset: PHAsset, isSelected: Bool, isSelectionMode: Bool, isUploaded: Bool) {
        self.asset = asset
        self.isSelected = isSelected
        self.isSelectionMode = isSelectionMode
        self.syncStatus = isUploaded ? .uploaded : .pending
        self.namespace = nil
        self.isGeometrySource = true
    }
    
    init(asset: PHAsset, isSelected: Bool, isSelectionMode: Bool, syncStatus: PhotoSyncStatus) {
        self.asset = asset
        self.isSelected = isSelected
        self.isSelectionMode = isSelectionMode
        self.syncStatus = syncStatus
        self.namespace = nil
        self.isGeometrySource = true
    }
    
    init(asset: PHAsset, isSelected: Bool, isSelectionMode: Bool, syncStatus: PhotoSyncStatus, namespace: Namespace.ID?, isGeometrySource: Bool = true) {
        self.asset = asset
        self.isSelected = isSelected
        self.isSelectionMode = isSelectionMode
        self.syncStatus = syncStatus
        self.namespace = namespace
        self.isGeometrySource = isGeometrySource
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                // Thumbnail Image
                thumbnailImage(geometry: geometry)
                
                // Video Duration Badge
                if isVideo {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "play.fill")
                                .font(.caption2)
                            Text(formatDuration(videoDuration))
                                .font(.caption2)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(4)
                        .padding(4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                // RAW Badge
                if hasRAW {
                    VStack {
                        HStack {
                            Text("RAW")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.orange)
                                .cornerRadius(3)
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(4)
                }
                
                // Sync Status Badge
                syncStatusBadge
                
                // Selection Indicator
                if isSelectionMode {
                    ZStack {
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                            .frame(width: 24, height: 24)
                            .background(
                                Circle()
                                    .fill(isSelected ? Color.blue : Color.black.opacity(0.3))
                            )
                        
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(6)
                }
                
                // Selection Overlay
                if isSelected {
                    Rectangle()
                        .fill(Color.blue.opacity(0.3))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            // Constrain tap area to visible bounds (aspectRatio .fill may overflow)
            .contentShape(Rectangle())
        }
        .onAppear {
            isViewActive = true
            loadAssetInfo()
        }
        .onDisappear {
            isViewActive = false
            loadTask?.cancel()
            loadTask = nil
            ThumbnailCache.shared.cancelThumbnail(for: asset.localIdentifier)
        }
    }
    
    @ViewBuilder
    private var syncStatusBadge: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 22, height: 22)
                    
                    switch syncStatus {
                    case .pending:
                        Image(systemName: "cloud")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    
                    case .processing, .checking:
                        ZStack {
                            Image(systemName: "cloud")
                                .font(.system(size: 12))
                                .foregroundColor(.blue)
                            
                            ProgressView()
                                .scaleEffect(0.5)
                                .offset(y: 1)
                        }
                    
                    case .notUploaded:
                        Image(systemName: "icloud.and.arrow.up")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    
                    case .uploaded:
                        Image(systemName: "checkmark.icloud.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.green)
                    
                    case .error:
                        Image(systemName: "exclamationmark.icloud")
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }
                }
                .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
            }
        }
        .padding(4)
    }
    
    /// Returns the thumbnail image view with optional matched geometry effect
    @ViewBuilder
    private func thumbnailImage(geometry: GeometryProxy) -> some View {
        if let thumbnail = thumbnail {
            let imageView = Image(uiImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: geometry.size.width, height: geometry.size.height)
            
            // Apply matched geometry effect if namespace is provided
            // Use isSource parameter to control which view is the source of the geometry
            if let namespace = namespace {
                imageView
                    .matchedGeometryEffect(id: asset.localIdentifier, in: namespace, isSource: isGeometrySource)
            } else {
                imageView
            }
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: geometry.size.width, height: geometry.size.height)
                .overlay(
                    ProgressView()
                )
        }
    }
    
    private func loadAssetInfo() {
        isVideo = asset.mediaType == .video
        videoDuration = asset.duration
        
        loadTask?.cancel()
        
        // Check RAW cache first to avoid expensive PHAssetResource lookup
        if let cachedRAW = RAWFormatChecker.shared.getCachedRAWStatus(for: asset.localIdentifier) {
            hasRAW = cachedRAW
        }
        
        loadTask = Task { @MainActor in
            ThumbnailCache.shared.getThumbnail(for: asset) { [self] image in
                guard self.isViewActive else { return }
                if let image = image {
                    self.thumbnail = image
                }
            }
            
            // Only check RAW if not already cached
            if RAWFormatChecker.shared.getCachedRAWStatus(for: asset.localIdentifier) == nil {
                let assetId = asset.localIdentifier
                let assetRef = asset
                
                let hasRAWResource = await Task.detached(priority: .utility) {
                    let resources = PHAssetResource.assetResources(for: assetRef)
                    return RAWFormatChecker.shared.hasRAWResource(for: assetId, resources: resources)
                }.value
                
                guard !Task.isCancelled else { return }
                self.hasRAW = hasRAWResource
            }
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    PhotoThumbnailView(
        asset: PHAsset(),
        isSelected: false,
        isSelectionMode: false,
        isUploaded: false
    )
    .frame(width: 120, height: 120)
}
