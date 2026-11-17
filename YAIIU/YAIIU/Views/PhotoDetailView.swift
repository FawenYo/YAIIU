import SwiftUI
import Photos
import CoreLocation
import AVKit
import AVFoundation
import UIKit
import MapKit

// MARK: - ZoomableScrollView

final class ZoomableScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let imageView = UIImageView()
    private var interactivePanGesture: UIPanGestureRecognizer!
    
    var onScaleChanged: ((CGFloat) -> Void)?
    var onDoubleTap: (() -> Void)?
    var onSingleTap: (() -> Void)?
    var onDragChanged: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint, CGPoint) -> Void)?
    
    private var currentImageSize: CGSize = .zero
    private var lastLayoutBounds: CGSize = .zero
    
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
        singleTap.require(toFail: doubleTap)
        imageView.addGestureRecognizer(singleTap)
        
        interactivePanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleInteractivePan(_:)))
        interactivePanGesture.delegate = self
        addGestureRecognizer(interactivePanGesture)
    }
    
    // MARK: - UIGestureRecognizerDelegate
    
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === interactivePanGesture {
            return zoomScale <= 1.0
        }
        return true
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
    
    @objc private func handleInteractivePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        
        switch gesture.state {
        case .changed:
            onDragChanged?(translation)
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: self)
            onDragEnded?(translation, velocity)
        default:
            break
        }
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
    
    // MARK: - Public
    
    func setImage(_ image: UIImage?) {
        guard let image = image else {
            imageView.image = nil
            currentImageSize = .zero
            lastLayoutBounds = .zero
            return
        }
        
        // Skip redundant updates for same image when bounds unchanged
        if imageView.image === image && lastLayoutBounds == bounds.size { return }

        // A sharper copy of the displayed photo (zoom upgrade) must keep the
        // user's current zoom and position instead of resetting the layout.
        if imageView.image != nil, lastLayoutBounds == bounds.size, currentImageSize.height > 0,
           abs(currentImageSize.width / currentImageSize.height - image.size.width / image.size.height) < 0.01 {
            currentImageSize = image.size
            imageView.image = image
            return
        }
        
        currentImageSize = image.size
        imageView.image = image
        zoomScale = 1.0
        
        if bounds.width > 0 && bounds.height > 0 {
            configureImageSize(for: image)
            lastLayoutBounds = bounds.size
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
        guard currentImageSize != .zero,
              bounds.width > 0 && bounds.height > 0,
              let image = imageView.image else { return }
        
        // Reconfigure image frame when bounds change (e.g., device rotation)
        if lastLayoutBounds != bounds.size {
            configureImageSize(for: image)
            lastLayoutBounds = bounds.size
        }
    }
}

// MARK: - NativeVideoPlayerView

/// Custom video player using AVPlayerLayer for native rendering performance.
/// Provides minimal controls that match the photo viewer aesthetic.
final class VideoPlayerUIView: UIView {
    var onTap: (() -> Void)?
    var onDragChanged: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint, CGPoint) -> Void)?
    
    private var interactivePanGesture: UIPanGestureRecognizer!
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        setupGestures()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }
    
    private var videoPlayerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
    
    private func setupGestures() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tapGesture)
        
        interactivePanGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(interactivePanGesture)
    }
    
    @objc private func handleTap() {
        onTap?()
    }
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        
        switch gesture.state {
        case .changed:
            onDragChanged?(translation)
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: self)
            onDragEnded?(translation, velocity)
        default:
            break
        }
    }
    
    func setPlayer(_ player: AVPlayer?) {
        videoPlayerLayer.player = player
        videoPlayerLayer.videoGravity = .resizeAspect
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        videoPlayerLayer.frame = bounds
    }
}

/// SwiftUI wrapper for the native video player view.
struct NativeVideoPlayerView: UIViewRepresentable {
    let player: AVPlayer?
    let aspectRatio: CGFloat
    var onTap: (() -> Void)?
    var onDragChanged: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint, CGPoint) -> Void)?
    
    func makeUIView(context: Context) -> VideoPlayerUIView {
        let view = VideoPlayerUIView()
        view.onTap = onTap
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        return view
    }
    
    func updateUIView(_ uiView: VideoPlayerUIView, context: Context) {
        uiView.setPlayer(player)
        uiView.onTap = onTap
        uiView.onDragChanged = onDragChanged
        uiView.onDragEnded = onDragEnded
    }
}

// MARK: - AirPlayButton

/// UIKit wrapper for AVRoutePickerView to enable AirPlay functionality.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let routePickerView = AVRoutePickerView()
        routePickerView.tintColor = .white
        routePickerView.activeTintColor = .systemBlue
        routePickerView.prioritizesVideoDevices = true
        return routePickerView
    }
    
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - VideoControlsOverlay

/// Playback controls overlay with skip, speed, and AirPlay support.
struct VideoControlsOverlay: View {
    let player: AVPlayer
    let duration: TimeInterval
    @Binding var isPlaying: Bool
    @Binding var isVisible: Bool
    
    @State private var currentTime: TimeInterval = 0
    @State private var isSeeking: Bool = false
    @State private var hideTimer: Timer?
    @State private var timeObserver: Any?
    @State private var playbackRate: Float = 1.0
    @State private var showSpeedPicker: Bool = false
    
    private let skipInterval: TimeInterval = 5
    private let availableSpeeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    
    private var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }
    
    var body: some View {
        ZStack {
            // Gradient overlays for control visibility
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0.3), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 80)
                
                Spacer()
                
                LinearGradient(
                    colors: [.clear, .black.opacity(0.5)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 120)
            }
            .allowsHitTesting(false)
            
            VStack {
                // Top bar with AirPlay and speed
                topControlsBar
                
                Spacer()
                
                // Center playback controls
                centerControls
                
                Spacer()
                
                // Bottom bar with progress and time
                bottomControlsBar
            }
            
            // Speed picker overlay
            if showSpeedPicker {
                speedPickerOverlay
            }
        }
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isVisible)
        .onAppear {
            setupTimeObserver()
            scheduleHide()
        }
        .onDisappear {
            hideTimer?.invalidate()
            if let observer = timeObserver {
                player.removeTimeObserver(observer)
                timeObserver = nil
            }
        }
        .onChange(of: isVisible) { _, visible in
            if visible {
                scheduleHide()
            } else {
                showSpeedPicker = false
            }
        }
    }
    
    // MARK: - Top Controls
    
    private var topControlsBar: some View {
        HStack {
            Spacer()
            
            // Speed button
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSpeedPicker.toggle()
                }
                cancelHideTimer()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 14, weight: .medium))
                    Text(formatSpeed(playbackRate))
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial.opacity(0.8))
                .clipShape(Capsule())
            }
            
            // AirPlay button
            AirPlayButton()
                .frame(width: 36, height: 36)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
    
    // MARK: - Center Controls
    
    private var centerControls: some View {
        HStack(spacing: 48) {
            // Skip backward
            Button {
                skipBackward()
                scheduleHide()
            } label: {
                Image(systemName: "gobackward.5")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .contentShape(Circle())
            }
            
            // Play/Pause
            Button {
                togglePlayback()
                scheduleHide()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 72, height: 72)
                    .contentShape(Circle())
            }
            
            // Skip forward
            Button {
                skipForward()
                scheduleHide()
            } label: {
                Image(systemName: "goforward.5")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .contentShape(Circle())
            }
        }
    }
    
    // MARK: - Bottom Controls
    
    private var bottomControlsBar: some View {
        VStack(spacing: 8) {
            progressSlider
                .padding(.horizontal, 16)
            
            HStack {
                Text(formatTime(currentTime))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                
                Spacer()
                
                Text("-" + formatTime(duration - currentTime))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 16)
    }
    
    // MARK: - Progress Slider
    
    private var progressSlider: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 4)
                
                // Progress fill
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(0, geometry.size.width * progress), height: 4)
                
                // Thumb indicator (enlarged when seeking)
                Circle()
                    .fill(Color.white)
                    .frame(width: isSeeking ? 16 : 8, height: isSeeking ? 16 : 8)
                    .offset(x: max(0, geometry.size.width * progress - (isSeeking ? 8 : 4)))
                    .animation(.easeOut(duration: 0.15), value: isSeeking)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isSeeking = true
                        cancelHideTimer()
                        let fraction = max(0, min(1, value.location.x / geometry.size.width))
                        currentTime = duration * fraction
                        // Seek while scrubbing for real-time preview
                        let seekTime = CMTime(seconds: currentTime, preferredTimescale: 600)
                        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                    .onEnded { _ in
                        isSeeking = false
                        scheduleHide()
                    }
            )
        }
        .frame(height: 24)
    }
    
    // MARK: - Speed Picker
    
    private var speedPickerOverlay: some View {
        VStack(spacing: 0) {
            ForEach(availableSpeeds, id: \.self) { speed in
                Button {
                    setPlaybackRate(speed)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSpeedPicker = false
                    }
                    scheduleHide()
                } label: {
                    HStack {
                        Text(formatSpeed(speed))
                            .font(.system(size: 15, weight: speed == playbackRate ? .semibold : .regular))
                        
                        Spacer()
                        
                        if speed == playbackRate {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                
                if speed != availableSpeeds.last {
                    Divider()
                        .background(Color.white.opacity(0.2))
                }
            }
        }
        .frame(width: 140)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .position(x: UIScreen.main.bounds.width - 90, y: 140)
    }
    
    // MARK: - Actions
    
    private func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
            player.rate = playbackRate
        }
        isPlaying.toggle()
    }
    
    private func skipForward() {
        let newTime = min(currentTime + skipInterval, duration)
        let seekTime = CMTime(seconds: newTime, preferredTimescale: 600)
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = newTime
    }
    
    private func skipBackward() {
        let newTime = max(currentTime - skipInterval, 0)
        let seekTime = CMTime(seconds: newTime, preferredTimescale: 600)
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = newTime
    }
    
    private func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player.rate = rate
        }
    }
    
    // MARK: - Time Observer
    
    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [self] time in
            guard !isSeeking else { return }
            currentTime = time.seconds
        }
    }
    
    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            if isPlaying && !showSpeedPicker {
                withAnimation {
                    isVisible = false
                }
            }
        }
    }
    
    private func cancelHideTimer() {
        hideTimer?.invalidate()
    }
    
    // MARK: - Formatting
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(max(0, seconds))
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        if mins >= 60 {
            let hours = mins / 60
            let remainingMins = mins % 60
            return String(format: "%d:%02d:%02d", hours, remainingMins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }
    
    private func formatSpeed(_ rate: Float) -> String {
        if rate == 1.0 {
            return "1×"
        } else if rate == floor(rate) {
            return String(format: "%.0f×", rate)
        } else {
            return String(format: "%.2g×", rate)
        }
    }
}

// MARK: - ZoomableImageView
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage?
    @Binding var scale: CGFloat
    var onDoubleTap: (() -> Void)?
    var onSingleTap: (() -> Void)?
    var onDragChanged: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint, CGPoint) -> Void)?
    
    func makeUIView(context: Context) -> ZoomableScrollView {
        let scrollView = ZoomableScrollView()
        scrollView.onScaleChanged = { newScale in
            DispatchQueue.main.async {
                scale = newScale
            }
        }
        scrollView.onDoubleTap = onDoubleTap
        scrollView.onSingleTap = onSingleTap
        scrollView.onDragChanged = onDragChanged
        scrollView.onDragEnded = onDragEnded
        return scrollView
    }
    
    func updateUIView(_ uiView: ZoomableScrollView, context: Context) {
        uiView.setImage(image)
        uiView.onDragChanged = onDragChanged
        uiView.onDragEnded = onDragEnded
    }
}

// MARK: - PhotoDetailView
struct PhotoDetailView: View {
    let photoLibraryManager: PhotoLibraryManager
    let displayIndices: [Int]?
    let displayIndexGeneration: Int?
    let initialIndex: Int
    let namespace: Namespace.ID
    let refreshToken: UUID?
    @Binding var isPresented: Bool
    
    @State private var currentIndex: Int
    @State private var currentAsset: PHAsset?
    @State private var currentContentRevision: PhotoAssetContentRevision?
    @State private var fullImage: UIImage?
    @State private var offset: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    @State private var dragProgress: CGFloat = 0
    @State private var imageRequestID: PHImageRequestID?
    /// The zoom-quality image is requested only once the user zooms in.
    @State private var didRequestZoomResolution = false
    /// Asset content generation whose panel-only details (place name, EXIF) were requested.
    @State private var panelDetailsGeneration: Int?
    @State private var imageLoadGeneration = 0
    @State private var assetContentGeneration = 0
    @State private var imageLoadFailed: Bool = false
    
    @State private var player: AVPlayer?
    @State private var isVideoLoading: Bool = false
    @State private var isVideoPlaying: Bool = false
    @State private var playerEndObserver: NSObjectProtocol?
    @State private var showVideoControls: Bool = true
    
    @State private var infoPanelProgress: CGFloat = 0
    @State private var isInfoPanelScrollAtTop = true
    @State private var infoPanelOverscroll: CGFloat = 0
    @State private var isDraggingInfoPanel = false
    @State private var infoPanelDragBaseline: CGFloat = 0
    private static let infoPanelScrollSpace = "infoPanelScroll"
    @State private var location: CLLocation?
    @State private var locationName: String?
    @State private var cameraInfo: String?
    @State private var lensSummary: String?
    @State private var exifItems: [String] = []
    @State private var isExifLoaded = false
    @State private var fileName: String?
    @State private var fileSize: Int64?
    @State private var horizontalOffset: CGFloat = 0
    @State private var hasNavigated: Bool = false
    @State private var currentDragMode: DragMode = .none
    
    private enum DragMode {
        case none
        case horizontal
        case openPanel
        case closePanel
        case dismiss
    }
    
    /// Downsample large originals to a safe zoom preview size.
    /// Requesting PHImageManagerMaximumSize can decode 40–50MP RAW photos at once.
    private static let maxDisplayImageDimension: CGFloat = 4096
    /// Unzoomed viewing needs only the screen's pixel size; a 4096 px decode is
    /// ~50 MB per photo and dominated detail-view memory while swiping.
    private static var screenImageDimension: CGFloat {
        let bounds = UIScreen.main.bounds
        return max(bounds.width, bounds.height) * UIScreen.main.scale
    }

    private let dismissThreshold: CGFloat = 150
    private let horizontalSwipeThreshold: CGFloat = 80
    
    /// Fixed per device so the panel and photo keep the same size across assets.
    private func infoPanelHeight(for geometry: GeometryProxy) -> CGFloat {
        let ratio: CGFloat
        if UIDevice.current.userInterfaceIdiom == .phone {
            ratio = 0.72
        } else if geometry.size.width > geometry.size.height {
            ratio = 0.64
        } else {
            ratio = 0.53
        }
        return geometry.size.height * ratio
    }
    
    private var totalCount: Int {
        if let indices = displayIndices {
            return indices.count
        }
        return photoLibraryManager.assetCount
    }

    /// Filtered positions survive content-only updates, but stop navigation as
    /// soon as structural changes invalidate them. Unfiltered detail waits for
    /// its identifier snapshot when structural changes move those positions.
    private var isNavigationIndexReady: Bool {
        if displayIndices != nil {
            return displayIndexGeneration == photoLibraryManager.assetIndexGeneration
        }
        return displayIndexGeneration == photoLibraryManager.assetIndexGeneration ||
            photoLibraryManager.orderedIdentifiersGeneration == photoLibraryManager.assetFetchGeneration
    }
    
    private func resolveActualIndex(_ displayIndex: Int) -> Int {
        if let indices = displayIndices, displayIndex < indices.count {
            return indices[displayIndex]
        }
        return displayIndex
    }
    
    private var shouldUseGeometryEffect: Bool {
        !hasNavigated && currentIndex == initialIndex
    }
    
    private var isInfoPanelVisible: Bool {
        infoPanelProgress > 0
    }
    
    init(photoLibraryManager: PhotoLibraryManager, displayIndices: [Int]?, displayIndexGeneration: Int?, initialIndex: Int, namespace: Namespace.ID, refreshToken: UUID? = nil, isPresented: Binding<Bool>) {
        self.photoLibraryManager = photoLibraryManager
        self.displayIndices = displayIndices
        self.displayIndexGeneration = displayIndexGeneration
        self.initialIndex = initialIndex
        self.namespace = namespace
        self.refreshToken = refreshToken
        self._isPresented = isPresented
        self._currentIndex = State(initialValue: initialIndex)
    }
    
    private func geometryId(for asset: PHAsset) -> String {
        if let token = refreshToken {
            return "\(asset.localIdentifier)_\(token.uuidString)"
        }
        return asset.localIdentifier
    }
    
    private func computedPhotoOffset(for geometry: GeometryProxy) -> CGFloat {
        -(infoPanelHeight(for: geometry) / 2) * infoPanelProgress
    }
    
    private func infoPanelCurrentOffset(for geometry: GeometryProxy) -> CGFloat {
        infoPanelHeight(for: geometry) * (1 - infoPanelProgress)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .opacity(1.0 - (dragProgress * 0.5))
                    .ignoresSafeArea()
                
                if currentAsset != nil {
                    photoContent(geometry: geometry)
                        .offset(y: computedPhotoOffset(for: geometry))
                        .offset(offset)
                } else {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                }
                
                closeButton
                
                infoPanelView(geometry: geometry)
            }
        }
        .statusBar(hidden: true)
        .onAppear {
            photoLibraryManager.requireIdentifierSnapshotsForChanges()
            loadAssetAtCurrentIndex()
        }
        .onDisappear {
            cleanupCurrentAsset()
        }
        .onChange(of: isInfoPanelVisible) { _, visible in
            if visible, let asset = currentAsset {
                loadPanelDetails(for: asset)
            }
        }
        .onChange(of: currentIndex) { _, _ in
            // An index correction after a PhotoKit refresh is not navigation to
            // another photo: preserve zoom, info panel, and video playback.
            if let currentAsset,
               photoLibraryManager.asset(at: resolveActualIndex(currentIndex))?.localIdentifier == currentAsset.localIdentifier {
                return
            }
            cleanupCurrentAsset()
            resetAssetStates()
            loadAssetAtCurrentIndex()
        }
        .onReceive(photoLibraryManager.$orderedIdentifiersGeneration.receive(on: RunLoop.main)) { generation in
            guard let generation,
                  generation == photoLibraryManager.assetFetchGeneration,
                  photoLibraryManager.orderedIdentifiersGeneration == generation,
                  let previousAsset = currentAsset else { return }

            let updatedIndex: Int
            let actualIndex: Int
            if let indices = displayIndices {
                // Filtered positions remain valid across content-only fetch
                // replacements. Resolve the current photo directly at its
                // original position, without scanning the entire identifier list.
                guard displayIndexGeneration == photoLibraryManager.assetIndexGeneration,
                      indices.indices.contains(currentIndex) else { return }
                updatedIndex = currentIndex
                actualIndex = indices[currentIndex]
            } else {
                // Structural edits can shift unfiltered positions. Reconcile by
                // identity before loading any image from the replacement fetch.
                guard let index = photoLibraryManager.orderedLocalIdentifiers.firstIndex(
                    of: previousAsset.localIdentifier
                ) else {
                    isPresented = false
                    return
                }
                updatedIndex = index
                actualIndex = index
            }

            // Do not silently show a different photo at a reused filter index.
            guard let updatedAsset = photoLibraryManager.asset(at: actualIndex),
                  updatedAsset.localIdentifier == previousAsset.localIdentifier else {
                isPresented = false
                return
            }

            // A nonincremental PhotoKit change supplies no per-asset edit
            // identifiers. Refresh the open asset just as the grid does when
            // the current fetch generation requires a full content reload.
            let updatedContentRevision = ThumbnailCache.shared.contentRevision(
                for: updatedAsset.localIdentifier
            )
            let wasEdited = PhotoAssetContentRevision.needsReload(
                previousIdentifier: previousAsset.localIdentifier,
                previousRevision: currentContentRevision,
                currentIdentifier: updatedAsset.localIdentifier,
                currentRevision: updatedContentRevision
            ) || photoLibraryManager.fullReloadGeneration == generation
                || updatedAsset.modificationDate != previousAsset.modificationDate
            if updatedIndex != currentIndex {
                currentIndex = updatedIndex
            }
            if wasEdited {
                // Fetch result change details report content/metadata edits even
                // when an asset remains at the exact same index.
                cleanupCurrentAsset()
                resetAssetStates()
                currentAsset = updatedAsset
                currentContentRevision = updatedContentRevision
                loadCurrentAsset()
            } else {
                currentAsset = updatedAsset
                currentContentRevision = updatedContentRevision
            }
        }
    }
    
    private func loadAssetAtCurrentIndex() {
        let actualIndex = resolveActualIndex(currentIndex)
        currentAsset = photoLibraryManager.asset(at: actualIndex)
        if let currentAsset {
            currentContentRevision = ThumbnailCache.shared.contentRevision(
                for: currentAsset.localIdentifier
            )
            loadCurrentAsset()
        }
    }
    
    // MARK: - Drag Handling
    
    private func handleUIKitDragChanged(translation: CGPoint, panelHeight: CGFloat) {
        let dx = translation.x
        let dy = translation.y
        
        if currentDragMode == .none {
            let isHorizontal = abs(dx) > abs(dy)
            if infoPanelProgress > 0.5 && dy > 5 {
                currentDragMode = .closePanel
            } else if isHorizontal && abs(dx) > 5 {
                currentDragMode = .horizontal
            } else if dy < -5 && infoPanelProgress < 0.9 {
                currentDragMode = .openPanel
            } else if dy > 5 && infoPanelProgress < 0.1 {
                currentDragMode = .dismiss
            }
        }
        
        // Track the finger 1:1; a fixed short range moved the panel faster than the drag.
        switch currentDragMode {
        case .horizontal:
            horizontalOffset = dx
        case .openPanel:
            infoPanelProgress = max(0, min(1, -dy / panelHeight))
        case .closePanel:
            infoPanelProgress = max(0, min(1, 1.0 - dy / panelHeight))
        case .dismiss:
            offset = CGSize(width: dx, height: dy)
            dragProgress = min(1, max(0, dy / dismissThreshold))
        case .none:
            break
        }
    }
    
    private func handleUIKitDragEnded(translation: CGPoint, velocity: CGPoint) {
        let horizontalTranslation = translation.x
        let verticalTranslation = translation.y
        let horizontalVelocity = velocity.x
        let verticalVelocity = velocity.y
        
        let mode = currentDragMode
        currentDragMode = .none
        
        switch mode {
        case .horizontal:
            let shouldNavigate = abs(horizontalTranslation) > horizontalSwipeThreshold || abs(horizontalVelocity) > 300
            if shouldNavigate {
                if horizontalTranslation > 0 || horizontalVelocity > 300 {
                    navigateToPrevious()
                } else {
                    navigateToNext()
                }
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    horizontalOffset = 0
                }
            }
            
        case .openPanel:
            let shouldOpen = infoPanelProgress > 0.3 || verticalVelocity < -300
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                infoPanelProgress = shouldOpen ? 1 : 0
            }
            
        case .closePanel:
            let shouldClose = infoPanelProgress < 0.7 || verticalVelocity > 300
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                infoPanelProgress = shouldClose ? 0 : 1
            }
            
        case .dismiss:
            let shouldDismiss = dragProgress > 0.5 || verticalVelocity > 500
            if shouldDismiss {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    isPresented = false
                }
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    offset = .zero
                    dragProgress = 0
                }
            }
            
        case .none:
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                if infoPanelProgress > 0 && infoPanelProgress < 1 {
                    infoPanelProgress = infoPanelProgress > 0.5 ? 1 : 0
                }
                if offset != .zero {
                    offset = .zero
                    dragProgress = 0
                }
                if horizontalOffset != 0 {
                    horizontalOffset = 0
                }
            }
        }
    }
    
    // MARK: - Navigation
    
    private var canNavigateToPrevious: Bool {
        isNavigationIndexReady && currentIndex > 0
    }

    private var canNavigateToNext: Bool {
        isNavigationIndexReady && currentIndex < totalCount - 1
    }
    
    private func navigateToPrevious() {
        guard canNavigateToPrevious else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { horizontalOffset = 0 }
            return
        }
        hasNavigated = true
        withAnimation(.easeOut(duration: 0.2)) { horizontalOffset = UIScreen.main.bounds.width }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if canNavigateToPrevious { currentIndex -= 1 }
            horizontalOffset = 0
        }
    }
    
    private func navigateToNext() {
        guard canNavigateToNext else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { horizontalOffset = 0 }
            return
        }
        hasNavigated = true
        withAnimation(.easeOut(duration: 0.2)) { horizontalOffset = -UIScreen.main.bounds.width }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if canNavigateToNext { currentIndex += 1 }
            horizontalOffset = 0
        }
    }
    
    // MARK: - Content Views
    
    @ViewBuilder
    private func photoContent(geometry: GeometryProxy) -> some View {
        if let asset = currentAsset {
            Group {
                if asset.mediaType == .video {
                    videoContent(asset: asset, geometry: geometry)
                } else {
                    imageContent(asset: asset, geometry: geometry)
                }
            }
            .offset(x: horizontalOffset)
        }
    }
    
    @ViewBuilder
    private func imageContent(asset: PHAsset, geometry: GeometryProxy) -> some View {
        if let image = fullImage {
            let zoomableView = ZoomableImageView(
                image: image,
                scale: $scale,
                onDoubleTap: {},
                onSingleTap: {
                    if isInfoPanelVisible {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            infoPanelProgress = 0
                        }
                    }
                },
                onDragChanged: { translation in
                    handleUIKitDragChanged(translation: translation, panelHeight: infoPanelHeight(for: geometry))
                },
                onDragEnded: { translation, velocity in
                    handleUIKitDragEnded(translation: translation, velocity: velocity)
                }
            )
            .onChange(of: scale) { _, newScale in
                guard newScale > 1.05, !didRequestZoomResolution,
                      max(asset.pixelWidth, asset.pixelHeight) > Int(Self.screenImageDimension) else { return }
                didRequestZoomResolution = true
                loadFullImage(for: asset, maxDimension: Self.maxDisplayImageDimension)
            }
            
            if shouldUseGeometryEffect {
                zoomableView
                    .matchedGeometryEffect(id: geometryId(for: asset), in: namespace)
            } else {
                zoomableView
            }
        } else if imageLoadFailed {
            Button {
                if let requestID = imageRequestID {
                    PHImageManager.default().cancelImageRequest(requestID)
                    imageRequestID = nil
                }
                imageLoadFailed = false
                loadFullImage(for: asset, maxDimension: Self.screenImageDimension)
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 30))
                    Text(L10n.InitialSetup.retry)
                        .font(.subheadline)
                }
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
        } else {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
        }
    }
    
    @ViewBuilder
    private func videoContent(asset: PHAsset, geometry: GeometryProxy) -> some View {
        let aspectRatio = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
        
        ZStack {
            // Thumbnail placeholder while video loads
            if let image = fullImage, player == nil {
                let thumbnailImage = Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                if shouldUseGeometryEffect {
                    thumbnailImage.matchedGeometryEffect(id: geometryId(for: asset), in: namespace)
                } else {
                    thumbnailImage
                }
            }
            
            // Native video player with custom controls
            if let player = player {
                let videoContainer = ZStack {
                    NativeVideoPlayerView(
                        player: player,
                        aspectRatio: aspectRatio,
                        onTap: {
                            handleVideoTap()
                        },
                        onDragChanged: { translation in
                            handleUIKitDragChanged(translation: translation, panelHeight: infoPanelHeight(for: geometry))
                        },
                        onDragEnded: { translation, velocity in
                            handleUIKitDragEnded(translation: translation, velocity: velocity)
                        }
                    )
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    
                    // Controls overlay
                    VideoControlsOverlay(
                        player: player,
                        duration: asset.duration,
                        isPlaying: $isVideoPlaying,
                        isVisible: $showVideoControls
                    )
                    .aspectRatio(aspectRatio, contentMode: .fit)
                }
                .onAppear {
                    player.play()
                    isVideoPlaying = true
                }
                
                if shouldUseGeometryEffect {
                    videoContainer.matchedGeometryEffect(id: geometryId(for: asset), in: namespace)
                } else {
                    videoContainer
                }
            } else if isVideoLoading {
                // Loading indicator
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
            } else if fullImage == nil {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
            }
        }
    }
    
    private func handleVideoTap() {
        if isInfoPanelVisible {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                infoPanelProgress = 0
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                showVideoControls.toggle()
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
        .opacity(isInfoPanelVisible ? 0.5 : 1.0)
    }
    
    // MARK: - Info Panel
    
    private var cardBackground: Color {
        Color(UIColor.secondarySystemGroupedBackground)
    }
    
    @ViewBuilder
    private func infoPanelView(geometry: GeometryProxy) -> some View {
        let panelHeight = infoPanelHeight(for: geometry)
        
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                mainInfoCard
                
                // MapKit allocates a Metal renderer and tile caches per instance; build
                // it only while the panel is on screen, not for every swiped photo.
                if let loc = location, isInfoPanelVisible {
                    LocationMapView(coordinate: loc.coordinate, locationName: locationName, thumbnail: fullImage)
                        .background(cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        // Map(initialPosition:) ignores later coordinate changes.
                        .id(currentAsset?.localIdentifier)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 32)
            // The panel itself follows the finger; cancel the scroll view's rubber band
            // so the content does not move twice as far.
            .offset(y: isDraggingInfoPanel ? -infoPanelOverscroll : 0)
            // Measured outside the offset to avoid feedback. Bool and clamped values change
            // only at the top edge, so normal scrolling does not re-render every frame.
            .onGeometryChange(for: Bool.self) {
                $0.frame(in: .named(Self.infoPanelScrollSpace)).minY >= -1
            } action: { isInfoPanelScrollAtTop = $0 }
            .onGeometryChange(for: CGFloat.self) {
                max(0, $0.frame(in: .named(Self.infoPanelScrollSpace)).minY)
            } action: { infoPanelOverscroll = $0 }
        }
        .coordinateSpace(name: Self.infoPanelScrollSpace)
        .simultaneousGesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .global)
                .onChanged { value in
                    let dy = value.translation.height
                    if !isDraggingInfoPanel {
                        guard isInfoPanelScrollAtTop, dy > abs(value.translation.width) else { return }
                        isDraggingInfoPanel = true
                        // Distance already spent scrolling the content back to the top
                        // must not move the panel.
                        infoPanelDragBaseline = dy
                    }
                    infoPanelProgress = max(0, min(1, 1 - (dy - infoPanelDragBaseline) / panelHeight))
                }
                .onEnded { value in
                    guard isDraggingInfoPanel else { return }
                    isDraggingInfoPanel = false
                    let shouldClose = infoPanelProgress < 0.7 || value.velocity.height > 300
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        infoPanelProgress = shouldClose ? 0 : 1
                    }
                }
        )
        .frame(maxWidth: .infinity)
        .frame(height: panelHeight)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(UIColor.systemGroupedBackground))
                .shadow(color: .black.opacity(0.3), radius: 20, y: -5)
        )
        .offset(y: geometry.size.height - panelHeight + infoPanelCurrentOffset(for: geometry))
    }
    
    private var mainInfoCard: some View {
        let badge = PhotoInfoFormat.formatBadge(fileName: fileName)
        let isScreenshot = currentAsset?.mediaSubtypes.contains(.photoScreenshot) ?? false
        let cameraText = cameraInfo ?? (isScreenshot ? L10n.PhotoDetail.screenshot : nil)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                if let date = currentAsset?.creationDate {
                    Text(formatDateTime(date))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(fileName.map { ($0 as NSString).deletingPathExtension } ?? L10n.PhotoDetail.fileNameUnknown)
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .infoCardRow()
            
            if cameraText != nil || badge != nil {
                Divider()
                HStack {
                    Text(cameraText ?? "")
                        .font(.system(size: 17))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    if let badge {
                        Text(badge)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(UIColor.tertiarySystemFill), in: Capsule())
                    }
                    if isScreenshot {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .frame(width: 30, height: 30)
                            .background(Color(UIColor.tertiarySystemFill), in: Circle())
                    }
                }
                .infoCardRow()
            }
            
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(lensSummary ?? L10n.PhotoDetail.noLensInfo)
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .redacted(reason: isExifLoaded ? [] : .placeholder)
                Text(fileMetadataString)
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .infoCardRow()
            
            Divider()
            HStack(spacing: 0) {
                let items = exifItems.isEmpty ? Array(repeating: "-", count: 5) : exifItems
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 {
                        Divider().frame(height: 18)
                    }
                    Text(item)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .redacted(reason: isExifLoaded ? [] : .placeholder)
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
    
    private var fileMetadataString: String {
        guard let asset = currentAsset else { return "" }
        var parts: [String] = []
        if let mp = PhotoInfoFormat.megapixels(width: asset.pixelWidth, height: asset.pixelHeight) {
            parts.append(mp)
        }
        parts.append("\(asset.pixelWidth) × \(asset.pixelHeight)")
        if let size = fileSize {
            parts.append(formatFileSize(size))
        }
        if asset.mediaType == .video {
            parts.append(formatDuration(asset.duration))
        }
        return parts.joined(separator: " • ")
    }
    
    private func formatDateTime(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.wide).day().weekday(.wide).hour().minute())
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    // MARK: - Asset Lifecycle
    
    private func loadCurrentAsset() {
        guard let asset = currentAsset else { return }
        if asset.mediaType == .video {
            loadVideoThumbnail(for: asset)
            loadVideo(for: asset)
        } else {
            didRequestZoomResolution = false
            loadFullImage(for: asset, maxDimension: Self.screenImageDimension)
        }
        loadMetadata(for: asset)
        // The panel stays open across navigation, so the new asset needs its
        // place and EXIF details right away.
        if isInfoPanelVisible {
            loadPanelDetails(for: asset)
        }
    }
    
    private func cleanupCurrentAsset() {
        imageLoadGeneration &+= 1
        assetContentGeneration &+= 1
        if let requestID = imageRequestID {
            PHImageManager.default().cancelImageRequest(requestID)
            imageRequestID = nil
        }
        player?.pause()
        player = nil
        if let observer = playerEndObserver {
            NotificationCenter.default.removeObserver(observer)
            playerEndObserver = nil
        }
    }
    
    private func resetAssetStates() {
        currentAsset = nil
        currentContentRevision = nil
        fullImage = nil
        imageLoadFailed = false
        scale = 1.0
        offset = .zero
        dragProgress = 0
        currentDragMode = .none
        isVideoLoading = false
        isVideoPlaying = false
        showVideoControls = true
        location = nil
        locationName = nil
        cameraInfo = nil
        lensSummary = nil
        exifItems = []
        isExifLoaded = false
        fileName = nil
        fileSize = nil
    }
    
    // MARK: - Data Loading
    
    private func loadFullImage(for asset: PHAsset, maxDimension: CGFloat) {
        if let requestID = imageRequestID {
            PHImageManager.default().cancelImageRequest(requestID)
        }
        imageLoadGeneration &+= 1
        let requestGeneration = imageLoadGeneration
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.resizeMode = .exact

        // A bounded PhotoKit image is sufficient for a sharp screen/zoom preview.
        // The original file remains untouched for uploads and metadata extraction.
        let targetSize = CGSize(
            width: max(1, min(CGFloat(asset.pixelWidth), maxDimension)),
            height: max(1, min(CGFloat(asset.pixelHeight), maxDimension))
        )

        imageRequestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let errorDescription = (info?[PHImageErrorKey] as? Error)?.localizedDescription ?? "no image returned"
            guard !isCancelled else { return }

            Task { @MainActor in
                guard self.isPresented,
                      self.imageLoadGeneration == requestGeneration,
                      asset.localIdentifier == self.currentAsset?.localIdentifier else { return }
                if let image {
                    self.fullImage = image
                } else if !isDegraded {
                    guard self.fullImage == nil else {
                        // A failed zoom upgrade keeps the preview; zooming again retries.
                        self.didRequestZoomResolution = false
                        return
                    }
                    self.imageLoadFailed = true
                    logWarning("Unable to load photo preview: \(errorDescription)", category: .app)
                }
            }
        }
    }
    
    private func loadVideoThumbnail(for asset: PHAsset) {
        let contentGeneration = assetContentGeneration
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        
        let targetSize = CGSize(
            width: UIScreen.main.bounds.width * UIScreen.main.scale,
            height: UIScreen.main.bounds.height * UIScreen.main.scale
        )
        
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            Task { @MainActor in
                guard self.assetContentGeneration == contentGeneration,
                      asset.localIdentifier == self.currentAsset?.localIdentifier else { return }
                if let image {
                    self.fullImage = image
                }
            }
        }
    }
    
    private func loadVideo(for asset: PHAsset) {
        let contentGeneration = assetContentGeneration
        isVideoLoading = true
        
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        
        PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { playerItem, info in
            Task { @MainActor in
                guard self.assetContentGeneration == contentGeneration,
                      asset.localIdentifier == self.currentAsset?.localIdentifier else { return }
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
    
    private func loadMetadata(for asset: PHAsset) {
        let contentGeneration = assetContentGeneration
        location = asset.location
        
        Task.detached(priority: .userInitiated) {
            let resources = PHAssetResource.assetResources(for: asset)
            guard let primaryResource = resources.first else { return }
            
            let resourceFilename = primaryResource.resolvedFilename(using: asset)
            
            await MainActor.run {
                guard self.assetContentGeneration == contentGeneration else { return }
                self.fileName = resourceFilename
            }
            
            // KVC fileSize avoids materializing the original just to show a
            // size badge; requestData streaming here retained the whole file.
            let fileSizeValue = (primaryResource.value(forKey: "fileSize") as? CLong).map(Int64.init)
            await MainActor.run {
                guard self.assetContentGeneration == contentGeneration else { return }
                self.fileSize = fileSizeValue
            }
        }
    }

    /// Reverse geocoding and EXIF need a network call and a content-editing input
    /// (which downloads iCloud originals and holds a display-size image); load
    /// them only when the info panel is opened, not for every swiped photo.
    private func loadPanelDetails(for asset: PHAsset) {
        let contentGeneration = assetContentGeneration
        guard panelDetailsGeneration != contentGeneration else { return }
        panelDetailsGeneration = contentGeneration

        if let loc = location {
            Task.detached(priority: .utility) {
                let geocoder = CLGeocoder()
                do {
                    let placemarks = try await geocoder.reverseGeocodeLocation(loc)
                    if let placemark = placemarks.first {
                        let district = [placemark.locality, placemark.subLocality]
                            .compactMap { $0 }.joined(separator: " - ")
                        let locationString = district.isEmpty
                            ? [placemark.locality, placemark.administrativeArea, placemark.country]
                                .compactMap { $0 }.joined(separator: ", ")
                            : district
                        guard !locationString.isEmpty else { return }
                        await MainActor.run {
                            guard self.assetContentGeneration == contentGeneration else { return }
                            self.locationName = locationString
                        }
                    }
                } catch { }
            }
        }
        
        Task.detached(priority: .userInitiated) {
            // Only the header is needed. requestContentEditingInput prepares a full
            // editing input first and lagged by seconds on large RAW+JPEG assets.
            let resources = PHAssetResource.assetResources(for: asset)
            let photoResource = resources.first { $0.type == .photo }
                ?? resources.first { $0.type == .alternatePhoto }
            var metadata: [String: Any] = [:]
            if let photoResource, let fileURL = try? await ResourceFileAccess.tempFile(for: photoResource) {
                if let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                    metadata = properties
                }
                try? FileManager.default.removeItem(at: fileURL)
            }
            
            let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            
            let focal = ((exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Double)
                ?? (exif[kCGImagePropertyExifFocalLength as String] as? Double)).map { Int($0.rounded()) }
            let fNumber = exif[kCGImagePropertyExifFNumber as String] as? Double
            let exposureTime = (exif[kCGImagePropertyExifExposureTime as String] as? Double).flatMap { $0 > 0 ? $0 : nil }
            let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first
            let bias = exif[kCGImagePropertyExifExposureBiasValue as String] as? Double
            
            var items: [String] = []
            if let iso { items.append("ISO \(iso)") }
            if let focal { items.append("\(focal) mm") }
            if let bias { items.append(PhotoInfoFormat.exposureBias(bias)) }
            if let fNumber { items.append(PhotoInfoFormat.aperture(fNumber)) }
            if let exposureTime { items.append(PhotoInfoFormat.shutter(exposureTime)) }
            
            let make = tiff[kCGImagePropertyTIFFMake as String] as? String
            let model = tiff[kCGImagePropertyTIFFModel as String] as? String
            var cameraName: String?
            if let model {
                cameraName = model
                if let make, !model.lowercased().contains(make.lowercased()) {
                    cameraName = "\(make) \(model)"
                }
            }
            
            // Built-in phone lens models repeat the camera name and focal data; only a distinct lens name adds information.
            let lensModel = exif[kCGImagePropertyExifLensModel as String] as? String
            let short = [focal.map { "\($0) mm" }, fNumber.map(PhotoInfoFormat.aperture)]
                .compactMap { $0 }.joined(separator: " ")
            let lensSummary: String?
            if let lensModel, !(model.map { lensModel.hasPrefix($0) } ?? false) {
                lensSummary = lensModel
            } else {
                lensSummary = short.isEmpty ? nil : short
            }
            
            let finalItems = items
            let finalCamera = cameraName
            await MainActor.run {
                guard self.assetContentGeneration == contentGeneration else { return }
                self.exifItems = finalItems
                self.cameraInfo = finalCamera
                self.lensSummary = lensSummary
                self.isExifLoaded = true
            }
        }
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

private extension View {
    func infoCardRow() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum PhotoInfoFormat {
    /// "1.78", "2.8", "2": at most two decimals, trailing zeros trimmed, locale-independent.
    private static func trimmed(_ value: Double) -> String {
        var s = String(format: "%.2f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
    static func aperture(_ fNumber: Double) -> String { "ƒ\(trimmed(fNumber))" }
    static func shutter(_ seconds: Double) -> String {
        seconds >= 1 ? "\(trimmed(seconds)) s" : "1/\(Int((1 / seconds).rounded())) s"
    }
    static func exposureBias(_ ev: Double) -> String {
        let rounded = (ev * 100).rounded() / 100
        return rounded == 0 ? "0 ev" : "\(rounded > 0 ? "+" : "-")\(trimmed(abs(rounded))) ev"
    }
    /// Floored like Photos (6048x8064 -> "48 MP"); nil below 1 MP.
    static func megapixels(width: Int, height: Int) -> String? {
        let mp = width * height / 1_000_000
        return mp >= 1 ? "\(mp) MP" : nil
    }
    static func formatBadge(fileName: String?) -> String? {
        guard let ext = fileName.map({ ($0 as NSString).pathExtension.uppercased() }), !ext.isEmpty else { return nil }
        switch ext {
        case "HEIC", "HEIF": return "HEIF"
        case "JPG", "JPEG": return "JPEG"
        default: return ext
        }
    }
}

// MARK: - LocationMapView

struct LocationMapView: View {
    let coordinate: CLLocationCoordinate2D
    var locationName: String?
    var thumbnail: UIImage?
    
    var body: some View {
        VStack(spacing: 0) {
            Map(initialPosition: .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))),
                interactionModes: []) {
                Annotation("", coordinate: coordinate, anchor: .bottom) { pin }
            }
            .frame(height: 160)
            
            HStack(spacing: 6) {
                Text(locationName ?? formatCoordinates(coordinate))
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(UIColor.tertiaryLabel))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            openInMaps()
        }
    }
    
    @ViewBuilder
    private var pin: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(3)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 2)
        } else {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.white, .red)
        }
    }
    
    private func formatCoordinates(_ c: CLLocationCoordinate2D) -> String {
        let latDir = c.latitude >= 0 ? "N" : "S"
        let lonDir = c.longitude >= 0 ? "E" : "W"
        return String(format: "%.4f° %@, %.4f° %@", abs(c.latitude), latDir, abs(c.longitude), lonDir)
    }
    
    private func openInMaps() {
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = locationName
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: coordinate),
            MKLaunchOptionsMapSpanKey: NSValue(mkCoordinateSpan: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        ])
    }
}

// MARK: - Preview
#Preview {
    @Previewable @Namespace var namespace
    @Previewable @State var isPresented = true
    
    ZStack {
        Color.gray
        if isPresented {
            Text(L10n.PhotoDetail.previewRequiresAssets)
                .foregroundColor(.white)
        }
    }
}
