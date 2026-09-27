import CoreGraphics
import XCTest
@testable import RECLAIM

final class FingerprintTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a grayscale test image from a pixel-generating closure.
    private func makeImage(width: Int = 64, height: Int = 64,
                           _ value: (Int, Int) -> UInt8) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let raw = context.data else { return nil }
        let stride = context.bytesPerRow
        let pixels = raw.bindMemory(to: UInt8.self, capacity: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * stride + x] = value(x, y)
            }
        }
        return context.makeImage()
    }

    // MARK: - Hamming distance

    func testIdenticalFingerprintsHaveZeroDistance() {
        let a = ImageFingerprint(bits: 0xDEADBEEFCAFEBABE)
        XCTAssertEqual(a.hammingDistance(to: a), 0)
    }

    func testHammingDistanceCountsDifferingBits() {
        let a = ImageFingerprint(bits: 0b0000)
        let b = ImageFingerprint(bits: 0b1011)
        XCTAssertEqual(a.hammingDistance(to: b), 3)
    }

    func testMaximallyDifferentFingerprints() {
        let a = ImageFingerprint(bits: 0)
        let b = ImageFingerprint(bits: UInt64.max)
        XCTAssertEqual(a.hammingDistance(to: b), 64)
    }

    // MARK: - Generation

    func testFingerprintIsDeterministic() throws {
        let image = try XCTUnwrap(makeImage { x, y in UInt8((x * 3 + y * 5) % 256) })
        let first = try XCTUnwrap(FingerprintGenerator.fingerprint(from: image))
        let second = try XCTUnwrap(FingerprintGenerator.fingerprint(from: image))
        XCTAssertEqual(first, second, "The same image must always hash identically")
    }

    func testFingerprintIsContentBasedNotIdentityBased() throws {
        // Two separately constructed images with identical content must match —
        // this is what makes detection content-based rather than metadata-based.
        let a = try XCTUnwrap(makeImage { x, _ in UInt8(x * 4 % 256) })
        let b = try XCTUnwrap(makeImage { x, _ in UInt8(x * 4 % 256) })
        XCTAssertEqual(FingerprintGenerator.fingerprint(from: a),
                       FingerprintGenerator.fingerprint(from: b))
    }

    func testFingerprintSurvivesRescaling() throws {
        // A resized copy of the same picture should still be recognised.
        //
        // The intermediate values are explicitly typed: left to infer them,
        // Swift's type checker times out choosing overloads for the mixed
        // integer arithmetic inside these closures.
        let large = try XCTUnwrap(makeImage(width: 256, height: 256) { x, y in
            let sx: Int = x / 4
            let sy: Int = y / 4
            let value: Int = (sx * 7 + sy * 11) % 256
            return UInt8(value)
        })
        let small = try XCTUnwrap(makeImage(width: 64, height: 64) { x, y in
            let value: Int = (x * 7 + y * 11) % 256
            return UInt8(value)
        })
        let a = try XCTUnwrap(FingerprintGenerator.fingerprint(from: large))
        let b = try XCTUnwrap(FingerprintGenerator.fingerprint(from: small))
        XCTAssertLessThanOrEqual(
            a.hammingDistance(to: b),
            FingerprintGenerator.exactDuplicateThreshold,
            "A rescaled copy should still register as the same image"
        )
    }

    func testDifferentImagesProduceDifferentFingerprints() throws {
        let gradient = try XCTUnwrap(makeImage { x, _ in UInt8(x * 4 % 256) })
        let inverse = try XCTUnwrap(makeImage { x, _ in
            let value: Int = 255 - (x * 4 % 256)
            return UInt8(value)
        })
        let a = try XCTUnwrap(FingerprintGenerator.fingerprint(from: gradient))
        let b = try XCTUnwrap(FingerprintGenerator.fingerprint(from: inverse))
        XCTAssertGreaterThan(a.hammingDistance(to: b),
                             FingerprintGenerator.exactDuplicateThreshold)
    }

    // MARK: - Clustering

    func testClustererGroupsIdenticalFingerprints() {
        let shared = ImageFingerprint(bits: 0xABCD)
        let clusters = FingerprintClusterer.cluster([
            ("a", shared),
            ("b", shared),
            ("c", ImageFingerprint(bits: 0x1234_5678_9ABC_DEF0))
        ])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0]), ["a", "b"])
    }

    func testClustererGroupsNearMatchesWithinThreshold() {
        // One bit apart — within the threshold, so they belong together.
        let clusters = FingerprintClusterer.cluster([
            ("a", ImageFingerprint(bits: 0b0000)),
            ("b", ImageFingerprint(bits: 0b0001))
        ])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0]), ["a", "b"])
    }

    func testClustererKeepsDistantFingerprintsApart() {
        let clusters = FingerprintClusterer.cluster([
            ("a", ImageFingerprint(bits: 0)),
            ("b", ImageFingerprint(bits: UInt64.max))
        ])
        XCTAssertTrue(clusters.isEmpty)
    }

    func testClustererHandlesEmptyAndSingleInput() {
        XCTAssertTrue(FingerprintClusterer.cluster([]).isEmpty)
        XCTAssertTrue(FingerprintClusterer.cluster([("a", ImageFingerprint(bits: 1))]).isEmpty)
    }

    func testClustererDoesNotPlaceAnItemInTwoClusters() {
        let clusters = FingerprintClusterer.cluster([
            ("a", ImageFingerprint(bits: 0b0000)),
            ("b", ImageFingerprint(bits: 0b0001)),
            ("c", ImageFingerprint(bits: 0b0011))
        ])
        let all = clusters.flatMap { $0 }
        XCTAssertEqual(all.count, Set(all).count, "No identifier may appear twice")
    }
}
