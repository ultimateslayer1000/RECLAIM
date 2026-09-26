import CoreGraphics
import Foundation

/// A 64-bit perceptual hash of an image's structure.
///
/// Content-based, not metadata-based: two files with different names, different
/// identifiers and different compression settings produce the same fingerprint
/// if they look the same. Re-saved, re-exported and re-compressed copies all
/// collapse together, which filename or `localIdentifier` grouping would miss.
struct ImageFingerprint: Hashable, Sendable {
    let bits: UInt64

    /// Number of differing bits. 0 means structurally identical.
    func hammingDistance(to other: ImageFingerprint) -> Int {
        (bits ^ other.bits).nonzeroBitCount
    }
}

/// Builds difference hashes (dHash).
///
/// The image is reduced to a 9×8 grayscale grid; each of the 64 output bits
/// records whether a pixel is brighter than its right-hand neighbour. Because
/// the hash encodes *relative* gradients rather than absolute colour, it is
/// naturally robust to exposure shifts, scaling and re-encoding — while still
/// being strict enough that genuinely different scenes rarely collide.
enum FingerprintGenerator {

    /// One wider than tall: 8 comparisons per row × 8 rows = 64 bits.
    static let gridWidth = 9
    static let gridHeight = 8

    /// Distance at or below which two images are treated as the *same* image.
    /// Chosen tight to avoid false positives — a wrongly merged "duplicate"
    /// risks the user deleting a photo they wanted.
    static let exactDuplicateThreshold = 2

    static func fingerprint(from cgImage: CGImage) -> ImageFingerprint? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: gridWidth,
            height: gridHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,                       // let CoreGraphics pick the stride
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight))

        guard let raw = context.data else { return nil }
        // CoreGraphics may pad rows, so never assume stride == width.
        let stride = context.bytesPerRow
        let pixels = raw.bindMemory(to: UInt8.self, capacity: stride * gridHeight)

        var bits: UInt64 = 0
        var index = 0
        for y in 0..<gridHeight {
            let row = y * stride
            for x in 0..<(gridWidth - 1) {
                if pixels[row + x] > pixels[row + x + 1] {
                    bits |= (UInt64(1) << UInt64(index))
                }
                index += 1
            }
        }
        return ImageFingerprint(bits: bits)
    }
}

/// Groups fingerprints into duplicate clusters.
///
/// Exact-hash matches are bucketed in O(n) via a dictionary. Only the remaining
/// unmatched singletons undergo pairwise Hamming comparison, and even then only
/// against other singletons — so the expensive O(n²) path operates on a small
/// residue rather than the whole library.
enum FingerprintClusterer {

    static func cluster(
        _ entries: [(id: String, fingerprint: ImageFingerprint)],
        threshold: Int = FingerprintGenerator.exactDuplicateThreshold
    ) -> [[String]] {
        guard entries.count > 1 else { return [] }

        // Pass 1 — exact bucket match.
        var buckets: [UInt64: [String]] = [:]
        for entry in entries {
            buckets[entry.fingerprint.bits, default: []].append(entry.id)
        }

        var clusters: [[String]] = []
        var singletons: [(id: String, fingerprint: ImageFingerprint)] = []

        for entry in entries {
            guard let bucket = buckets[entry.fingerprint.bits] else { continue }
            if bucket.count > 1 {
                if bucket.first == entry.id { clusters.append(bucket) }
            } else {
                singletons.append(entry)
            }
        }

        guard threshold > 0, singletons.count > 1 else { return clusters }

        // Pass 2 — near-match sweep over the unmatched residue only.
        var consumed = Set<String>()
        for i in 0..<singletons.count {
            let a = singletons[i]
            if consumed.contains(a.id) { continue }
            var group = [a.id]
            for j in (i + 1)..<singletons.count {
                let b = singletons[j]
                if consumed.contains(b.id) { continue }
                if a.fingerprint.hammingDistance(to: b.fingerprint) <= threshold {
                    group.append(b.id)
                    consumed.insert(b.id)
                }
            }
            if group.count > 1 {
                consumed.insert(a.id)
                clusters.append(group)
            }
        }
        return clusters
    }
}
