import Foundation
import Photos

struct PhotoAsset: Identifiable, Hashable {
    let id: String
    let asset: PHAsset
    let resources: [AssetResource]
    
    init(asset: PHAsset) {
        self.id = asset.localIdentifier
        self.asset = asset
        
        let phResources = PHAssetResource.assetResources(for: asset)
        self.resources = phResources.map { AssetResource(resource: $0) }
    }
    
    var mediaType: MediaType {
        switch asset.mediaType {
        case .image:
            return .photo
        case .video:
            return .video
        default:
            return .unknown
        }
    }
    
    var hasRAW: Bool {
        resources.contains { $0.isRAW }
    }
    
    var isVideo: Bool {
        mediaType == .video
    }
    
    var creationDate: Date? {
        asset.creationDate
    }
    
    var modificationDate: Date? {
        asset.modificationDate
    }
    
    var duration: TimeInterval {
        asset.duration
    }
    
    var pixelWidth: Int {
        asset.pixelWidth
    }
    
    var pixelHeight: Int {
        asset.pixelHeight
    }
    
    var isFavorite: Bool {
        asset.isFavorite
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: PhotoAsset, rhs: PhotoAsset) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Asset Resource
struct AssetResource: Identifiable {
    let id: String
    let resource: PHAssetResource
    
    init(resource: PHAssetResource) {
        self.id = UUID().uuidString
        self.resource = resource
    }
    
    var filename: String {
        resource.originalFilename
    }
    
    var uniformTypeIdentifier: String {
        resource.uniformTypeIdentifier
    }
    
    var isRAW: Bool {
        let uti = uniformTypeIdentifier.lowercased()
        return uti.contains("raw") || 
               uti.contains("dng") || 
               uti.contains("arw") || 
               uti.contains("cr2") || 
               uti.contains("cr3") ||
               uti.contains("nef") ||
               uti.contains("raf") ||
               uti.contains("orf") ||
               uti.contains("rw2")
    }
    
    var isPrimaryPhoto: Bool {
        resource.type == .photo || resource.type == .fullSizePhoto
    }
    
    var isVideo: Bool {
        resource.type == .video || resource.type == .fullSizeVideo
    }
    
    var resourceTypeString: String {
        if isRAW {
            return "raw"
        } else if isVideo {
            return "video"
        } else if isPrimaryPhoto {
            return "jpeg"
        } else {
            return "primary"
        }
    }
    
    var mimeType: String {
        let uti = uniformTypeIdentifier.lowercased()
        
        // Image formats
        if uti.contains("jpeg") || uti.contains("jpg") {
            return "image/jpeg"
        } else if uti.contains("png") {
            return "image/png"
        } else if uti.contains("heic") || uti.contains("heif") {
            return "image/heic"
        } else if uti.contains("gif") {
            return "image/gif"
        } else if uti.contains("webp") {
            return "image/webp"
        } else if uti.contains("tiff") {
            return "image/tiff"
        }
        
        // RAW formats
        if uti.contains("dng") {
            return "image/x-adobe-dng"
        } else if uti.contains("arw") {
            return "image/x-sony-arw"
        } else if uti.contains("cr2") {
            return "image/x-canon-cr2"
        } else if uti.contains("cr3") {
            return "image/x-canon-cr3"
        } else if uti.contains("nef") {
            return "image/x-nikon-nef"
        } else if uti.contains("raf") {
            return "image/x-fuji-raf"
        } else if uti.contains("orf") {
            return "image/x-olympus-orf"
        } else if uti.contains("rw2") {
            return "image/x-panasonic-rw2"
        } else if isRAW {
            return "image/x-raw"
        }
        
        // Video formats
        if uti.contains("mpeg4") || uti.contains("mp4") {
            return "video/mp4"
        } else if uti.contains("quicktime") || uti.contains("mov") {
            return "video/quicktime"
        } else if uti.contains("avi") {
            return "video/x-msvideo"
        }
        
        return "application/octet-stream"
    }
}

// MARK: - Media Type
enum MediaType {
    case photo
    case video
    case unknown
}
