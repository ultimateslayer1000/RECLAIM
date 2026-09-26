import Foundation

/// Everything a completed scan produced. Built incrementally — the UI renders
/// partial results as each phase lands rather than waiting for the whole scan.
struct ScanResults: Sendable, Equatable {
    var similarGroups: [SimilarGroup] = []
    var screenshots: [PhotoCandidate] = []
    /// Always sorted largest → smallest.
    var largeVideos: [PhotoCandidate] = []
    var contactGroups: [ContactDuplicateGroup] = []

    /// Set when Photos access was limited, so the UI can say so honestly.
    var photoAccessWasLimited: Bool = false
    var scannedAssetCount: Int = 0
    var completedAt: Date?

    var duplicateGroups: [SimilarGroup] {
        similarGroups.filter { $0.kind == .exactDuplicate }
    }

    var photosInGroups: Int {
        similarGroups.reduce(0) { $0 + $1.members.count }
    }

    /// Upper bound on what this category could free if the user accepted every
    /// suggestion. Distinct from *selected* bytes, which drives the Review screen.
    func potentialBytes(for category: CleanupCategory) -> Int64 {
        switch category {
        case .similarPhotos:
            return similarGroups.reduce(0) { $0 + $1.reclaimableBytes }
        case .screenshots:
            return screenshots.reduce(0) { $0 + $1.byteSize }
        case .largeVideos:
            return largeVideos.reduce(0) { $0 + $1.byteSize }
        case .duplicateContacts:
            return 0
        }
    }

    func itemCount(for category: CleanupCategory) -> Int {
        switch category {
        case .similarPhotos:     return similarGroups.reduce(0) { $0 + $1.removableMembers.count }
        case .screenshots:       return screenshots.count
        case .largeVideos:       return largeVideos.count
        case .duplicateContacts: return contactGroups.reduce(0) { $0 + max(0, $1.members.count - 1) }
        }
    }

    var isEmpty: Bool {
        similarGroups.isEmpty && screenshots.isEmpty
            && largeVideos.isEmpty && contactGroups.isEmpty
    }
}
