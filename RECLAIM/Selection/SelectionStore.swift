import Foundation
import Observation

/// What the user decided to do with one duplicate-contact group.
enum ContactDecision: Equatable, Sendable {
    /// Leave the group alone. The default for every group.
    case ignore
    /// Delete these specific records, keeping the rest.
    case delete(ids: Set<String>)
    /// Fold the others into `keepID` using the previewed field set.
    case merge(instruction: ContactMergeInstruction)

    var isActionable: Bool {
        switch self {
        case .ignore: return false
        case .delete(let ids): return !ids.isEmpty
        case .merge: return true
        }
    }
}

/// The single source of truth for everything the user has marked for removal.
///
/// Owned by the app root and injected into every screen, so selections survive
/// tab switches and push/pop for the whole cleanup session — exactly once
/// requirement §17. It is deliberately *only* a record of intent: nothing here
/// deletes anything, and the only way out is `buildPlan()`, which the Review
/// screen turns into a `CleanupPlan` at the moment the user confirms.
@Observable
@MainActor
final class SelectionStore {

    // MARK: - Selections

    private(set) var similarPhotoIDs: Set<String> = []
    private(set) var screenshotIDs: Set<String> = []
    private(set) var videoIDs: Set<String> = []
    private(set) var contactDecisions: [String: ContactDecision] = [:]

    /// Byte sizes for everything selectable, refreshed from each scan.
    /// Kept separate from the selections so the two can be updated independently.
    private var byteIndex: [String: Int64] = [:]
    /// Display labels for the review screen, by identifier.
    private var labelIndex: [String: String] = [:]

    // MARK: - Derived totals

    var totalSelectedItems: Int {
        similarPhotoIDs.count + screenshotIDs.count + videoIDs.count + selectedContactCount
    }

    var selectedContactCount: Int {
        contactDecisions.values.reduce(0) { running, decision in
            switch decision {
            case .ignore: return running
            case .delete(let ids): return running + ids.count
            case .merge(let instruction): return running + instruction.absorbedIDs.count
            }
        }
    }

    var hasSelection: Bool { totalSelectedItems > 0 }

    /// Estimated bytes that would be freed by the current selection.
    /// Contacts contribute nothing — they occupy negligible space and claiming
    /// otherwise would be dishonest.
    var estimatedBytes: Int64 {
        let ids = similarPhotoIDs.union(screenshotIDs).union(videoIDs)
        return ids.reduce(0) { $0 + (byteIndex[$1] ?? 0) }
    }

    func selectedCount(for category: CleanupCategory) -> Int {
        switch category {
        case .similarPhotos:     return similarPhotoIDs.count
        case .screenshots:       return screenshotIDs.count
        case .largeVideos:       return videoIDs.count
        case .duplicateContacts: return selectedContactCount
        }
    }

    func selectedBytes(for category: CleanupCategory) -> Int64 {
        let ids: Set<String>
        switch category {
        case .similarPhotos:     ids = similarPhotoIDs
        case .screenshots:       ids = screenshotIDs
        case .largeVideos:       ids = videoIDs
        case .duplicateContacts: return 0
        }
        return ids.reduce(0) { $0 + (byteIndex[$1] ?? 0) }
    }

    func bytes(for id: String) -> Int64 { byteIndex[id] ?? 0 }
    func label(for id: String) -> String { labelIndex[id] ?? "Item" }

    // MARK: - Index maintenance

    /// Refreshes size/label lookups after a scan and drops any selection whose
    /// item no longer exists, so a stale identifier can never enter a plan.
    func reconcile(with results: ScanResults) {
        var bytes: [String: Int64] = [:]
        var labels: [String: String] = [:]

        for group in results.similarGroups {
            for member in group.members {
                bytes[member.id] = member.byteSize
                labels[member.id] = Format.date(member.creationDate)
            }
        }
        for shot in results.screenshots {
            bytes[shot.id] = shot.byteSize
            labels[shot.id] = Format.date(shot.creationDate)
        }
        for video in results.largeVideos {
            bytes[video.id] = video.byteSize
            labels[video.id] = Format.duration(video.duration)
        }
        byteIndex = bytes
        labelIndex = labels

        let validPhotos = Set(results.similarGroups.flatMap { $0.members.map(\.id) })
        let validShots = Set(results.screenshots.map(\.id))
        let validVideos = Set(results.largeVideos.map(\.id))
        let validGroups = Set(results.contactGroups.map(\.id))

        similarPhotoIDs.formIntersection(validPhotos)
        screenshotIDs.formIntersection(validShots)
        videoIDs.formIntersection(validVideos)
        contactDecisions = contactDecisions.filter { validGroups.contains($0.key) }
    }

    // MARK: - Mutations

    func isSelected(_ id: String, in category: CleanupCategory) -> Bool {
        switch category {
        case .similarPhotos:     return similarPhotoIDs.contains(id)
        case .screenshots:       return screenshotIDs.contains(id)
        case .largeVideos:       return videoIDs.contains(id)
        case .duplicateContacts: return false
        }
    }

    func toggle(_ id: String, in category: CleanupCategory) {
        switch category {
        case .similarPhotos:
            similarPhotoIDs.formSymmetricDifference([id])
        case .screenshots:
            screenshotIDs.formSymmetricDifference([id])
        case .largeVideos:
            videoIDs.formSymmetricDifference([id])
        case .duplicateContacts:
            break
        }
    }

    func setSelected(_ ids: some Sequence<String>, selected: Bool, in category: CleanupCategory) {
        let set = Set(ids)
        switch category {
        case .similarPhotos:
            selected ? similarPhotoIDs.formUnion(set) : similarPhotoIDs.subtract(set)
        case .screenshots:
            selected ? screenshotIDs.formUnion(set) : screenshotIDs.subtract(set)
        case .largeVideos:
            selected ? videoIDs.formUnion(set) : videoIDs.subtract(set)
        case .duplicateContacts:
            break
        }
    }

    /// "Select all except the suggested keep" for one group.
    func selectAllButSuggested(in group: SimilarGroup) {
        similarPhotoIDs.formUnion(group.removableMembers.map(\.id))
        // Guarantee the keeper is never in the deletion set, even if it was
        // individually selected earlier.
        similarPhotoIDs.remove(group.suggestedKeepID)
    }

    func clearSelection(in group: SimilarGroup) {
        similarPhotoIDs.subtract(group.members.map(\.id))
    }

    func decision(for groupID: String) -> ContactDecision {
        contactDecisions[groupID] ?? .ignore
    }

    func setDecision(_ decision: ContactDecision, for groupID: String) {
        if case .ignore = decision {
            contactDecisions.removeValue(forKey: groupID)
        } else {
            contactDecisions[groupID] = decision
        }
    }

    func clearAll() {
        similarPhotoIDs.removeAll()
        screenshotIDs.removeAll()
        videoIDs.removeAll()
        contactDecisions.removeAll()
    }

    // MARK: - Plan

    /// Freezes the current selection into the immutable plan the user confirms.
    /// This is the only bridge between selection and deletion.
    func buildPlan() -> CleanupPlan {
        var deletions: [String] = []
        var merges: [ContactMergeInstruction] = []

        for decision in contactDecisions.values {
            switch decision {
            case .ignore:
                continue
            case .delete(let ids):
                deletions.append(contentsOf: ids)
            case .merge(let instruction):
                merges.append(instruction)
            }
        }

        return CleanupPlan(
            similarPhotoIDs: Array(similarPhotoIDs),
            screenshotIDs: Array(screenshotIDs),
            videoIDs: Array(videoIDs),
            contactDeletionIDs: deletions,
            contactMerges: merges,
            estimatedBytes: estimatedBytes
        )
    }
}
