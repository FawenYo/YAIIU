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
        if currentImageSize == image.size && lastLayoutBounds == bounds.size { return }
        
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
    let initialIndex: Int
    let namespace: Namespace.ID
    @Binding var isPresented: Bool
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var currentIndex: Int
    @State private var currentAsset: PHAsset?
    @State private var fullImage: UIImage?
    @State private var offset: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    @State private var dragProgress: CGFloat = 0
    @State private var imageLoadTask: Task<Void, Never>?
    
    @State private var player: AVPlayer?
    @State private var isVideoLoading: Bool = false
    @State private var isVideoPlaying: Bool = false
    @State private var playerEndObserver: NSObjectProtocol?
    @State private var showVideoControls: Bool = true
    
    @State private var infoPanelProgress: CGFloat = 0
    @State private var location: CLLocation?
    @State private var locationName: String?
    @State private var cameraInfo: String?
    @State private var lensInfo: String?
    @State private var exposureInfo: String?
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
    
    private let dismissThreshold: CGFloat = 150
    private let horizontalSwipeThreshold: CGFloat = 80
    
    private func infoPanelHeight(for geometry: GeometryProxy) -> CGFloat {
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let isLandscape = geometry.size.width > geometry.size.height
        let hasCamera = cameraInfo != nil || exposureInfo != nil || lensInfo != nil
        let hasMap = location != nil
        let hasLocation = locationName != nil || location != nil
        
        var ratio: CGFloat
        var maxRatio: CGFloat
        
        if isPhone {
            ratio = 0.42
            if hasCamera { ratio += 0.10 }
            if hasMap { ratio += 0.20 }
            else if hasLocation { ratio += 0.10 }
            maxRatio = 0.72
        } else if isLandscape {
            // iPad landscape
            ratio = 0.38
            if hasCamera { ratio += 0.08 }
            if hasMap { ratio += 0.18 }
            else if hasLocation { ratio += 0.08 }
            maxRatio = 0.68
        } else {
            // iPad portrait
            ratio = 0.32
            if hasCamera { ratio += 0.06 }
            if hasMap { ratio += 0.15 }
            else if hasLocation { ratio += 0.06 }
            maxRatio = 0.58
        }
        
        let screenHeight = geometry.size.height
        return screenHeight * min(ratio, maxRatio)
    }
    
    private var totalCount: Int {
        if let indices = displayIndices {
            return indices.count
        }
        return photoLibraryManager.assetCount
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
    
    init(photoLibraryManager: PhotoLibraryManager, displayIndices: [Int]?, initialIndex: Int, namespace: Namespace.ID, isPresented: Binding<Bool>) {
        self.photoLibraryManager = photoLibraryManager
        self.displayIndices = displayIndices
        self.initialIndex = initialIndex
        self.namespace = namespace
        self._isPresented = isPresented
        self._currentIndex = State(initialValue: initialIndex)
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
            loadAssetAtCurrentIndex()
        }
        .onDisappear {
            cleanupCurrentAsset()
        }
        .onChange(of: currentIndex) { _, _ in
            cleanupCurrentAsset()
            resetAssetStates()
            loadAssetAtCurrentIndex()
        }
    }
    
    private func loadAssetAtCurrentIndex() {
        let actualIndex = resolveActualIndex(currentIndex)
        currentAsset = photoLibraryManager.asset(at: actualIndex)
        if currentAsset != nil {
            loadCurrentAsset()
        }
    }
    
    // MARK: - Drag Handling
    
    private func handleUIKitDragChanged(translation: CGPoint) {
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
        
        let panelDragRange: CGFloat = 200
        switch currentDragMode {
        case .horizontal:
            horizontalOffset = dx
        case .openPanel:
            infoPanelProgress = max(0, min(1, -dy / panelDragRange))
        case .closePanel:
            infoPanelProgress = max(0, min(1, 1.0 - dy / panelDragRange))
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
        currentIndex > 0
    }
    
    private var canNavigateToNext: Bool {
        currentIndex < totalCount - 1
    }
    
    private func navigateToPrevious() {
        guard canNavigateToPrevious else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { horizontalOffset = 0 }
            return
        }
        hasNavigated = true
        withAnimation(.easeOut(duration: 0.2)) { horizontalOffset = UIScreen.main.bounds.width }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { currentIndex -= 1; horizontalOffset = 0 }
    }
    
    private func navigateToNext() {
        guard canNavigateToNext else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { horizontalOffset = 0 }
            return
        }
        hasNavigated = true
        withAnimation(.easeOut(duration: 0.2)) { horizontalOffset = -UIScreen.main.bounds.width }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { currentIndex += 1; horizontalOffset = 0 }
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
                    handleUIKitDragChanged(translation: translation)
                },
                onDragEnded: { translation, velocity in
                    handleUIKitDragEnded(translation: translation, velocity: velocity)
                }
            )
            
            if shouldUseGeometryEffect {
                zoomableView
                    .matchedGeometryEffect(id: asset.localIdentifier, in: namespace)
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
    private func videoContent(asset: PHAsset, geometry: GeometryProxy) -> some View {
        let aspectRatio = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
        
        ZStack {
            // Thumbnail placeholder while video loads
            if let image = fullImage, player == nil {
                let thumbnailImage = Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                if shouldUseGeometryEffect {
                    thumbnailImage.matchedGeometryEffect(id: asset.localIdentifier, in: namespace)
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
                            handleUIKitDragChanged(translation: translation)
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
                    videoContainer.matchedGeometryEffect(id: asset.localIdentifier, in: namespace)
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
    
    private var infoPanelBackground: Color {
        colorScheme == .dark
            ? Color(white: 0.12)
            : Color(UIColor.systemBackground)
    }
    
    private var infoPanelSectionBackground: Color {
        colorScheme == .dark
            ? Color(white: 0.18)
            : Color(UIColor.secondarySystemGroupedBackground)
    }
    
    private var infoPanelHandleColor: Color {
        colorScheme == .dark
            ? Color(white: 0.4)
            : Color(white: 0.5)
    }
    
    @ViewBuilder
    private func infoPanelView(geometry: GeometryProxy) -> some View {
        let panelHeight = infoPanelHeight(for: geometry)
        
        VStack(spacing: 0) {
            Capsule()
                .fill(infoPanelHandleColor)
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 16)
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    dateTimeSection
                    
                    if cameraInfo != nil || exposureInfo != nil || lensInfo != nil {
                        cameraSection
                    }
                    
                    if locationName != nil || location != nil {
                        locationSection
                    }
                    
                    fileInfoSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: panelHeight)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(infoPanelBackground)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.15), radius: 20, y: -5)
        )
        .offset(y: geometry.size.height - panelHeight + infoPanelCurrentOffset(for: geometry))
    }
    
    private var dateTimeSection: some View {
        HStack(spacing: 0) {
            if let asset = currentAsset, let date = asset.creationDate {
                Text(formatDateTime(date))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }
    
    private var cameraSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 20))
                .foregroundColor(.secondary)
                .frame(width: 28)
            
            VStack(alignment: .leading, spacing: 2) {
                if let camera = cameraInfo {
                    if let lens = lensInfo {
                        Text("\(camera) · \(lens)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else {
                        Text(camera)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                    }
                } else if let lens = lensInfo {
                    Text(lens)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                }
                
                if let exposure = exposureInfo {
                    Text(exposure)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(infoPanelSectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
    private var locationSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "location.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
                    .frame(width: 28)
                
                VStack(alignment: .leading, spacing: 1) {
                    if let name = locationName {
                        Text(name)
                            .font(.system(size: 14))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    
                    if let loc = location {
                        Text(formatCoordinates(loc))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            
            if let loc = location {
                LocationMapView(coordinate: loc.coordinate, locationName: locationName)
                    .frame(height: 140)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0,
                            bottomLeadingRadius: 12,
                            bottomTrailingRadius: 12,
                            topTrailingRadius: 0
                        )
                    )
            }
        }
        .background(infoPanelSectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
    private var fileInfoSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.system(size: 20))
                .foregroundColor(.secondary)
                .frame(width: 28)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(fileName ?? L10n.PhotoDetail.fileNameUnknown)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                Text(fileMetadataString)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(infoPanelSectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
    private var fileMetadataString: String {
        guard let asset = currentAsset else { return "" }
        var parts: [String] = []
        parts.append("\(asset.pixelWidth)×\(asset.pixelHeight)")
        if let size = fileSize {
            parts.append(formatFileSize(size))
        }
        if asset.mediaType == .video {
            parts.append(formatDuration(asset.duration))
        }
        return parts.joined(separator: " · ")
    }
    
    private func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        formatter.doesRelativeDateFormatting = false
        return formatter.string(from: date)
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
            loadFullImage(for: asset)
        }
        loadMetadata(for: asset)
    }
    
    private func cleanupCurrentAsset() {
        imageLoadTask?.cancel()
        player?.pause()
        player = nil
        if let observer = playerEndObserver {
            NotificationCenter.default.removeObserver(observer)
            playerEndObserver = nil
        }
    }
    
    private func resetAssetStates() {
        currentAsset = nil
        fullImage = nil
        scale = 1.0
        offset = .zero
        dragProgress = 0
        currentDragMode = .none
        isVideoLoading = false
        isVideoPlaying = false
        showVideoControls = true
        infoPanelProgress = 0
        location = nil
        locationName = nil
        cameraInfo = nil
        lensInfo = nil
        exposureInfo = nil
        fileName = nil
        fileSize = nil
    }
    
    // MARK: - Data Loading
    
    private func loadFullImage(for asset: PHAsset) {
        imageLoadTask = Task {
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            options.resizeMode = .none
            
            await withCheckedContinuation { continuation in
                PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: PHImageManagerMaximumSize,
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    
                    Task { @MainActor in
                        if asset.localIdentifier == self.currentAsset?.localIdentifier {
                            if let image = image {
                                self.fullImage = image
                            }
                        }
                        
                        if !isDegraded {
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }
    
    private func loadVideoThumbnail(for asset: PHAsset) {
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
                if asset.localIdentifier == self.currentAsset?.localIdentifier {
                    if let image = image {
                        self.fullImage = image
                    }
                }
            }
        }
    }
    
    private func loadVideo(for asset: PHAsset) {
        isVideoLoading = true
        
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        
        PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { playerItem, info in
            Task { @MainActor in
                guard asset.localIdentifier == self.currentAsset?.localIdentifier else { return }
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
        location = asset.location
        
        Task.detached(priority: .userInitiated) {
            let resources = PHAssetResource.assetResources(for: asset)
            guard let primaryResource = resources.first else { return }
            
            let resourceFilename = primaryResource.originalFilename
            
            await MainActor.run {
                self.fileName = resourceFilename
            }
            
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
                } catch { }
            }
        }
        
        Task.detached(priority: .userInitiated) {
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            
            let metadataResult: (exif: [String: Any]?, tiff: [String: Any]?)? = await withCheckedContinuation { continuation in
                asset.requestContentEditingInput(with: options) { input, info in
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

// MARK: - LocationMapView

struct LocationMapView: View {
    let coordinate: CLLocationCoordinate2D
    var locationName: String?
    
    @State private var region: MKCoordinateRegion
    
    init(coordinate: CLLocationCoordinate2D, locationName: String? = nil) {
        self.coordinate = coordinate
        self.locationName = locationName
        _region = State(initialValue: MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))
    }
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Map(coordinateRegion: $region, annotationItems: [LocationPin(coordinate: coordinate)]) { pin in
                MapMarker(coordinate: pin.coordinate, tint: .red)
            }
            .disabled(true)
            
            Button {
                openInMaps()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12, weight: .medium))
                    Text(L10n.PhotoDetail.openInMaps)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
            }
            .padding(8)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            openInMaps()
        }
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

private struct LocationPin: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
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
