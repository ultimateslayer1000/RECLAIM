import Foundation
import Photos

/// Orchestrates the full SCAN stage.
///
/// Runs every phase off the main actor, reports progress continuously, and
/// publishes partial results as each phase lands so the dashboard fills in
/// progressively rather than blocking on the slowest step.
///
/// Cancellation is cooperative: `Task.checkCancellation` is polled between
/// phases and the bounded-concurrency helpers bail out mid-phase, so leaving the
/// app or pulling to re-scan stops the previous run promptly.
actor ScanEngine {

    private let photoLibrary: PhotoLibraryService
    private let contactService: ContactService
    private let duplicateEngine: ContactDuplicateEngine
    private let analyzer: PhotoAnalyzer
    private let similarity: PhotoSimilarityService
    private let videoService: VideoService

    init(photoLibrary: PhotoLibraryService = PhotoLibraryService(),
         contactService: ContactService = ContactService(),
         duplicateEngine: ContactDuplicateEngine = ContactDuplicateEngine(),
         analyzer: PhotoAnalyzer = PhotoAnalyzer(),
         similarity: PhotoSimilarityService = PhotoSimilarityService(),
         videoService: VideoService = VideoService()) {
        self.photoLibrary = photoLibrary
        self.contactService = contactService
        self.duplicateEngine = duplicateEngine
        self.analyzer = analyzer
        self.similarity = similarity
        self.videoService = videoService
    }

    /// Runs a scan.
    ///
    /// - Parameters:
    ///   - photoAccess: skips all photo phases entirely when unusable.
    ///   - contactsAccess: skips the contacts phase when unusable.
    ///   - onProgress: called frequently; hop to the main actor inside.
    ///   - onPartial: called once per completed phase with results so far.
    func scan(
        photoAccess: AccessState,
        contactsAccess: AccessState,
        onProgress: @escaping @Sendable (ScanProgress) -> Void,
        onPartial: @escaping @Sendable (ScanResults) -> Void
    ) async -> ScanResults {

        var results = ScanResults()
        results.photoAccessWasLimited = (photoAccess == .limited)
        var progress = ScanProgress()

        func report(_ phase: ScanPhase, _ fraction: Double, processed: Int = 0, total: Int = 0) {
            progress.phase = phase
            progress.phaseFraction = fraction
            progress.processedAssets = processed
            progress.totalAssets = total
            onProgress(progress)
        }

        if photoAccess.isUsable {
            // ---------- Phase 1: read the library ----------
            report(.readingLibrary, 0)
            let photoAssets = photoLibrary.assetObjects(mediaType: .image)
            let videoCandidates = photoLibrary.fetchVideos()
            let videoAssets = photoLibrary.assetObjects(mediaType: .video)
            let screenshots = photoLibrary.fetchScreenshots()

            let photoCandidates = photoAssets.map { PhotoCandidate(asset: $0) }
            let candidateIndex = Dictionary(
                photoCandidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
            )
            results.scannedAssetCount = photoAssets.count + videoAssets.count
            report(.readingLibrary, 1, processed: results.scannedAssetCount,
                   total: results.scannedAssetCount)

            // Screenshots are a pure metadata query, so they are available
            // immediately — publish them before the expensive work begins.
            results.screenshots = screenshots
            onPartial(results)

            guard !Task.isCancelled else { return finish(&results) }

            // ---------- Phase 2+3: fingerprint, then group ----------
            let total = photoAssets.count
            report(.fingerprinting, 0, processed: 0, total: total)

            let analyses = await analyzer.analyze(
                assets: photoAssets,
                includeFeaturePrints: true,
                onProgress: { done in
                    // Fingerprinting and Vision share one decode pass, so this
                    // single counter drives both reported phases.
                    var p = ScanProgress()
                    p.phase = .fingerprinting
                    p.phaseFraction = total > 0 ? Double(done) / Double(total) : 1
                    p.processedAssets = done
                    p.totalAssets = total
                    onProgress(p)
                }
            )

            guard !Task.isCancelled else { return finish(&results) }

            // If every asset analysed but not one produced a feature print, the
            // Vision runtime is unavailable rather than the library being free
            // of similar photos. Record it so the UI can say which it is.
            results.similarDetectionUnavailable =
                !analyses.isEmpty && analyses.allSatisfy { $0.featurePrint == nil }

            report(.findingSimilar, 0.3, processed: total, total: total)
            results.similarGroups = await similarity.buildGroups(
                analyses: analyses, candidates: candidateIndex
            )
            report(.findingSimilar, 1, processed: total, total: total)
            onPartial(results)

            // ---------- Phase 4: screenshots (already resolved) ----------
            report(.findingScreenshots, 1)

            guard !Task.isCancelled else { return finish(&results) }

            // ---------- Phase 5: video sizes ----------
            let videoIndex = Dictionary(
                videoAssets.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first }
            )
            let videoTotal = videoCandidates.count
            report(.measuringVideos, 0, processed: 0, total: videoTotal)
            results.largeVideos = await videoService.measure(
                videos: videoCandidates,
                assetsByID: videoIndex,
                onProgress: { done in
                    var p = ScanProgress()
                    p.phase = .measuringVideos
                    p.phaseFraction = videoTotal > 0 ? Double(done) / Double(videoTotal) : 1
                    p.processedAssets = done
                    p.totalAssets = videoTotal
                    onProgress(p)
                }
            )
            onPartial(results)
        }

        guard !Task.isCancelled else { return finish(&results) }

        // ---------- Phase 6: contacts ----------
        if contactsAccess.isUsable {
            report(.readingContacts, 0)
            do {
                let records = try contactService.fetchContacts()
                results.contactGroups = duplicateEngine.findDuplicates(in: records)
            } catch {
                // A contacts failure must never take the photo results down with
                // it — the category simply reports as unavailable.
                results.contactGroups = []
            }
            report(.readingContacts, 1)
        }

        return finish(&results)
    }

    private func finish(_ results: inout ScanResults) -> ScanResults {
        results.completedAt = Date()
        return results
    }
}
