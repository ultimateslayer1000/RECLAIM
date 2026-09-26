import AVFoundation
import Foundation
import Photos

/// Resolves real byte sizes for video assets.
///
/// ## Why this is written the way it is
///
/// There is no public API that hands you a `PHAsset`'s file size. The widely
/// copied trick — `PHAssetResource.value(forKey: "fileSize")` — is KVC against
/// an undocumented property, i.e. a private API, and is explicitly out of bounds
/// for this project and a genuine App Store rejection risk.
///
/// The supported route used here, in order of preference:
///
/// 1. **Exact.** Ask for the `AVAsset`. When the video is local, Photos vends an
///    `AVURLAsset`, and its `url` answers `URLResourceValues.fileSize` — public,
///    exact, and effectively free because it is a stat, not a read.
/// 2. **Estimated.** If the asset is not URL-backed, derive
///    `estimatedDataRate × duration` from the video track.
/// 3. **Estimated (coarse).** If even the track is unavailable (iCloud-only,
///    nothing cached locally), fall back to duration × a conservative bitrate
///    and label the row as an estimate rather than guessing silently.
///
/// Throughout, `isNetworkAccessAllowed` stays **false**. Downloading full videos
/// from iCloud just to weigh them would burn the user's data and take minutes.
/// An unavailable asset is a state to display, not an error to crash on.
actor VideoService {

    /// Size at or above which a video earns the "Large" badge.
    static let largeThreshold: Int64 = 50_000_000  // 50 MB

    /// Conservative fallback bitrate (bits/sec) ≈ 8 Mbps, roughly 1080p30 H.264.
    private static let fallbackBitrate: Double = 8_000_000

    private let imageManager = PHImageManager.default()

    /// Measures every video, returning them sorted largest → smallest.
    func measure(
        videos: [PhotoCandidate],
        assetsByID: [String: PHAsset],
        onProgress: @escaping @Sendable (Int) -> Void
    ) async -> [PhotoCandidate] {
        guard !videos.isEmpty else { return [] }

        let manager = imageManager
        let boxes = videos.compactMap { candidate -> VideoBox? in
            guard let asset = assetsByID[candidate.id] else { return nil }
            return VideoBox(candidate: candidate, asset: asset)
        }

        // Videos are heavier per item than stills, so the concurrency cap is
        // lower — three simultaneous AVAsset resolutions is plenty.
        let measured = await BoundedConcurrency.map(
            boxes,
            limit: 3,
            transform: { box in
                await Self.measureOne(box: box, manager: manager)
            },
            onProgress: onProgress
        )

        return measured.sorted { $0.byteSize > $1.byteSize }
    }

    private static func measureOne(box: VideoBox, manager: PHImageManager) async -> PhotoCandidate? {
        var candidate = box.candidate

        let options = PHVideoRequestOptions()
        options.deliveryMode = .fastFormat
        // Never pull gigabytes down from iCloud just to read a size.
        options.isNetworkAccessAllowed = false

        guard let avAsset = await requestAVAsset(for: box.asset, manager: manager, options: options) else {
            candidate.byteSize = coarseEstimate(duration: candidate.duration)
            candidate.sizeAccuracy = candidate.duration > 0 ? .estimated : .unknown
            return candidate
        }

        // 1 — exact, via the backing file's resource values.
        if let urlAsset = avAsset as? AVURLAsset,
           let size = fileSize(at: urlAsset.url) {
            candidate.byteSize = size
            candidate.sizeAccuracy = .exact
            return candidate
        }

        // 2 — estimated, from the track's data rate.
        if let size = await bitrateEstimate(for: avAsset, duration: candidate.duration) {
            candidate.byteSize = size
            candidate.sizeAccuracy = .estimated
            return candidate
        }

        // 3 — coarse fallback.
        candidate.byteSize = coarseEstimate(duration: candidate.duration)
        candidate.sizeAccuracy = candidate.duration > 0 ? .estimated : .unknown
        return candidate
    }

    // MARK: - Size strategies

    private static func fileSize(at url: URL) -> Int64? {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
            if let size = values.fileSize, size > 0 { return Int64(size) }
            if let allocated = values.totalFileAllocatedSize, allocated > 0 { return Int64(allocated) }
            return nil
        } catch {
            return nil
        }
    }

    private static func bitrateEstimate(for asset: AVAsset, duration: TimeInterval) async -> Int64? {
        guard duration > 0 else { return nil }
        do {
            // Async loading, because the synchronous AVAsset accessors are
            // deprecated from iOS 16 and block whatever thread they land on.
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            var bitsPerSecond = 0.0
            for track in tracks + audioTracks {
                let rate = try await track.load(.estimatedDataRate)
                if rate.isFinite && rate > 0 { bitsPerSecond += Double(rate) }
            }
            guard bitsPerSecond > 0 else { return nil }
            return Int64(bitsPerSecond * duration / 8.0)
        } catch {
            return nil
        }
    }

    private static func coarseEstimate(duration: TimeInterval) -> Int64 {
        guard duration > 0 else { return 0 }
        return Int64(fallbackBitrate * duration / 8.0)
    }

    // MARK: - Bridging

    private static func requestAVAsset(
        for asset: PHAsset,
        manager: PHImageManager,
        options: PHVideoRequestOptions
    ) async -> AVAsset? {
        let box = AVResumeBox()
        return await withCheckedContinuation { (continuation: CheckedContinuation<AVAsset?, Never>) in
            manager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                if box.claim() { continuation.resume(returning: avAsset) }
            }
        }
    }
}

private struct VideoBox: @unchecked Sendable {
    let candidate: PhotoCandidate
    let asset: PHAsset
}

private final class AVResumeBox: @unchecked Sendable {
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
