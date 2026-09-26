import Foundation
import Photos

/// Reads the photo library into `Sendable` value types.
///
/// Every fetch respects whatever access the user granted: under limited access
/// `PHAsset.fetchAssets` transparently returns only the selected subset, so the
/// same code path serves both full and limited libraries. We never assume we
/// can see everything.
struct PhotoLibraryService: Sendable {

    // MARK: - Fetch options

    private func baseOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        // Newest first — matches how people think about their library, and means
        // the most relevant results stream in first.
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // Hidden assets are deliberately out of scope: surfacing them in a
        // cleanup list would leak content the user chose to conceal.
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        return options
    }

    // MARK: - Reads

    /// All still images available to the app.
    func fetchPhotos() -> [PhotoCandidate] {
        let options = baseOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return candidates(from: PHAsset.fetchAssets(with: options))
    }

    /// Screenshots, identified by the documented `.photoScreenshot` media
    /// subtype rather than by guessing at dimensions or filenames.
    func fetchScreenshots() -> [PhotoCandidate] {
        let options = baseOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d AND (mediaSubtypes & %d) != 0",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaSubtype.photoScreenshot.rawValue
        )
        return candidates(from: PHAsset.fetchAssets(with: options))
    }

    /// All videos. Sizes are resolved separately by `VideoService`.
    func fetchVideos() -> [PhotoCandidate] {
        let options = baseOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        return candidates(from: PHAsset.fetchAssets(with: options))
    }

    /// Total asset count, used to size progress reporting before work begins.
    func totalAssetCount() -> Int {
        PHAsset.fetchAssets(with: baseOptions()).count
    }

    /// Live `PHAsset` objects, needed wherever an image must actually be
    /// requested (analysis, thumbnails). Kept separate from the `PhotoCandidate`
    /// fetches so `Sendable` value types remain the default currency of the app
    /// and asset references stay confined to one isolation domain.
    func assetObjects(mediaType: PHAssetMediaType, screenshotsOnly: Bool = false) -> [PHAsset] {
        let options = baseOptions()
        if screenshotsOnly {
            options.predicate = NSPredicate(
                format: "mediaType == %d AND (mediaSubtypes & %d) != 0",
                mediaType.rawValue,
                PHAssetMediaSubtype.photoScreenshot.rawValue
            )
        } else {
            options.predicate = NSPredicate(format: "mediaType == %d", mediaType.rawValue)
        }
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    // MARK: - Identifier round-trip

    /// Resolves identifiers back to live assets at deletion time.
    ///
    /// Deliberately re-fetched rather than retained: an asset may have been
    /// removed by another app or by the user in Photos since the scan, and a
    /// stale `PHAsset` reference would make the delete fail opaquely.
    func assets(withIdentifiers ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// Which of `ids` still exist. Used after a deletion to verify what actually
    /// went away instead of trusting the request's success flag.
    func survivingIdentifiers(from ids: [String]) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var surviving = Set<String>()
        result.enumerateObjects { asset, _, _ in surviving.insert(asset.localIdentifier) }
        return surviving
    }

    // MARK: - Helpers

    private func candidates(from result: PHFetchResult<PHAsset>) -> [PhotoCandidate] {
        var out: [PhotoCandidate] = []
        out.reserveCapacity(result.count)
        // autoreleasepool keeps the peak footprint flat while walking a large
        // fetch result — without it, enumerating 10k assets accumulates a large
        // pool of temporary objects before any drain.
        autoreleasepool {
            result.enumerateObjects { asset, _, _ in
                out.append(PhotoCandidate(asset: asset))
            }
        }
        return out
    }
}
