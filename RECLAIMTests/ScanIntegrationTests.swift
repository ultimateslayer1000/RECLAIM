import Photos
import Vision
import XCTest
@testable import RECLAIM

/// End-to-end verification of the scan pipeline against a known photo library.
///
/// Unlike the pure-logic tests, this drives the *real* Photos framework and the
/// *real* Vision feature-print comparison. It is meaningful only when the
/// library has been seeded with the fixtures from `Scripts/make_test_photos.py`:
///
///     python3 Scripts/make_test_photos.py
///     xcrun simctl addmedia booted /tmp/reclaim-fixtures/*.png
///
/// The fixtures encode ground truth, so these are real pass/fail assertions
/// rather than "the scan ran without crashing":
///
///   dupA_0..2    3 byte-identical copies   -> must land in ONE group
///   dupB_0..1    2 byte-identical copies   -> must land in ONE group, not dupA's
///   similar_0..3 same scene, re-framed     -> should cluster (reported, not asserted)
///   unique_0..2  unrelated scenes          -> must NOT be grouped with anything
///
/// The test skips rather than fails when the fixtures are absent, because a
/// machine without them genuinely cannot answer the question.
@MainActor
final class ScanIntegrationTests: XCTestCase {

    private var fixtureNames: [String: String] = [:]   // localIdentifier -> filename

    // MARK: - Setup

    /// Requests access and maps every fixture asset's identifier to its
    /// original filename, so assertions can talk about "dupA_0" rather than
    /// an opaque UUID.
    private func prepare() async throws -> [PhotoCandidate] {
        // Deliberately *reads* the status instead of requesting it.
        //
        // Calling `requestAuthorization` here would present the system dialog,
        // and a unit test has no way to dismiss it — `addUIInterruptionMonitor`
        // exists only in UI tests — so the run would hang indefinitely rather
        // than fail. Skipping with an actionable message is the honest
        // behaviour: the grant is a one-time manual step.
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        try XCTSkipUnless(
            status == .authorized || status == .limited,
            """
            Photo library access not granted (status: \(status.rawValue)).
            Launch the app once and tap 'Allow photo access' → 'Allow Full Access',
            then re-run. A unit test cannot dismiss the system permission dialog.
            """
        )

        let library = PhotoLibraryService()
        let photos = library.fetchPhotos()

        let assets = library.assets(withIdentifiers: photos.map(\.id))
        for asset in assets {
            if let name = PHAssetResource.assetResources(for: asset).first?.originalFilename {
                fixtureNames[asset.localIdentifier] = name
            }
        }

        let fixtures = photos.filter { isFixture($0.id) }
        try XCTSkipUnless(
            fixtures.count >= 12,
            "Test fixtures not present in the photo library (found \(fixtures.count) of 12). "
                + "Run Scripts/make_test_photos.py and simctl addmedia first."
        )
        return photos
    }

    private func isFixture(_ id: String) -> Bool {
        guard let name = fixtureNames[id] else { return false }
        return name.hasPrefix("dup") || name.hasPrefix("similar") || name.hasPrefix("unique")
    }

    private func name(_ id: String) -> String { fixtureNames[id] ?? "?" }

    // MARK: - The scan

    private func runScan() async -> ScanResults {
        let engine = ScanEngine()
        return await engine.scan(
            photoAccess: .granted,
            // Contacts are deliberately excluded: the simulator address book is
            // empty, and this test is about the photo pipeline.
            contactsAccess: .denied,
            onProgress: { _ in },
            onPartial: { _ in }
        )
    }

    // MARK: - Tests

    /// Walks each stage of the analysis pipeline in isolation and reports where
    /// assets are lost. Diagnostic rather than behavioural: it pinpoints the
    /// failing stage instead of only asserting the end result is wrong.
    func testDiagnoseAnalysisPipeline() async throws {
        _ = try await prepare()
        let library = PhotoLibraryService()
        let assets = library.assetObjects(mediaType: .image)
        print("── stage 1 assetObjects: \(assets.count) assets")
        let first = try XCTUnwrap(assets.first, "no assets to analyse")

        let image = await ThumbnailProvider.shared.analysisImage(for: first)
        print("── stage 2 analysisImage: \(image == nil ? "NIL" : "ok, size \(image!.size)")")
        let unwrapped = try XCTUnwrap(image, "analysisImage returned nil")

        let cg = unwrapped.cgImage
        print("── stage 3 cgImage: \(cg == nil ? "NIL" : "ok, \(cg!.width)x\(cg!.height)")")
        let cgImage = try XCTUnwrap(cg, "UIImage had no backing CGImage")

        let fingerprint = FingerprintGenerator.fingerprint(from: cgImage)
        print("── stage 4 fingerprint: "
              + (fingerprint.map { String($0.bits, radix: 16) } ?? "NIL"))
        XCTAssertNotNil(fingerprint)

        let analyzer = PhotoAnalyzer()
        let analyses = await analyzer.analyze(
            assets: assets, includeFeaturePrints: true, onProgress: { _ in }
        )
        print("── stage 5 analyze: \(analyses.count) of \(assets.count) succeeded")
        print("──   with feature prints: \(analyses.filter { $0.featurePrint != nil }.count)")
        XCTAssertEqual(analyses.count, assets.count,
                       "Every asset should produce an analysis")
    }

    /// Surfaces the error `PhotoAnalyzer.featurePrint` swallows.
    ///
    /// Production code returns nil on failure so one bad asset cannot abort a
    /// whole scan — but that also hides *why* Vision failed. This reproduces
    /// the call with the error printed.
    func testDiagnoseVisionFeaturePrint() async throws {
        _ = try await prepare()
        let assets = PhotoLibraryService().assetObjects(mediaType: .image)
        let first = try XCTUnwrap(assets.first)
        // `XCTUnwrap` takes an autoclosure, which cannot contain `await`, so the
        // async call is hoisted out.
        let loaded = await ThumbnailProvider.shared.analysisImage(for: first)
        let image = try XCTUnwrap(loaded)
        let cg = try XCTUnwrap(image.cgImage)
        print("── input image: \(cg.width)x\(cg.height)")

        print("── supportedRevisions: \(VNGenerateImageFeaturePrintRequest.supportedRevisions)")
        print("── Revision1 = \(VNGenerateImageFeaturePrintRequestRevision1), "
              + "Revision2 = \(VNGenerateImageFeaturePrintRequestRevision2)")

        // Default revision, whatever the OS picks.
        let defaultRequest = VNGenerateImageFeaturePrintRequest()
        print("── default revision resolves to: \(defaultRequest.revision)")
        do {
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([defaultRequest])
            let observation = defaultRequest.results?.first as? VNFeaturePrintObservation
            print("── DEFAULT ok — results: \(defaultRequest.results?.count ?? -1), "
                  + "elementCount: \(observation?.elementCount ?? -1)")
        } catch {
            print("── DEFAULT FAILED: \(error)")
        }

        // Explicitly pinned revision 2 — what production currently requests.
        let pinned = VNGenerateImageFeaturePrintRequest()
        pinned.revision = VNGenerateImageFeaturePrintRequestRevision2
        do {
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([pinned])
            let observation = pinned.results?.first as? VNFeaturePrintObservation
            print("── REVISION2 ok — results: \(pinned.results?.count ?? -1), "
                  + "elementCount: \(observation?.elementCount ?? -1)")
        } catch {
            print("── REVISION2 FAILED: \(error)")
        }

        // And a distance computation between two different images, which is
        // what the similarity pass actually depends on.
        if assets.count > 1,
           let second = await ThumbnailProvider.shared.analysisImage(for: assets[1]),
           let cg2 = second.cgImage {
            let a = VNGenerateImageFeaturePrintRequest()
            let b = VNGenerateImageFeaturePrintRequest()
            do {
                try VNImageRequestHandler(cgImage: cg, options: [:]).perform([a])
                try VNImageRequestHandler(cgImage: cg2, options: [:]).perform([b])
                if let oa = a.results?.first as? VNFeaturePrintObservation,
                   let ob = b.results?.first as? VNFeaturePrintObservation {
                    var distance = Float(0)
                    try oa.computeDistance(&distance, to: ob)
                    print("── DISTANCE between asset 0 and 1: \(distance)")
                } else {
                    print("── DISTANCE: could not obtain both observations")
                }
            } catch {
                print("── DISTANCE FAILED: \(error)")
            }
        }
    }

    func testScanGroupsPlantedDuplicatesAndLeavesUniquesAlone() async throws {
        _ = try await prepare()
        let results = await runScan()

        // Report the full grouping — invaluable for threshold calibration.
        print("─── scan produced \(results.similarGroups.count) groups ───")
        for group in results.similarGroups {
            let members = group.members.map { name($0.id) }.sorted()
            print("  [\(group.kind.rawValue)] \(members.joined(separator: ", "))")
        }

        // Map each fixture filename to the group it landed in.
        var groupOf: [String: String] = [:]
        for group in results.similarGroups {
            for member in group.members where isFixture(member.id) {
                groupOf[name(member.id)] = group.id
            }
        }

        // --- The three identical copies must be together ---
        let aGroups = Set(["dupA_0.png", "dupA_1.png", "dupA_2.png"].compactMap { groupOf[$0] })
        XCTAssertEqual(aGroups.count, 1,
                       "The 3 identical dupA copies must land in exactly one group")

        // --- The two identical copies must be together ---
        let bGroups = Set(["dupB_0.png", "dupB_1.png"].compactMap { groupOf[$0] })
        XCTAssertEqual(bGroups.count, 1,
                       "The 2 identical dupB copies must land in exactly one group")

        // --- ...and the two sets must not be conflated ---
        if let a = aGroups.first, let b = bGroups.first {
            XCTAssertNotEqual(a, b, "dupA and dupB are different scenes and must not merge")
        }

        // --- The critical safety property: no false positives ---
        // A missed duplicate costs the user some space. A *wrong* grouping can
        // cost them a photo they wanted, so this is the assertion that matters.
        for unique in ["unique_0.png", "unique_1.png", "unique_2.png"] {
            XCTAssertNil(groupOf[unique],
                         "\(unique) is an unrelated scene and must not be grouped")
        }
    }

    func testExactDuplicatesAreClassifiedAsDuplicatesNotMerelySimilar() async throws {
        _ = try await prepare()
        let results = await runScan()

        let duplicateGroups = results.similarGroups.filter { $0.kind == .exactDuplicate }
        let namesInDuplicateGroups = Set(
            duplicateGroups.flatMap { $0.members.map { name($0.id) } }
        )

        // Byte-identical files must be caught by the perceptual-hash pass, not
        // left to the fuzzier Vision stage.
        XCTAssertTrue(namesInDuplicateGroups.contains("dupA_0.png"),
                      "Byte-identical copies should be classified as exact duplicates")
        XCTAssertTrue(namesInDuplicateGroups.contains("dupB_0.png"),
                      "Byte-identical copies should be classified as exact duplicates")
    }

    /// The four re-framed shots of one scene should cluster via Vision.
    ///
    /// Skips — rather than silently reporting — when the Vision runtime is
    /// unavailable. That is the documented Simulator behaviour ("Failed to
    /// create espresso context"), so this assertion can only be satisfied on a
    /// real device. An earlier version of this test merely *printed* the
    /// grouping, which let a total Vision failure pass as success.
    func testSimilarFramesClusterTogether() async throws {
        _ = try await prepare()
        let results = await runScan()

        try XCTSkipIf(
            results.similarDetectionUnavailable,
            "Vision feature prints unavailable on this device (Simulator limitation) — "
                + "similar-photo clustering must be verified on a real iPhone."
        )

        var groupOf: [String: String] = [:]
        for group in results.similarGroups {
            for member in group.members where isFixture(member.id) {
                groupOf[name(member.id)] = group.id
            }
        }

        let similarGroups = Set(
            (0..<4).compactMap { groupOf["similar_\($0).png"] }
        )
        XCTAssertEqual(similarGroups.count, 1,
                       "The four re-framed shots of one scene should form a single group")

        // Still the property that matters most: no false positives.
        for unique in ["unique_0.png", "unique_1.png", "unique_2.png"] {
            XCTAssertNil(groupOf[unique],
                         "\(unique) must not be pulled into a similar group")
        }
    }

    func testSuggestedKeepIsAlwaysAMemberAndNeverEveryPhoto() async throws {
        _ = try await prepare()
        let results = await runScan()
        try XCTSkipIf(results.similarGroups.isEmpty, "No groups formed")

        for group in results.similarGroups {
            XCTAssertTrue(
                group.members.contains { $0.id == group.suggestedKeepID },
                "The suggested keep must be a member of its own group"
            )
            XCTAssertEqual(
                group.removableMembers.count, group.members.count - 1,
                "Exactly one photo per group is kept"
            )
            XCTAssertFalse(
                group.removableMembers.contains { $0.id == group.suggestedKeepID },
                "The suggested keep must never appear in the removable set"
            )
        }
    }

    func testReclaimableBytesNeverExceedGroupTotal() async throws {
        _ = try await prepare()
        let results = await runScan()
        try XCTSkipIf(results.similarGroups.isEmpty, "No groups formed")

        for group in results.similarGroups {
            XCTAssertLessThan(
                group.reclaimableBytes, group.totalBytes,
                "Reclaimable must exclude the kept photo, so it is always less than the total"
            )
            XCTAssertGreaterThan(group.reclaimableBytes, 0)
        }
    }

    /// Records how long a full scan takes so regressions are visible.
    func testScanCompletesInReasonableTime() async throws {
        let photos = try await prepare()
        let start = Date()
        let results = await runScan()
        let elapsed = Date().timeIntervalSince(start)

        print("─── scanned \(photos.count) photos in \(String(format: "%.2f", elapsed))s ───")
        print("    groups: \(results.similarGroups.count), "
              + "screenshots: \(results.screenshots.count), "
              + "videos: \(results.largeVideos.count)")

        XCTAssertNotNil(results.completedAt, "A finished scan must stamp completedAt")
        // Generous: this is a smoke check against a pathological regression,
        // not a benchmark. Real performance work belongs on a device.
        XCTAssertLessThan(elapsed, 120, "Scan of a tiny library should not take minutes")
    }
}
