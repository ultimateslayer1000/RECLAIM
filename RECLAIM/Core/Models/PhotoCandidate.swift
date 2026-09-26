import Foundation
import Photos

/// A `Sendable` value snapshot of a `PHAsset`.
///
/// `PHAsset` is a non-`Sendable` reference type, so it must not cross actor
/// boundaries. The scan engine reads everything it needs once, up front, into
/// this struct; deletion later re-fetches the live `PHAsset` by
/// `localIdentifier`. That keeps the concurrency model sound and guarantees we
/// only ever delete an identifier the user actually approved.
struct PhotoCandidate: Identifiable, Hashable, Sendable {
    /// `PHAsset.localIdentifier`. Stable for the lifetime of the asset.
    let id: String
    let pixelWidth: Int
    let pixelHeight: Int
    let creationDate: Date?
    let modificationDate: Date?
    let isFavorite: Bool
    let mediaType: PHAssetMediaType
    let isScreenshot: Bool
    /// Seconds. Zero for stills.
    let duration: TimeInterval

    /// Byte size. Resolved lazily and may be an estimate — see `sizeAccuracy`.
    var byteSize: Int64
    var sizeAccuracy: SizeAccuracy

    enum SizeAccuracy: String, Sendable {
        /// Read from the asset's backing file via public URL resource values.
        case exact
        /// Derived from dimensions/bitrate because the file is not local.
        case estimated
        /// Could not be determined at all.
        case unknown
    }

    var pixelCount: Int { pixelWidth * pixelHeight }

    var megapixels: Double { Double(pixelCount) / 1_000_000 }

    init(asset: PHAsset) {
        self.id = asset.localIdentifier
        self.pixelWidth = asset.pixelWidth
        self.pixelHeight = asset.pixelHeight
        self.creationDate = asset.creationDate
        self.modificationDate = asset.modificationDate
        self.isFavorite = asset.isFavorite
        self.mediaType = asset.mediaType
        self.isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        self.duration = asset.duration
        // Stills get a dimension-based estimate immediately; videos are resolved
        // asynchronously by VideoService because it is far more expensive.
        if asset.mediaType == .image {
            self.byteSize = PhotoCandidate.estimatedImageBytes(
                width: asset.pixelWidth,
                height: asset.pixelHeight,
                isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)
            )
            self.sizeAccuracy = .estimated
        } else {
            self.byteSize = 0
            self.sizeAccuracy = .unknown
        }
    }

    /// Memberwise init used by tests and previews.
    init(id: String,
         pixelWidth: Int,
         pixelHeight: Int,
         creationDate: Date?,
         modificationDate: Date? = nil,
         isFavorite: Bool = false,
         mediaType: PHAssetMediaType = .image,
         isScreenshot: Bool = false,
         duration: TimeInterval = 0,
         byteSize: Int64 = 0,
         sizeAccuracy: SizeAccuracy = .estimated) {
        self.id = id
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.isFavorite = isFavorite
        self.mediaType = mediaType
        self.isScreenshot = isScreenshot
        self.duration = duration
        self.byteSize = byteSize
        self.sizeAccuracy = sizeAccuracy
    }

    /// Heuristic size for a still image.
    ///
    /// Reading the true size of every photo means touching every backing file,
    /// which is far too slow for a 10,000-photo library during a scan. HEIC runs
    /// roughly 0.30 bytes/pixel at Apple's default quality; PNG screenshots are
    /// much heavier per pixel but compress flat UI regions well. These constants
    /// are deliberately conservative so the dashboard under-promises.
    ///
    /// The Review screen labels totals as estimates for exactly this reason.
    static func estimatedImageBytes(width: Int, height: Int, isScreenshot: Bool) -> Int64 {
        let pixels = Double(width * height)
        guard pixels > 0 else { return 0 }
        let bytesPerPixel = isScreenshot ? 0.20 : 0.30
        return Int64(pixels * bytesPerPixel)
    }
}
