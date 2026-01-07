import SwiftUI
import Photos
import CoreLocation
import AVKit
import UIKit

// MARK: - ZoomableScrollView
final class ZoomableScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    
    var onScaleChanged: ((CGFloat) -> Void)?
    var onDoubleTap: (() -> Void)?
    var onSingleTap: (() -> Void)?
    
    // Track image size to detect actual image changes and preserve zoom state
    private var currentImageSize: CGSize = .zero
    private var isInitialSetupDone = false
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupScrollView()
        setupImageView()
        setupGestures()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupScrollView() {
        delegate = self
        minimumZoomScale = 1.0
        maximumZoomScale = 4.0
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bounces = true
        bouncesZoom = true
        contentInsetAdjustmentBehavior = .never
        // Match Apple Photos app behavior
        decelerationRate = .normal
        isScrollEnabled = true
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }
    
    private func setupImageView() {
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.backgroundColor = .clear
        addSubview(imageView)
    }
    
    private func setupGestures() {
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)
        
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        // Wait for double tap to fail before triggering single tap
        singleTap.require(toFail: doubleTap)
        imageView.addGestureRecognizer(singleTap)
    }
    
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.0 {
            setZoomScale(1.0, animated: true)
        } else {
            let location = gesture.location(in: imageView)
            let zoomRect = calculateZoomRect(scale: 2.0, center: location)
            zoom(to: zoomRect, animated: true)
        }
        onDoubleTap?()
    }
    
    @objc private func handleSingleTap() {
        onSingleTap?()
    }
    
    private func calculateZoomRect(scale: CGFloat, center: CGPoint) -> CGRect {
        let size = CGSize(
            width: bounds.width / scale,
            height: bounds.height / scale
        )
        let origin = CGPoint(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2
        )
        return CGRect(origin: origin, size: size)
    }
    
    // MARK: - UIScrollViewDelegate
    
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageView
    }
    
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageView()
        onScaleChanged?(scrollView.zoomScale)
    }
    
    private func centerImageView() {
        let boundsSize = bounds.size
        var frameToCenter = imageView.frame
        
        if frameToCenter.size.width < boundsSize.width {
            frameToCenter.origin.x = (boundsSize.width - frameToCenter.size.width) / 2
        } else {
            frameToCenter.origin.x = 0
        }
        
        if frameToCenter.size.height < boundsSize.height {
            frameToCenter.origin.y = (boundsSize.height - frameToCenter.size.height) / 2
        } else {
            frameToCenter.origin.y = 0
        }
        
        imageView.frame = frameToCenter
    }
    
    // MARK: - Public Methods
    
    func setImage(_ image: UIImage?) {
        guard let image = image else {
            imageView.image = nil
            currentImageSize = .zero
            isInitialSetupDone = false
            return
        }
        
        // Skip reconfiguration if same image to preserve zoom state during SwiftUI updates
        if currentImageSize == image.size && isInitialSetupDone {
            return
        }
        
        currentImageSize = image.size
        imageView.image = image
        zoomScale = 1.0
        isInitialSetupDone = false
        
        if bounds.width > 0 && bounds.height > 0 {
            configureImageSize(for: image)
            isInitialSetupDone = true
        }
    }
    
    private func configureImageSize(for image: UIImage) {
        let imageSize = image.size
        let boundsSize = bounds.size
        
        guard boundsSize.width > 0 && boundsSize.height > 0 else { return }
        guard imageSize.width > 0 && imageSize.height > 0 else { return }
        
        let widthRatio = boundsSize.width / imageSize.width
        let heightRatio = boundsSize.height / imageSize.height
        let fitScale = min(widthRatio, heightRatio)
        
        let scaledWidth = imageSize.width * fitScale
        let scaledHeight = imageSize.height * fitScale
        
        let frame = CGRect(
            x: (boundsSize.width - scaledWidth) / 2,
            y: (boundsSize.height - scaledHeight) / 2,
            width: scaledWidth,
            height: scaledHeight
        )
        
        imageView.frame = frame
        contentSize = frame.size
    }
    
    func resetZoom(animated: Bool = true) {
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseInOut) {
                self.zoomScale = 1.0
                self.centerImageView()
            }
        } else {
            zoomScale = 1.0
            centerImageView()
        }
    }
    
    func getCurrentScale() -> CGFloat {
        return zoomScale
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        // Only configure on first valid layout to preserve zoom state
        guard !isInitialSetupDone, currentImageSize != .zero else { return }
        
        if bounds.width > 0 && bounds.height > 0, let image = imageView.image {
            configureImageSize(for: image)
            isInitialSetupDone = true
        }
    }
}

// MARK: - ZoomableImageView
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage?
    @Binding var scale: CGFloat
    var onDoubleTap: (() -> Void)?
    var onSingleTap: (() -> Void)?
    
    func makeUIView(context: Context) -> ZoomableScrollView {
        let scrollView = ZoomableScrollView()
        scrollView.onScaleChanged = { newScale in
            DispatchQueue.main.async {
                scale = newScale
            }
        }
        scrollView.onDoubleTap = onDoubleTap
        scrollView.onSingleTap = onSingleTap
        return scrollView
    }
    
    func updateUIView(_ uiView: ZoomableScrollView, context: Context) {
        uiView.setImage(image)
    }
}

// MARK: - PhotoDetailView
struct PhotoDetailView: View {
    let assets: [PHAsset]
    let initialIndex: Int
    let namespace: Namespace.ID
    @Binding var isPresented: Bool
    
    @State private var currentIndex: Int
    @State private var fullImage: UIImage?
    @State private var offset: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    @State private var isDragging: Bool = false
    @State private var dragProgress: CGFloat = 0
    @State private var imageLoadTask: Task<Void, Never>?
    
    @State private var player: AVPlayer?
    @State private var isVideoLoading: Bool = false
    @State private var isVideoPlaying: Bool = false
    @State private var playerEndObserver: NSObjectProtocol?
    
    @State private var showInfoPanel: Bool = false
    @State private var infoPanelDragOffset: CGFloat = 0
    @State private var photoVerticalOffset: CGFloat = 0
    
    @State private var location: CLLocation?
    @State private var locationName: String?
    @State private var cameraInfo: String?
    @State private var lensInfo: String?
    @State private var exposureInfo: String?
    @State private var fileName: String?
    @State private var fileSize: Int64?
    
    // Horizontal swipe navigation states
    @State private var horizontalOffset: CGFloat = 0
    @State private var isHorizontalDragging: Bool = false
    
    // Track whether user has navigated away from initial photo
    @State private var hasNavigated: Bool = false
    
    private let dismissThreshold: CGFloat = 150
    private let swipeUpThreshold: CGFloat = 60
    private let horizontalSwipeThreshold: CGFloat = 80
    
    /// Calculates info panel height based on screen size for better iPad support.
    /// Uses 60% of screen height on iPad, capped between 450-700 points.
    private func infoPanelHeight(for geometry: GeometryProxy) -> CGFloat {
        let screenHeight = geometry.size.height
        let isCompactHeight = screenHeight < 700
        
        if isCompactHeight {
            return min(screenHeight * 0.7, 450)
        }
        
        // For taller screens (iPad), use proportional height
        let proportionalHeight = screenHeight * 0.6
        return min(max(proportionalHeight, 450), 700)
    }
    
    private var currentAsset: PHAsset {
        assets[currentIndex]
    }
    
    private var shouldUseGeometryEffect: Bool {
        !hasNavigated && currentIndex == initialIndex
    }
    
    init(assets: [PHAsset], initialIndex: Int, namespace: Namespace.ID, isPresented: Binding<Bool>) {
        self.assets = assets
        self.initialIndex = initialIndex
        self.namespace = namespace
        self._isPresented = isPresented
        self._currentIndex = State(initialValue: initialIndex)
    }
    
    /// Calculates photo vertical offset when info panel is shown.
    /// Moves photo up by half the panel height to make room for EXIF info.
    private func computedPhotoOffset(for geometry: GeometryProxy) -> CGFloat {
        if showInfoPanel {
            let panelHeight = infoPanelHeight(for: geometry)
            return -(panelHeight / 2) + photoVerticalOffset
        }
        return photoVerticalOffset
    }
    
    /// Calculates info panel Y offset based on visibility state and drag gesture.
    private func infoPanelCurrentOffset(for geometry: GeometryProxy) -> CGFloat {
        let panelHeight = infoPanelHeight(for: geometry)
        return showInfoPanel
            ? infoPanelDragOffset
            : panelHeight + infoPanelDragOffset
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .opacity(1.0 - (dragProgress * 0.5))
                    .ignoresSafeArea()
                
                photoContent(geometry: geometry)
                    .offset(y: computedPhotoOffset(for: geometry))
                    .offset(offset)
                
                closeButton
                
                infoPanelView(geometry: geometry)
            }
        }
        .gesture(
            // Disable drag gesture when zoomed to let UIScrollView handle panning
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    handleDragChange(value: value)
                }
                .onEnded { value in
                    handleDragEnd(value: value)
                },
            isEnabled: scale <= 1.0
        )
        .statusBar(hidden: true)
        .onAppear {
            loadCurrentAsset()
        }
        .onDisappear {
            cleanupCurrentAsset()
        }
        .onChange(of: currentIndex) { oldValue, newValue in
            // Reset states and reload when switching to a different photo
            cleanupCurrentAsset()
            resetAssetStates()
            loadCurrentAsset()
        }
    }
    
    // MARK: - Drag Handling
    
    private func handleDragChange(value: DragGesture.Value) {
        guard scale <= 1.0 else { return }
        
        let horizontalTranslation = value.translation.width
        let verticalTranslation = value.translation.height
        
        // Determine drag direction based on initial movement
        let isHorizontalGesture = abs(horizontalTranslation) > abs(verticalTranslation)
        
        if showInfoPanel {
            // When info panel is open, only handle vertical drag to dismiss it
            if verticalTranslation > 0 {
                infoPanelDragOffset = verticalTranslation
                photoVerticalOffset = verticalTranslation * 0.5
            }
        } else if isHorizontalGesture && !isDragging {
            // Horizontal swipe for photo navigation (only when not in vertical dismiss drag)
            isHorizontalDragging = true
            horizontalOffset = horizontalTranslation
        } else if !isHorizontalDragging {
            // Vertical handling for info panel and dismiss
            if verticalTranslation < 0 {
                infoPanelDragOffset = verticalTranslation
                photoVerticalOffset = verticalTranslation * 0.3
            } else if verticalTranslation > 0 {
                isDragging = true
                offset = value.translation
                let verticalProgress = verticalTranslation / dismissThreshold
                dragProgress = min(verticalProgress, 1.0)
            }
        }
    }
    
    private func handleDragEnd(value: DragGesture.Value) {
        guard scale <= 1.0 else { return }
        
        let horizontalTranslation = value.translation.width
        let verticalTranslation = value.translation.height
        let horizontalVelocity = value.predictedEndTranslation.width - horizontalTranslation
        let verticalVelocity = value.predictedEndTranslation.height - verticalTranslation
        
        if isHorizontalDragging {
            // Handle horizontal swipe for navigation
            let shouldNavigate = abs(horizontalTranslation) > horizontalSwipeThreshold || abs(horizontalVelocity) > 300
            
            if shouldNavigate {
                if horizontalTranslation > 0 || horizontalVelocity > 300 {
                    // Swipe right - go to previous photo
                    navigateToPrevious()
                } else {
                    // Swipe left - go to next photo
                    navigateToNext()
                }
            } else {
                // Snap back to center
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    horizontalOffset = 0
                }
            }
            isHorizontalDragging = false
        } else if showInfoPanel {
            if verticalTranslation > 80 || verticalVelocity > 300 {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    showInfoPanel = false
                    infoPanelDragOffset = 0
                    photoVerticalOffset = 0
                }
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    infoPanelDragOffset = 0
                    photoVerticalOffset = 0
                }
            }
        } else {
            if verticalTranslation < -swipeUpThreshold || verticalVelocity < -300 {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    showInfoPanel = true
                    infoPanelDragOffset = 0
                    photoVerticalOffset = 0
                }
            } else if verticalTranslation > dismissThreshold || verticalVelocity > 500 {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    isPresented = false
                }
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    offset = .zero
                    dragProgress = 0
                    infoPanelDragOffset = 0
                    photoVerticalOffset = 0
                }
                isDragging = false
            }
        }
    }
    
    // MARK: - Navigation
    
    private var canNavigateToPrevious: Bool {
        currentIndex > 0
    }
    
    private var canNavigateToNext: Bool {
        currentIndex < assets.count - 1
    }
    
    private func navigateToPrevious() {
        guard canNavigateToPrevious else {
            // Bounce back animation when at the first photo
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                horizontalOffset = 0
            }
            return
        }
        
        hasNavigated = true
        
        // Animate slide out to right, then update index
        withAnimation(.easeOut(duration: 0.2)) {
            horizontalOffset = UIScreen.main.bounds.width
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            currentIndex -= 1
            horizontalOffset = 0
        }
    }
    
    private func navigateToNext() {
        guard canNavigateToNext else {
            // Bounce back animation when at the last photo
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                horizontalOffset = 0
            }
            return
        }
        
        hasNavigated = true
        
        // Animate slide out to left, then update index
        withAnimation(.easeOut(duration: 0.2)) {
            horizontalOffset = -UIScreen.main.bounds.width
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            currentIndex += 1
            horizontalOffset = 0
        }
    }
    
    // MARK: - Content Views
    
    @ViewBuilder
    private func photoContent(geometry: GeometryProxy) -> some View {
        Group {
            if currentAsset.mediaType == .video {
                videoContent(geometry: geometry)
            } else {
                imageContent(geometry: geometry)
            }
        }
        .offset(x: horizontalOffset)
    }
    
    @ViewBuilder
    private func imageContent(geometry: GeometryProxy) -> some View {
        if let image = fullImage {
            let zoomableView = ZoomableImageView(
                image: image,
                scale: $scale,
                onDoubleTap: {},
                onSingleTap: {
                    if showInfoPanel {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            showInfoPanel = false
                            photoVerticalOffset = 0
                        }
                    }
                }
            )
            
            // Only apply matchedGeometryEffect for the initial photo
            if shouldUseGeometryEffect {
                zoomableView
                    .matchedGeometryEffect(id: currentAsset.localIdentifier, in: namespace)
            } else {
                zoomableView
            }
        } else {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
        }
    }
    
    @ViewBuilder
    private func videoContent(geometry: GeometryProxy) -> some View {
        ZStack {
            if let image = fullImage, player == nil {
                let thumbnailImage = Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                
                // Only apply matchedGeometryEffect for the initial photo
                if shouldUseGeometryEffect {
                    thumbnailImage
                        .matchedGeometryEffect(id: currentAsset.localIdentifier, in: namespace)
                } else {
                    thumbnailImage
                }
            }
            
            if let player = player {
                let videoView = VideoPlayer(player: player)
                    .aspectRatio(CGFloat(currentAsset.pixelWidth) / CGFloat(currentAsset.pixelHeight), contentMode: .fit)
                    .onAppear {
                        player.play()
                        isVideoPlaying = true
                    }
                
                // Only apply matchedGeometryEffect for the initial photo
                if shouldUseGeometryEffect {
                    videoView
                        .matchedGeometryEffect(id: currentAsset.localIdentifier, in: namespace)
                } else {
                    videoView
                }
            } else if isVideoLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("Loading video...")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.8))
                }
            } else if fullImage == nil {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
            }
            
            if player != nil && !isVideoPlaying && !isVideoLoading {
                Button {
                    player?.play()
                    isVideoPlaying = true
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.white.opacity(0.9), .black.opacity(0.3))
                        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 4)
                }
            }
        }
        .onTapGesture {
            if showInfoPanel {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    showInfoPanel = false
                    photoVerticalOffset = 0
                }
            } else if let player = player {
                if isVideoPlaying {
                    player.pause()
                    isVideoPlaying = false
                } else {
                    player.play()
                    isVideoPlaying = true
                }
            }
        }
    }
    
    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                        isPresented = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.9), .black.opacity(0.4))
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                }
                .padding(.trailing, 16)
                .padding(.top, 8)
            }
            Spacer()
        }
        .opacity(showInfoPanel ? 0.5 : 1.0)
    }
    
    // MARK: - Info Panel
    
    @ViewBuilder
    private func infoPanelView(geometry: GeometryProxy) -> some View {
        let panelHeight = infoPanelHeight(for: geometry)
        
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(white: 0.5))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 16)
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    dateTimeSection
                    
                    if cameraInfo != nil || exposureInfo != nil {
                        cameraSection
                    }
                    
                    if lensInfo != nil {
                        lensSection
                    }
                    
                    if locationName != nil || location != nil {
                        locationSection
                    }
                    
                    fileInfoSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: panelHeight)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(UIColor.systemBackground))
                .shadow(color: .black.opacity(0.15), radius: 20, y: -5)
        )
        .offset(y: geometry.size.height - panelHeight + infoPanelCurrentOffset(for: geometry))
    }
    
    private var dateTimeSection: some View {
        HStack(spacing: 12) {
            if let date = currentAsset.creationDate {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatDateLine(date))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(formatTimeLine(date))
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
    private var cameraSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 22))
                .foregroundColor(.secondary)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                if let camera = cameraInfo {
                    Text(camera)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                }
                
                if let exposure = exposureInfo {
                    Text(exposure)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
    private var lensSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.circle")
                .font(.system(size: 22))
                .foregroundColor(.secondary)
                .frame(width: 32)
            
            if let lens = lensInfo {
                Text(lens)
                    .font(.system(size: 15))
                    .foregroundColor(.primary)
            }
            
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
    private var locationSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "map.fill")
                .font(.system(size: 22))
                .foregroundColor(.secondary)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                if let name = locationName {
                    Text(name)
                        .font(.system(size: 15))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }
                
                if let loc = location {
                    Text(formatCoordinates(loc))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
    private var fileInfoSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.system(size: 22))
                .foregroundColor(.secondary)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName ?? "Unknown")
                    .font(.system(size: 15))
                    .foregroundColor(.primary)
                
                HStack(spacing: 4) {
                    Text("\(currentAsset.pixelWidth) × \(currentAsset.pixelHeight)")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    
                    if let size = fileSize {
                        Text("·")
                            .foregroundColor(.secondary)
                        Text(formatFileSize(size))
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    
                    if currentAsset.mediaType == .video {
                        Text("·")
                            .foregroundColor(.secondary)
                        Text(formatDuration(currentAsset.duration))
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
    private func formatDateLine(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M/d EEEE"
        return formatter.string(from: date)
    }
    
    private func formatTimeLine(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    // MARK: - Asset Lifecycle
    
    /// Loads the current asset's content based on its media type
    private func loadCurrentAsset() {
        if currentAsset.mediaType == .video {
            loadVideoThumbnail()
            loadVideo()
        } else {
            loadFullImage()
        }
        loadMetadata()
    }
    
    /// Cleans up resources for the current asset before switching or dismissing
    private func cleanupCurrentAsset() {
        imageLoadTask?.cancel()
        player?.pause()
        player = nil
        if let observer = playerEndObserver {
            NotificationCenter.default.removeObserver(observer)
            playerEndObserver = nil
        }
    }
    
    /// Resets all asset-specific state variables for fresh loading
    private func resetAssetStates() {
        fullImage = nil
        scale = 1.0
        offset = .zero
        dragProgress = 0
        isDragging = false
        isVideoLoading = false
        isVideoPlaying = false
        showInfoPanel = false
        infoPanelDragOffset = 0
        photoVerticalOffset = 0
        location = nil
        locationName = nil
        cameraInfo = nil
        lensInfo = nil
        exposureInfo = nil
        fileName = nil
        fileSize = nil
    }
    
    // MARK: - Data Loading
    
    private func loadFullImage() {
        let assetToLoad = currentAsset
        imageLoadTask = Task {
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            options.resizeMode = .none
            
            await withCheckedContinuation { continuation in
                PHImageManager.default().requestImage(
                    for: assetToLoad,
                    targetSize: PHImageManagerMaximumSize,
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    
                    Task { @MainActor in
                        if let image = image {
                            self.fullImage = image
                        }
                        
                        if !isDegraded {
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }
    
    private func loadVideoThumbnail() {
        let assetToLoad = currentAsset
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        
        let targetSize = CGSize(
            width: UIScreen.main.bounds.width * UIScreen.main.scale,
            height: UIScreen.main.bounds.height * UIScreen.main.scale
        )
        
        PHImageManager.default().requestImage(
            for: assetToLoad,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            Task { @MainActor in
                if let image = image {
                    self.fullImage = image
                }
            }
        }
    }
    
    private func loadVideo() {
        let assetToLoad = currentAsset
        isVideoLoading = true
        
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        
        PHImageManager.default().requestPlayerItem(forVideo: assetToLoad, options: options) { playerItem, info in
            Task { @MainActor in
                self.isVideoLoading = false
                
                if let playerItem = playerItem {
                    let avPlayer = AVPlayer(playerItem: playerItem)
                    self.player = avPlayer
                    
                    self.playerEndObserver = NotificationCenter.default.addObserver(
                        forName: .AVPlayerItemDidPlayToEndTime,
                        object: playerItem,
                        queue: .main
                    ) { [weak avPlayer] _ in
                        avPlayer?.seek(to: .zero)
                        self.isVideoPlaying = false
                    }
                }
            }
        }
    }
    
    private func loadMetadata() {
        let assetToLoad = currentAsset
        location = assetToLoad.location
        
        // Load resource info and file size on background thread
        Task.detached(priority: .userInitiated) {
            let resources = PHAssetResource.assetResources(for: assetToLoad)
            guard let primaryResource = resources.first else { return }
            
            let resourceFilename = primaryResource.originalFilename
            
            await MainActor.run {
                self.fileName = resourceFilename
            }
            
            // Load file size asynchronously via streaming
            var size: Int64 = 0
            PHAssetResourceManager.default().requestData(
                for: primaryResource,
                options: nil,
                dataReceivedHandler: { data in
                    size += Int64(data.count)
                },
                completionHandler: { error in
                    if error == nil {
                        Task { @MainActor in
                            self.fileSize = size
                        }
                    }
                }
            )
        }
        
        if let loc = location {
            Task.detached(priority: .utility) {
                let geocoder = CLGeocoder()
                do {
                    let placemarks = try await geocoder.reverseGeocodeLocation(loc)
                    if let placemark = placemarks.first {
                        var parts: [String] = []
                        if let locality = placemark.locality {
                            parts.append(locality)
                        }
                        if let administrativeArea = placemark.administrativeArea {
                            parts.append(administrativeArea)
                        }
                        if let country = placemark.country {
                            parts.append(country)
                        }
                        let locationString = parts.joined(separator: ", ")
                        await MainActor.run {
                            self.locationName = locationString
                        }
                    }
                } catch {
                    // Geocoding failed, location name remains nil
                }
            }
        }
        
        Task.detached(priority: .userInitiated) {
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            
            // Use continuation to bridge callback-based API to async/await
            let metadataResult: (exif: [String: Any]?, tiff: [String: Any]?)? = await withCheckedContinuation { continuation in
                assetToLoad.requestContentEditingInput(with: options) { input, info in
                    guard let url = input?.fullSizeImageURL,
                          let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
                        continuation.resume(returning: nil)
                        return
                    }
                    
                    let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
                    let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
                    continuation.resume(returning: (exif, tiff))
                }
            }
            
            guard let result = metadataResult else { return }
            
            if let exif = result.exif {
                var exposureParts: [String] = []
                
                if let fNumber = exif[kCGImagePropertyExifFNumber as String] as? Double {
                    exposureParts.append("ƒ/\(String(format: "%.1f", fNumber))")
                }
                
                if let exposureTime = exif[kCGImagePropertyExifExposureTime as String] as? Double {
                    if exposureTime >= 1 {
                        exposureParts.append("\(String(format: "%.1f", exposureTime))s")
                    } else {
                        exposureParts.append("1/\(Int(1/exposureTime))s")
                    }
                }
                
                if let iso = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int], let isoValue = iso.first {
                    exposureParts.append("ISO \(isoValue)")
                }
                
                if let focalLength = exif[kCGImagePropertyExifFocalLength as String] as? Double {
                    exposureParts.append("\(Int(focalLength)) mm")
                }
                
                let finalExposureInfo = exposureParts.isEmpty ? nil : exposureParts.joined(separator: "  ")
                let lensModel = exif[kCGImagePropertyExifLensModel as String] as? String
                
                await MainActor.run {
                    self.exposureInfo = finalExposureInfo
                    self.lensInfo = lensModel
                }
            }
            
            if let tiff = result.tiff {
                let make = tiff[kCGImagePropertyTIFFMake as String] as? String
                let model = tiff[kCGImagePropertyTIFFModel as String] as? String
                
                if let model = model {
                    var cameraName = model
                    // Avoid duplicate manufacturer name in camera string
                    if let make = make, !model.lowercased().contains(make.lowercased()) {
                        cameraName = "\(make) \(model)"
                    }
                    
                    await MainActor.run {
                        self.cameraInfo = cameraName
                    }
                }
            }
        }
    }
    
    private func formatCoordinates(_ location: CLLocation) -> String {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let latDir = lat >= 0 ? "N" : "S"
        let lonDir = lon >= 0 ? "E" : "W"
        return String(format: "%.4f° %@, %.4f° %@", abs(lat), latDir, abs(lon), lonDir)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            return String(format: "%d:%02d:%02d", hours, remainingMinutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
    
}

// MARK: - Preview
#Preview {
    @Previewable @Namespace var namespace
    @Previewable @State var isPresented = true
    
    ZStack {
        Color.gray
        if isPresented {
            Text("Preview requires a real PHAsset array")
                .foregroundColor(.white)
        }
    }
}
