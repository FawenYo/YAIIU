import SwiftUI
import Photos
import CoreLocation

// MARK: - Photo Detail View
/// A full-screen photo viewer with Apple Photos-like aesthetics and animations
struct PhotoDetailView: View {
    let asset: PHAsset
    let namespace: Namespace.ID
    @Binding var isPresented: Bool
    
    @State private var fullImage: UIImage?
    @State private var offset: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var isDragging: Bool = false
    @State private var dragProgress: CGFloat = 0
    @State private var imageLoadTask: Task<Void, Never>?
    
    // Info panel states
    @State private var showInfoPanel: Bool = false
    @State private var infoPanelDragOffset: CGFloat = 0
    @State private var photoVerticalOffset: CGFloat = 0
    
    // Photo metadata
    @State private var location: CLLocation?
    @State private var locationName: String?
    @State private var cameraInfo: String?
    @State private var lensInfo: String?
    @State private var exposureInfo: String?
    
    private let dismissThreshold: CGFloat = 150
    private let infoPanelHeight: CGFloat = 500
    private let swipeUpThreshold: CGFloat = 60
    
    // Computed photo offset when info panel is shown
    private var computedPhotoOffset: CGFloat {
        if showInfoPanel {
            return -(infoPanelHeight / 2) + photoVerticalOffset
        }
        return photoVerticalOffset
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                Color.black
                    .opacity(1.0 - (dragProgress * 0.5))
                    .ignoresSafeArea()
                
                // Main photo content - moves up when info panel shows
                photoContent(geometry: geometry)
                    .offset(y: computedPhotoOffset)
                
                // Close button (always visible when not dragging)
                closeButton
                
                // Info panel - slides up from bottom
                infoPanelView(geometry: geometry)
            }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    handleDragChange(value: value)
                }
                .onEnded { value in
                    handleDragEnd(value: value)
                }
        )
        .statusBar(hidden: true)
        .onAppear {
            loadFullImage()
            loadMetadata()
        }
        .onDisappear {
            imageLoadTask?.cancel()
        }
    }
    
    // MARK: - Drag Handling
    private func handleDragChange(value: DragGesture.Value) {
        guard scale == 1.0 else { return }
        
        let translation = value.translation.height
        
        if showInfoPanel {
            // Info panel is open
            if translation > 0 {
                // Dragging down - close the panel
                infoPanelDragOffset = translation
                // Also move photo back down
                photoVerticalOffset = translation * 0.5
            }
        } else {
            // Info panel is closed
            if translation < 0 {
                // Dragging up - open the panel
                let progress = min(abs(translation) / swipeUpThreshold, 1.0)
                infoPanelDragOffset = translation
                // Move photo up as we drag
                photoVerticalOffset = translation * 0.3
            } else if translation > 0 {
                // Dragging down - dismiss the view
                isDragging = true
                offset = value.translation
                let verticalProgress = translation / dismissThreshold
                dragProgress = min(verticalProgress, 1.0)
            }
        }
    }
    
    private func handleDragEnd(value: DragGesture.Value) {
        guard scale == 1.0 else { return }
        
        let translation = value.translation.height
        let velocity = value.predictedEndTranslation.height - translation
        
        if showInfoPanel {
            // Info panel is open
            if translation > 80 || velocity > 300 {
                // Swipe down - close info panel
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    showInfoPanel = false
                    infoPanelDragOffset = 0
                    photoVerticalOffset = 0
                }
            } else {
                // Snap back to open position
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    infoPanelDragOffset = 0
                    photoVerticalOffset = 0
                }
            }
        } else {
            // Info panel is closed
            if translation < -swipeUpThreshold || velocity < -300 {
                // Swipe up - show info panel
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    showInfoPanel = true
                    infoPanelDragOffset = 0
                    photoVerticalOffset = 0
                }
            } else if translation > dismissThreshold || velocity > 500 {
                // Swipe down far enough - dismiss the view
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    isPresented = false
                }
            } else {
                // Snap back
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
    
    // MARK: - Photo Content
    @ViewBuilder
    private func photoContent(geometry: GeometryProxy) -> some View {
        if let image = fullImage {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .matchedGeometryEffect(id: asset.localIdentifier, in: namespace)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    // Magnification gesture for zoom
                    MagnificationGesture()
                        .onChanged { value in
                            guard !showInfoPanel else { return }
                            let newScale = lastScale * value
                            scale = min(max(newScale, 1.0), 4.0)
                        }
                        .onEnded { value in
                            lastScale = scale
                            if scale < 1.0 {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    scale = 1.0
                                    lastScale = 1.0
                                }
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    guard !showInfoPanel else { return }
                    // Double tap to zoom
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        if scale > 1.0 {
                            scale = 1.0
                            lastScale = 1.0
                            offset = .zero
                        } else {
                            scale = 2.0
                            lastScale = 2.0
                        }
                    }
                }
                .onTapGesture {
                    // Single tap - if info panel is open, close it
                    if showInfoPanel {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            showInfoPanel = false
                            photoVerticalOffset = 0
                        }
                    }
                }
        } else {
            // Loading placeholder
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
        }
    }
    
    // MARK: - Close Button
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
    
    // MARK: - Info Panel View
    @ViewBuilder
    private func infoPanelView(geometry: GeometryProxy) -> some View {
        let baseOffset = showInfoPanel ? 0 : infoPanelHeight
        let panelOffset = baseOffset + infoPanelDragOffset
        
        VStack(spacing: 0) {
            // Drag indicator
            Capsule()
                .fill(Color.gray.opacity(0.5))
                .frame(width: 40, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 16)
            
            // Photo info content
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    // Date and time
                    dateTimeSection
                    
                    Divider()
                        .background(Color.gray.opacity(0.3))
                    
                    // Location
                    if locationName != nil || location != nil {
                        locationSection
                        Divider()
                            .background(Color.gray.opacity(0.3))
                    }
                    
                    // Technical details
                    technicalSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 50)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: infoPanelHeight)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 25, y: -10)
        )
        .offset(y: geometry.size.height - infoPanelHeight + panelOffset)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showInfoPanel)
    }
    
    // MARK: - Date Time Section
    private var dateTimeSection: some View {
        HStack(spacing: 14) {
            Image(systemName: "calendar")
                .font(.system(size: 22))
                .foregroundColor(.blue)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 3) {
                if let date = asset.creationDate {
                    Text(formatDate(date))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.black)
                    Text(formatTime(date))
                        .font(.system(size: 15))
                        .foregroundColor(.gray)
                } else {
                    Text("Unknown Date")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.gray)
                }
            }
            
            Spacer()
        }
    }
    
    // MARK: - Location Section
    private var locationSection: some View {
        HStack(spacing: 14) {
            Image(systemName: "location.fill")
                .font(.system(size: 22))
                .foregroundColor(.blue)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 3) {
                if let name = locationName {
                    Text(name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.black)
                        .lineLimit(2)
                }
                if let loc = location {
                    Text(formatCoordinates(loc))
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                }
            }
            
            Spacer()
        }
    }
    
    // MARK: - Technical Section
    private var technicalSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Dimensions and file type
            HStack(spacing: 14) {
                Image(systemName: "aspectratio")
                    .font(.system(size: 20))
                    .foregroundColor(.blue)
                    .frame(width: 32)
                
                Text("\(asset.pixelWidth) × \(asset.pixelHeight)")
                    .font(.system(size: 16))
                    .foregroundColor(.black)
                
                Spacer()
                
                // File type badge
                Text(getMediaTypeBadge())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(getMediaTypeBadgeColor())
                    .cornerRadius(8)
            }
            
            // Camera info
            if let camera = cameraInfo {
                HStack(spacing: 14) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.blue)
                        .frame(width: 32)
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text(camera)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.black)
                        
                        if let lens = lensInfo {
                            Text(lens)
                                .font(.system(size: 14))
                                .foregroundColor(.gray)
                        }
                    }
                    
                    Spacer()
                }
            }
            
            // Exposure info
            if let exposure = exposureInfo {
                HStack(spacing: 14) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 20))
                        .foregroundColor(.blue)
                        .frame(width: 32)
                    
                    Text(exposure)
                        .font(.system(size: 15))
                        .foregroundColor(.gray)
                    
                    Spacer()
                }
            }
            
            // Video duration
            if asset.mediaType == .video {
                HStack(spacing: 14) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.blue)
                        .frame(width: 32)
                    
                    Text(formatDuration(asset.duration))
                        .font(.system(size: 16))
                        .foregroundColor(.black)
                    
                    Spacer()
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func loadFullImage() {
        imageLoadTask = Task {
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            
            let targetSize = CGSize(
                width: UIScreen.main.bounds.width * UIScreen.main.scale,
                height: UIScreen.main.bounds.height * UIScreen.main.scale
            )
            
            await withCheckedContinuation { continuation in
                PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    
                    Task { @MainActor in
                        if let image = image {
                            self.fullImage = image
                        }
                        
                        // Only resume continuation when we get the final image
                        if !isDegraded {
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }
    
    private func loadMetadata() {
        // Load location
        location = asset.location
        
        if let loc = location {
            let geocoder = CLGeocoder()
            geocoder.reverseGeocodeLocation(loc) { placemarks, error in
                if let placemark = placemarks?.first {
                    var parts: [String] = []
                    if let name = placemark.name {
                        parts.append(name)
                    }
                    if let locality = placemark.locality {
                        parts.append(locality)
                    }
                    if let country = placemark.country {
                        parts.append(country)
                    }
                    locationName = parts.joined(separator: ", ")
                }
            }
        }
        
        // Load EXIF metadata
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        
        asset.requestContentEditingInput(with: options) { input, info in
            guard let url = input?.fullSizeImageURL else { return }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            guard let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return }
            
            // Extract EXIF data
            if let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                var exposureParts: [String] = []
                
                if let fNumber = exif[kCGImagePropertyExifFNumber as String] as? Double {
                    exposureParts.append("f/\(String(format: "%.1f", fNumber))")
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
                    exposureParts.append("\(Int(focalLength))mm")
                }
                
                Task { @MainActor in
                    if !exposureParts.isEmpty {
                        self.exposureInfo = exposureParts.joined(separator: "  •  ")
                    }
                    
                    if let lensModel = exif[kCGImagePropertyExifLensModel as String] as? String {
                        self.lensInfo = lensModel
                    }
                }
            }
            
            // Extract TIFF data (camera make/model)
            if let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                let make = tiff[kCGImagePropertyTIFFMake as String] as? String
                let model = tiff[kCGImagePropertyTIFFModel as String] as? String
                
                Task { @MainActor in
                    if let model = model {
                        // Remove make from model if it's already included
                        var cameraName = model
                        if let make = make, model.lowercased().contains(make.lowercased()) {
                            cameraName = model
                        } else if let make = make {
                            cameraName = "\(make) \(model)"
                        }
                        self.cameraInfo = cameraName
                    }
                }
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
    
    private func getMediaTypeBadge() -> String {
        if asset.mediaType == .video {
            return "VIDEO"
        }
        
        let resources = PHAssetResource.assetResources(for: asset)
        for resource in resources {
            let uti = resource.uniformTypeIdentifier.lowercased()
            if uti.contains("heic") || uti.contains("heif") {
                return "HEIC"
            } else if uti.contains("raw") || uti.contains("dng") || uti.contains("arw") ||
                      uti.contains("cr2") || uti.contains("cr3") || uti.contains("nef") {
                return "RAW"
            } else if uti.contains("png") {
                return "PNG"
            }
        }
        return "JPEG"
    }
    
    private func getMediaTypeBadgeColor() -> Color {
        let badge = getMediaTypeBadge()
        switch badge {
        case "RAW":
            return .orange
        case "VIDEO":
            return .red
        case "HEIC":
            return .purple
        case "PNG":
            return .blue
        default:
            return .gray
        }
    }
}

// MARK: - Photo Detail Container
/// Container view that handles the matched geometry effect transition
struct PhotoDetailContainer: View {
    let asset: PHAsset
    let thumbnail: UIImage?
    let namespace: Namespace.ID
    @Binding var isPresented: Bool
    
    var body: some View {
        PhotoDetailView(
            asset: asset,
            namespace: namespace,
            isPresented: $isPresented
        )
    }
}

// MARK: - Preview
#Preview {
    @Previewable @Namespace var namespace
    @Previewable @State var isPresented = true
    
    ZStack {
        Color.gray
        if isPresented {
            Text("Preview requires a real PHAsset")
                .foregroundColor(.white)
        }
    }
}
