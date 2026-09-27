import Foundation
import Photos
import UIKit

/// Central source for every image RECLAIM displays or analyses.
///
/// Two hard rules, both from the performance brief:
/// 1. Full-resolution originals are never requested. Analysis uses a 128pt
///    thumbnail; the grid uses a cell-sized one; even the full-screen preview
///    caps at screen scale.
/// 2. Requests are bounded and cached — `PHCachingImageManager` recycles decoded
///    bitmaps, and the cache window is explicitly reset when a screen goes away.
///
/// `@unchecked Sendable` is justified: the only stored state is
/// `PHCachingImageManager`, which Apple documents as safe to call from any
/// thread, plus an `NSCache`, which is itself thread-safe.
final class ThumbnailProvider: @unchecked Sendable {

    static let shared = ThumbnailProvider()

    /// Size used for fingerprinting and Vision work. Small on purpose: dHash
    /// reduces to 9×8 anyway, and Vision's feature print is scale-invariant, so
    /// anything larger is wasted decode time and memory.
    static let analysisSize = CGSize(width: 128, height: 128)

    private let manager = PHCachingImageManager()
    private let analysisCache = NSCache<NSString, UIImage>()

    private init() {
        manager.allowsCachingHighQualityImages = false
        // Bounded by count, not bytes: 128pt thumbs are tiny and predictable.
        analysisCache.countLimit = 400
    }

    // MARK: - Display

    /// Thumbnail for grid and row display.
    func thumbnail(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        let options = PHImageRequestOptions()
        // Deliberately not `.opportunistic`. That mode delivers a degraded
        // placeholder first and a final image later, but nothing guarantees the
        // second callback arrives — and since a continuation resumes exactly
        // once, a missing final would strand the task permanently. One
        // deterministic callback is worth more than a slightly faster first
        // paint; `PHCachingImageManager` plus the prefetch window covers scroll
        // performance instead.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isSynchronous = false
        // Grid scrolling must never block on a network fetch. iCloud-only
        // assets fall back to the placeholder cell rather than downloading.
        options.isNetworkAccessAllowed = false
        return await requestImage(asset: asset, size: targetSize, options: options)
    }

    /// Larger image for the full-screen preview. Network is permitted here
    /// because the user explicitly asked to inspect this one photo.
    func previewImage(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true
        return await requestImage(asset: asset, size: targetSize, options: options)
    }

    // MARK: - Analysis

    /// Small thumbnail for fingerprinting / Vision, cached by identifier.
    func analysisImage(for asset: PHAsset) async -> UIImage? {
        let key = asset.localIdentifier as NSString
        if let cached = analysisCache.object(forKey: key) { return cached }

        let options = PHImageRequestOptions()
        // `.highQualityFormat`, NOT `.fastFormat`.
        //
        // `.fastFormat` does not mean "decode quickly" — it means "return only a
        // representation that already exists". Assets with no cached rendition
        // (anything recently imported) fail outright with PHPhotosError 3303,
        // "No resource found matching image request spec". That silently
        // emptied the entire analysis stage.
        //
        // `.highQualityFormat` also delivers exactly one, non-degraded result,
        // which matters for correctness as much as availability: hashing some
        // assets from a degraded rendition and others from the full one would
        // produce different fingerprints for identical images.
        //
        // The cost is bounded because the target size is only 128pt and
        // PHCachingImageManager reuses the decode.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isSynchronous = false
        // Still false: an iCloud-only asset is skipped rather than downloaded.
        options.isNetworkAccessAllowed = false

        guard let image = await requestImage(
            asset: asset, size: Self.analysisSize, options: options
        ) else { return nil }

        analysisCache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Caching window

    /// Warms the cache for rows about to scroll into view.
    func startCaching(assets: [PHAsset], targetSize: CGSize) {
        guard !assets.isEmpty else { return }
        manager.startCachingImages(for: assets, targetSize: targetSize,
                                   contentMode: .aspectFill, options: nil)
    }

    func stopCaching(assets: [PHAsset], targetSize: CGSize) {
        guard !assets.isEmpty else { return }
        manager.stopCachingImages(for: assets, targetSize: targetSize,
                                  contentMode: .aspectFill, options: nil)
    }

    /// Called when a screen disappears so memory does not creep across the app.
    func resetCaches() {
        manager.stopCachingImagesForAllAssets()
        analysisCache.removeAllObjects()
    }

    // MARK: - Bridging PHImageManager to async/await

    private func requestImage(
        asset: PHAsset,
        size: CGSize,
        options: PHImageRequestOptions
    ) async -> UIImage? {
        // PHImageManager can invoke its handler more than once (a degraded
        // placeholder followed by the final image). A continuation may only be
        // resumed once, so the first non-degraded result wins and everything
        // afterwards is ignored.
        let box = ResumeBox()
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            manager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let failed = info?[PHImageErrorKey] != nil

                // Keep waiting for the real image unless this is terminal.
                if isDegraded && !isCancelled && !failed { return }
                if box.claim() { continuation.resume(returning: image) }
            }
        }
    }
}

/// Tiny lock-guarded latch ensuring a continuation resumes exactly once.
private final class ResumeBox: @unchecked Sendable {
    private var used = false
    private let lock = NSLock()

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
