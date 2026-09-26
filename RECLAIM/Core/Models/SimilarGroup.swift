import Foundation

/// A cluster of near-identical photos.
///
/// Groups are never auto-selected for deletion. The engine only *suggests* which
/// frame to keep; the user decides.
struct SimilarGroup: Identifiable, Hashable, Sendable {
    let id: String
    /// Ordered newest-first for stable display.
    let members: [PhotoCandidate]
    /// The frame the heuristics recommend keeping. Always a member `id`.
    let suggestedKeepID: String
    /// How the cluster was formed.
    let kind: Kind

    enum Kind: String, Sendable {
        /// Fingerprints matched exactly or within 2 bits — effectively the same file.
        case exactDuplicate
        /// Vision feature-print distance under threshold — same scene, different frame.
        case similar

        var label: String {
            switch self {
            case .exactDuplicate: return "Duplicates"
            case .similar:        return "Similar"
            }
        }

        var explanation: String {
            switch self {
            case .exactDuplicate:
                return "These look like copies of the same image."
            case .similar:
                return "These look like the same scene shot more than once."
            }
        }
    }

    var suggestedKeep: PhotoCandidate? {
        members.first { $0.id == suggestedKeepID }
    }

    /// Everything except the suggested keep — the default "select all" target.
    var removableMembers: [PhotoCandidate] {
        members.filter { $0.id != suggestedKeepID }
    }

    /// Bytes recoverable if every member except the suggested keep is removed.
    var reclaimableBytes: Int64 {
        removableMembers.reduce(0) { $0 + $1.byteSize }
    }

    var totalBytes: Int64 {
        members.reduce(0) { $0 + $1.byteSize }
    }
}
