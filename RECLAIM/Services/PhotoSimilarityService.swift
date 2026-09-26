import Foundation

/// The two constants that decide what counts as "similar".
///
/// These are the most field-sensitive numbers in the app. They were chosen
/// conservatively — a false positive means a user might delete a photo they
/// wanted, which is far worse than missing a duplicate. Verify and tune on a
/// real device against a real library before shipping.
struct SimilarityTuning: Sendable {
    /// Vision feature-print distance below which two frames are "the same scene".
    /// Calibrated for `VNGenerateImageFeaturePrintRequestRevision2`, whose
    /// distances land roughly in 0...2. Lower = stricter.
    var featureDistanceThreshold: Float = 0.5

    /// Photos more than this far apart in time are never compared. Burst-like
    /// sequences and "three tries at the same shot" happen within seconds; this
    /// is what turns an O(n²) sweep into a near-linear one.
    var temporalWindow: TimeInterval = 180

    /// Hard cap on how many prior photos any one photo is compared against,
    /// protecting the scan when hundreds of assets share a timestamp.
    var maxComparisonsPerPhoto: Int = 40

    /// Groups larger than this are split — a 200-photo "group" is not reviewable.
    var maxGroupSize: Int = 24

    static let `default` = SimilarityTuning()
}

/// Builds duplicate and similar-photo groups from analysis output.
///
/// Two distinct passes, because the two things mean different things to a user:
/// exact duplicates are safe to trim aggressively, whereas "similar" needs a
/// considered choice between frames.
actor PhotoSimilarityService {

    private let tuning: SimilarityTuning

    init(tuning: SimilarityTuning = .default) {
        self.tuning = tuning
    }

    /// Produces every group, duplicates first.
    ///
    /// - Parameters:
    ///   - analyses: one entry per successfully analysed asset.
    ///   - candidates: metadata, keyed by identifier, for scoring and display.
    func buildGroups(
        analyses: [PhotoAnalysis],
        candidates: [String: PhotoCandidate]
    ) -> [SimilarGroup] {
        guard analyses.count > 1 else { return [] }

        var groups: [SimilarGroup] = []
        var claimed = Set<String>()

        // --- Pass 1: exact/near-exact duplicates via perceptual hash ---
        let hashEntries = analyses.map { (id: $0.id, fingerprint: $0.fingerprint) }
        for cluster in FingerprintClusterer.cluster(hashEntries) {
            let members = cluster.compactMap { candidates[$0] }
            guard members.count > 1 else { continue }
            for chunk in chunked(members) {
                guard chunk.count > 1 else { continue }
                groups.append(makeGroup(chunk, kind: .exactDuplicate, analyses: analyses))
                chunk.forEach { claimed.insert($0.id) }
            }
        }

        // --- Pass 2: Vision similarity over what remains ---
        let remaining = analyses
            .filter { !claimed.contains($0.id) && $0.featurePrint != nil }
            .sorted { lhs, rhs in
                let l = candidates[lhs.id]?.creationDate ?? .distantPast
                let r = candidates[rhs.id]?.creationDate ?? .distantPast
                return l < r
            }

        var visited = Set<String>()
        var index = 0
        while index < remaining.count {
            let seed = remaining[index]
            index += 1
            if visited.contains(seed.id) { continue }

            var cluster: [PhotoAnalysis] = [seed]
            visited.insert(seed.id)
            let seedDate = candidates[seed.id]?.creationDate ?? .distantPast

            var comparisons = 0
            var lookahead = index
            while lookahead < remaining.count,
                  comparisons < tuning.maxComparisonsPerPhoto,
                  cluster.count < tuning.maxGroupSize {
                let other = remaining[lookahead]
                lookahead += 1
                if visited.contains(other.id) { continue }

                let otherDate = candidates[other.id]?.creationDate ?? .distantPast
                // Sorted ascending, so once we exceed the window nothing further
                // can qualify and the inner sweep stops entirely.
                if otherDate.timeIntervalSince(seedDate) > tuning.temporalWindow { break }

                comparisons += 1
                guard let a = seed.featurePrint, let b = other.featurePrint,
                      let distance = a.distance(to: b) else { continue }

                if distance <= tuning.featureDistanceThreshold {
                    cluster.append(other)
                    visited.insert(other.id)
                }
            }

            guard cluster.count > 1 else { continue }
            let members = cluster.compactMap { candidates[$0.id] }
            guard members.count > 1 else { continue }
            groups.append(makeGroup(members, kind: .similar, analyses: analyses))
        }

        // Biggest wins first.
        return groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    // MARK: - Helpers

    private func chunked(_ members: [PhotoCandidate]) -> [[PhotoCandidate]] {
        guard members.count > tuning.maxGroupSize else { return [members] }
        return stride(from: 0, to: members.count, by: tuning.maxGroupSize).map {
            Array(members[$0..<min($0 + tuning.maxGroupSize, members.count)])
        }
    }

    private func makeGroup(
        _ members: [PhotoCandidate],
        kind: SimilarGroup.Kind,
        analyses: [PhotoAnalysis]
    ) -> SimilarGroup {
        let quality = Dictionary(
            analyses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let ordered = members.sorted {
            ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
        }
        let keep = KeepSuggestionEngine.suggestKeep(from: ordered, quality: quality)
        return SimilarGroup(
            id: ordered.map(\.id).sorted().joined(separator: "|").hashValue.description,
            members: ordered,
            suggestedKeepID: keep,
            kind: kind
        )
    }
}

/// Picks the frame to recommend keeping.
///
/// Explicitly a *suggestion*, surfaced in the UI as "Suggested keep" and always
/// overridable. There is no claim of AI certainty here — it is a transparent,
/// deterministic weighting of objective signals, which is also what makes it
/// unit-testable.
enum KeepSuggestionEngine {

    struct Weights {
        var resolution: Double = 1.0
        var sharpness: Double = 1.2
        var favorite: Double = 2.0
        var exposure: Double = 0.4
        var recency: Double = 0.15
        static let `default` = Weights()
    }

    static func suggestKeep(
        from members: [PhotoCandidate],
        quality: [String: PhotoAnalysis],
        weights: Weights = .default
    ) -> String {
        guard let first = members.first else { return "" }
        guard members.count > 1 else { return first.id }

        let maxPixels = Double(members.map(\.pixelCount).max() ?? 1)
        let sharpnessValues = members.compactMap { quality[$0.id]?.sharpness }
        let maxSharpness = max(sharpnessValues.max() ?? 0, 0.0001)
        let dates = members.compactMap(\.creationDate)
        let oldest = dates.min() ?? Date.distantPast
        let newest = dates.max() ?? Date.distantPast
        let span = max(newest.timeIntervalSince(oldest), 1)

        var bestID = first.id
        var bestScore = -Double.infinity

        for member in members {
            var score = 0.0

            // Resolution, normalised against the best in the group.
            if maxPixels > 0 {
                score += weights.resolution * (Double(member.pixelCount) / maxPixels)
            }
            // Sharpness — the anti-blur signal.
            if let sharpness = quality[member.id]?.sharpness {
                score += weights.sharpness * (sharpness / maxSharpness)
            }
            // An explicit user favourite outranks everything else.
            if member.isFavorite { score += weights.favorite }
            // Penalise frames that are nearly black or blown out.
            if let brightness = quality[member.id]?.brightness {
                let distanceFromIdeal = abs(brightness - 0.5) / 0.5
                score += weights.exposure * (1 - distanceFromIdeal)
            }
            // Recency only ever acts as a tie-breaker — its weight is far below
            // every objective quality signal, per the brief.
            if let date = member.creationDate {
                score += weights.recency * (date.timeIntervalSince(oldest) / span)
            }

            if score > bestScore {
                bestScore = score
                bestID = member.id
            } else if score == bestScore {
                // Deterministic tie-break so the suggestion never flickers
                // between launches.
                bestID = min(bestID, member.id)
            }
        }
        return bestID
    }
}
