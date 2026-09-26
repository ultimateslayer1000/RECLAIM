import CoreGraphics
import Foundation
import Photos
import UIKit
import Vision

/// An immutable wrapper making a Vision feature print safe to pass between
/// concurrency domains.
///
/// `VNFeaturePrintObservation` is a reference type Apple has not marked
/// `Sendable`, but it is fully immutable once produced and its `computeDistance`
/// is a pure read. Wrapping it is therefore sound — and preferable to
/// re-deriving distances from the raw `data` buffer, which would mean guessing
/// at the metric Vision actually uses.
struct FeaturePrint: @unchecked Sendable {
    let observation: VNFeaturePrintObservation

    func distance(to other: FeaturePrint) -> Float? {
        var distance = Float(0)
        do {
            try observation.computeDistance(&distance, to: other.observation)
            return distance
        } catch {
            return nil
        }
    }
}

/// Everything derived from a single decode of one asset's thumbnail.
///
/// The thumbnail is fetched exactly once and all three derivations run off it.
/// Decoding is by far the dominant cost in the scan, so doing it once instead of
/// three times is the single biggest performance decision in the app.
struct PhotoAnalysis: Sendable {
    let id: String
    let fingerprint: ImageFingerprint
    let featurePrint: FeaturePrint?
    /// Laplacian variance — higher means more edge energy, i.e. sharper.
    let sharpness: Double
    /// Mean luminance, 0...1. Used to demote badly under/over-exposed frames.
    let brightness: Double
}

/// Produces `PhotoAnalysis` values with bounded concurrency.
actor PhotoAnalyzer {

    private let thumbnails: ThumbnailProvider

    init(thumbnails: ThumbnailProvider = .shared) {
        self.thumbnails = thumbnails
    }

    /// Analyses `assets`, reporting completion counts as it goes.
    ///
    /// `includeFeaturePrints` is false for the screenshot/video passes, which
    /// only need the cheap fingerprint — Vision is comfortably the most
    /// expensive step and is skipped wherever it adds nothing.
    func analyze(
        assets: [PHAsset],
        includeFeaturePrints: Bool,
        onProgress: @escaping @Sendable (Int) -> Void
    ) async -> [PhotoAnalysis] {
        let provider = thumbnails
        return await BoundedConcurrency.map(
            assets.map { AssetBox(asset: $0) },
            transform: { box in
                await Self.analyzeOne(
                    box.asset,
                    provider: provider,
                    includeFeaturePrints: includeFeaturePrints
                )
            },
            onProgress: onProgress
        )
    }

    private static func analyzeOne(
        _ asset: PHAsset,
        provider: ThumbnailProvider,
        includeFeaturePrints: Bool
    ) async -> PhotoAnalysis? {
        guard let image = await provider.analysisImage(for: asset),
              let cgImage = image.cgImage,
              let fingerprint = FingerprintGenerator.fingerprint(from: cgImage)
        else { return nil }

        // autoreleasepool bounds the CoreGraphics scratch buffers created per
        // asset; without it they accumulate until the task group drains.
        let quality = autoreleasepool { ImageQuality.measure(cgImage) }

        var print: FeaturePrint?
        if includeFeaturePrints {
            print = Self.featurePrint(for: cgImage)
        }

        return PhotoAnalysis(
            id: asset.localIdentifier,
            fingerprint: fingerprint,
            featurePrint: print,
            sharpness: quality.sharpness,
            brightness: quality.brightness
        )
    }

    private static func featurePrint(for cgImage: CGImage) -> FeaturePrint? {
        let request = VNGenerateImageFeaturePrintRequest()
        // Pinned explicitly so a future OS revision cannot silently change the
        // distance scale that `SimilarityTuning.featureDistanceThreshold` is
        // calibrated against. No availability guard is needed: revision 2 and
        // the app's deployment target are both iOS 17.
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first as? VNFeaturePrintObservation else {
                return nil
            }
            return FeaturePrint(observation: observation)
        } catch {
            return nil
        }
    }
}

/// `PHAsset` is not `Sendable`; boxing it keeps the bounded-concurrency helper
/// generic without forcing an unsafe conformance on Apple's type itself.
private struct AssetBox: @unchecked Sendable {
    let asset: PHAsset
}

/// Cheap no-Vision image quality metrics computed on the grayscale thumbnail.
enum ImageQuality {

    struct Metrics {
        let sharpness: Double
        let brightness: Double
    }

    /// Downsamples to a fixed 64×64 grid, then computes the variance of a
    /// 4-neighbour Laplacian. Blurred frames have little high-frequency energy
    /// and therefore a low variance, which is what lets the keep-suggestion
    /// heuristic prefer the crisp shot in a burst.
    static func measure(_ cgImage: CGImage, side: Int = 64) -> Metrics {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return Metrics(sharpness: 0, brightness: 0.5)
        }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let raw = context.data else {
            return Metrics(sharpness: 0, brightness: 0.5)
        }
        let stride = context.bytesPerRow
        let pixels = raw.bindMemory(to: UInt8.self, capacity: stride * side)

        var sum = 0.0
        var laplacians: [Double] = []
        laplacians.reserveCapacity((side - 2) * (side - 2))

        for y in 0..<side {
            for x in 0..<side {
                sum += Double(pixels[y * stride + x])
            }
        }
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let centre = Double(pixels[y * stride + x])
                let up = Double(pixels[(y - 1) * stride + x])
                let down = Double(pixels[(y + 1) * stride + x])
                let left = Double(pixels[y * stride + x - 1])
                let right = Double(pixels[y * stride + x + 1])
                laplacians.append(up + down + left + right - 4 * centre)
            }
        }

        let brightness = sum / Double(side * side) / 255.0
        guard !laplacians.isEmpty else {
            return Metrics(sharpness: 0, brightness: brightness)
        }
        let mean = laplacians.reduce(0, +) / Double(laplacians.count)
        let variance = laplacians.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(laplacians.count)
        return Metrics(sharpness: variance, brightness: brightness)
    }
}
