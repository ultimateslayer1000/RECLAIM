import XCTest
@testable import RECLAIM

final class StorageCalculationTests: XCTestCase {

    func testUsedCapacityIsTotalMinusAvailable() {
        let snapshot = StorageSnapshot(totalCapacity: 128_000_000_000,
                                       availableCapacity: 28_000_000_000,
                                       capturedAt: Date())
        XCTAssertEqual(snapshot.usedCapacity, 100_000_000_000)
    }

    func testUsedFractionIsClampedAndNeverNaN() {
        let unavailable = StorageSnapshot.unavailable
        XCTAssertEqual(unavailable.usedFraction, 0, "Must not divide by zero")
        XCTAssertFalse(unavailable.isAvailable)

        // Defensive: available > total should never happen, but must not break.
        let odd = StorageSnapshot(totalCapacity: 100, availableCapacity: 200,
                                  capturedAt: Date())
        XCTAssertEqual(odd.usedCapacity, 0)
        XCTAssertTrue((0...1).contains(odd.usedFraction))
    }

    func testReclaimedBytesReturnsPositiveDelta() {
        let before = StorageSnapshot(totalCapacity: 1000, availableCapacity: 100, capturedAt: Date())
        let after = StorageSnapshot(totalCapacity: 1000, availableCapacity: 340, capturedAt: Date())
        XCTAssertEqual(StorageService.reclaimedBytes(before: before, after: after), 240)
    }

    func testReclaimedBytesRejectsNonPositiveOrUnavailableReadings() {
        let before = StorageSnapshot(totalCapacity: 1000, availableCapacity: 400, capturedAt: Date())
        let after = StorageSnapshot(totalCapacity: 1000, availableCapacity: 300, capturedAt: Date())
        // Disk got fuller during the operation — the reading is not usable.
        XCTAssertNil(StorageService.reclaimedBytes(before: before, after: after))
        XCTAssertNil(StorageService.reclaimedBytes(before: .unavailable, after: after))
    }

    func testStorageServiceReadsTheRealVolume() {
        // Runs against the actual device/simulator volume — no mocking.
        let snapshot = StorageService().snapshot()
        XCTAssertTrue(snapshot.isAvailable, "A real volume should report capacity")
        XCTAssertGreaterThan(snapshot.totalCapacity, 0)
        XCTAssertLessThanOrEqual(snapshot.availableCapacity, snapshot.totalCapacity)
    }
}

final class ReclaimableCalculationTests: XCTestCase {

    private func candidate(_ id: String, bytes: Int64) -> PhotoCandidate {
        PhotoCandidate(id: id, pixelWidth: 100, pixelHeight: 100,
                       creationDate: Date(), byteSize: bytes)
    }

    func testGroupReclaimableExcludesTheSuggestedKeep() {
        let group = SimilarGroup(
            id: "g",
            members: [candidate("a", bytes: 300), candidate("b", bytes: 200),
                      candidate("c", bytes: 100)],
            suggestedKeepID: "a",
            kind: .similar
        )
        XCTAssertEqual(group.totalBytes, 600)
        XCTAssertEqual(group.reclaimableBytes, 300, "The keeper's bytes are not reclaimable")
        XCTAssertEqual(group.removableMembers.count, 2)
    }

    func testPotentialBytesPerCategory() {
        var results = ScanResults()
        results.similarGroups = [
            SimilarGroup(id: "g",
                         members: [candidate("a", bytes: 500), candidate("b", bytes: 500)],
                         suggestedKeepID: "a", kind: .exactDuplicate)
        ]
        results.screenshots = [candidate("s", bytes: 250)]
        results.largeVideos = [candidate("v", bytes: 9_000)]

        XCTAssertEqual(results.potentialBytes(for: .similarPhotos), 500)
        XCTAssertEqual(results.potentialBytes(for: .screenshots), 250)
        XCTAssertEqual(results.potentialBytes(for: .largeVideos), 9_000)
        XCTAssertEqual(results.potentialBytes(for: .duplicateContacts), 0)
    }

    func testItemCountsPerCategory() {
        var results = ScanResults()
        results.similarGroups = [
            SimilarGroup(id: "g",
                         members: [candidate("a", bytes: 1), candidate("b", bytes: 1),
                                   candidate("c", bytes: 1)],
                         suggestedKeepID: "a", kind: .similar)
        ]
        // Three members, one kept → two are removable.
        XCTAssertEqual(results.itemCount(for: .similarPhotos), 2)
    }

    func testImageSizeEstimateScalesWithPixelsAndIsConservative() {
        let photo = PhotoCandidate.estimatedImageBytes(width: 4032, height: 3024,
                                                       isScreenshot: false)
        let screenshot = PhotoCandidate.estimatedImageBytes(width: 4032, height: 3024,
                                                            isScreenshot: true)
        XCTAssertGreaterThan(photo, 0)
        XCTAssertLessThan(screenshot, photo, "Screenshots compress better than photos")
        XCTAssertEqual(PhotoCandidate.estimatedImageBytes(width: 0, height: 0,
                                                          isScreenshot: false), 0)
    }
}

final class KeepSuggestionTests: XCTestCase {

    private func candidate(_ id: String, width: Int = 1000, height: Int = 1000,
                           favorite: Bool = false, date: Date = Date()) -> PhotoCandidate {
        PhotoCandidate(id: id, pixelWidth: width, pixelHeight: height,
                       creationDate: date, isFavorite: favorite, byteSize: 1000)
    }

    private func analysis(_ id: String, sharpness: Double,
                          brightness: Double = 0.5) -> PhotoAnalysis {
        PhotoAnalysis(id: id, fingerprint: ImageFingerprint(bits: 0),
                      featurePrint: nil, sharpness: sharpness, brightness: brightness)
    }

    func testHigherResolutionWins() {
        let members = [candidate("small", width: 500, height: 500),
                       candidate("large", width: 4000, height: 3000)]
        let quality = ["small": analysis("small", sharpness: 100),
                       "large": analysis("large", sharpness: 100)]
        XCTAssertEqual(KeepSuggestionEngine.suggestKeep(from: members, quality: quality), "large")
    }

    func testSharperImageWinsAtEqualResolution() {
        let members = [candidate("blurry"), candidate("sharp")]
        let quality = ["blurry": analysis("blurry", sharpness: 10),
                       "sharp": analysis("sharp", sharpness: 900)]
        XCTAssertEqual(KeepSuggestionEngine.suggestKeep(from: members, quality: quality), "sharp")
    }

    func testFavoriteOutranksOtherSignals() {
        let members = [candidate("plain", width: 4000, height: 3000),
                       candidate("loved", width: 1000, height: 1000, favorite: true)]
        let quality = ["plain": analysis("plain", sharpness: 500),
                       "loved": analysis("loved", sharpness: 100)]
        XCTAssertEqual(KeepSuggestionEngine.suggestKeep(from: members, quality: quality), "loved")
    }

    func testBadlyExposedFrameIsDemoted() {
        let members = [candidate("dark"), candidate("balanced")]
        let quality = ["dark": analysis("dark", sharpness: 100, brightness: 0.02),
                       "balanced": analysis("balanced", sharpness: 100, brightness: 0.5)]
        XCTAssertEqual(KeepSuggestionEngine.suggestKeep(from: members, quality: quality), "balanced")
    }

    func testRecencyOnlyBreaksTiesAndDoesNotOverrideQuality() {
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        let members = [candidate("oldSharp", width: 4000, height: 3000, date: old),
                       candidate("newBlurry", width: 1000, height: 1000, date: new)]
        let quality = ["oldSharp": analysis("oldSharp", sharpness: 900),
                       "newBlurry": analysis("newBlurry", sharpness: 5)]
        XCTAssertEqual(KeepSuggestionEngine.suggestKeep(from: members, quality: quality),
                       "oldSharp", "Recency must not beat objective quality")
    }

    func testSuggestionIsDeterministicForIdenticalCandidates()  {
        let members = [candidate("b"), candidate("a")]
        let quality = ["a": analysis("a", sharpness: 100),
                       "b": analysis("b", sharpness: 100)]
        let first = KeepSuggestionEngine.suggestKeep(from: members, quality: quality)
        let second = KeepSuggestionEngine.suggestKeep(from: members, quality: quality)
        XCTAssertEqual(first, second)
    }

    func testEdgeCases() {
        XCTAssertEqual(KeepSuggestionEngine.suggestKeep(from: [], quality: [:]), "")
        let single = [candidate("only")]
        XCTAssertEqual(KeepSuggestionEngine.suggestKeep(from: single, quality: [:]), "only")
        // Missing quality data must not crash the scorer.
        let members = [candidate("a"), candidate("b")]
        XCTAssertFalse(KeepSuggestionEngine.suggestKeep(from: members, quality: [:]).isEmpty)
    }
}

final class FormatterTests: XCTestCase {

    func testDurationFormatting() {
        XCTAssertEqual(Format.duration(65), "1:05")
        XCTAssertEqual(Format.duration(3_723), "1:02:03")
        XCTAssertEqual(Format.duration(0), "0:00")
        XCTAssertEqual(Format.duration(-1), "--:--")
        XCTAssertEqual(Format.duration(.infinity), "--:--")
    }

    func testCountPluralisation() {
        XCTAssertEqual(Format.count(1, singular: "photo"), "1 photo")
        XCTAssertEqual(Format.count(3, singular: "photo"), "3 photos")
        XCTAssertEqual(Format.count(0, singular: "photo"), "0 photos")
    }

    func testByteFormattingHandlesZero() {
        XCTAssertEqual(Format.bytes(0), "0 KB")
        XCTAssertFalse(Format.bytes(5_000_000_000).isEmpty)
    }
}

final class ScanProgressTests: XCTestCase {

    func testOverallFractionIsMonotonicAcrossPhases() {
        var previous = -1.0
        for phase in ScanPhase.workingPhases {
            let progress = ScanProgress(phase: phase, phaseFraction: 0)
            XCTAssertGreaterThanOrEqual(progress.overallFraction, previous)
            previous = progress.overallFraction
        }
    }

    func testCompleteIsOneAndIdleIsZero() {
        XCTAssertEqual(ScanProgress(phase: .complete, phaseFraction: 1).overallFraction, 1)
        XCTAssertEqual(ScanProgress(phase: .idle, phaseFraction: 0).overallFraction, 0)
    }

    func testOverallFractionStaysInRange() {
        for phase in ScanPhase.allCases {
            for fraction in [0.0, 0.5, 1.0, 2.0] {
                let value = ScanProgress(phase: phase, phaseFraction: fraction).overallFraction
                XCTAssertTrue((0...1).contains(value), "\(phase) at \(fraction) → \(value)")
            }
        }
    }

    func testIsRunningReflectsLifecycle() {
        XCTAssertFalse(ScanProgress(phase: .idle).isRunning)
        XCTAssertFalse(ScanProgress(phase: .complete).isRunning)
        XCTAssertTrue(ScanProgress(phase: .fingerprinting).isRunning)
    }
}

final class CleanupOutcomeTests: XCTestCase {

    func testOutcomeWithFailuresIsNotReportedAsSuccess() {
        // TEST 4 from the brief: a partial failure must never read as success.
        var outcome = CleanupOutcome()
        outcome.photosRemoved = 9
        outcome.failures = [
            CleanupFailure(id: "x", itemDescription: "Photo",
                           reason: "Still present", domain: .photos)
        ]
        XCTAssertFalse(outcome.isCompleteSuccess)
        XCTAssertTrue(outcome.hasFailures)
        XCTAssertEqual(outcome.headline, "Partly cleaned")
        XCTAssertEqual(outcome.totalItemsRemoved, 9, "Reports 9, not the 10 requested")
    }

    func testCleanOutcomeIsSuccess() {
        var outcome = CleanupOutcome()
        outcome.photosRemoved = 10
        XCTAssertTrue(outcome.isCompleteSuccess)
        XCTAssertEqual(outcome.headline, "Space reclaimed.")
    }

    func testCancellationIsDistinctFromFailure() {
        var outcome = CleanupOutcome()
        outcome.wasCancelledByUser = true
        XCTAssertFalse(outcome.isCompleteSuccess)
        XCTAssertFalse(outcome.hasFailures)
        XCTAssertEqual(outcome.headline, "Cleanup cancelled")
        XCTAssertEqual(outcome.totalItemsRemoved, 0)
    }

    func testNothingRemovedHasItsOwnHeadline() {
        XCTAssertEqual(CleanupOutcome().headline, "Nothing was removed")
    }
}
