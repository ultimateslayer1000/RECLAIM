import Foundation

/// The verified result of a cleanup run.
///
/// Critically, these counts are **not** taken from the plan. After the deletion
/// request completes, `CleanupService` re-fetches the library and the contact
/// store and checks what actually disappeared. A request that "succeeded" but
/// left assets behind is reported as a partial failure, never as success.
struct CleanupOutcome: Sendable, Equatable {
    var photosRemoved: Int = 0
    var screenshotsRemoved: Int = 0
    var videosRemoved: Int = 0
    var contactsRemoved: Int = 0
    var contactsMerged: Int = 0

    /// Verified bytes freed, measured as the delta in available volume capacity
    /// across the operation. Falls back to the estimate when the volume reading
    /// is unusable (e.g. another process wrote to disk concurrently).
    var bytesReclaimed: Int64 = 0
    var bytesReclaimedIsEstimate: Bool = false

    var failures: [CleanupFailure] = []
    /// True when the user dismissed the system confirmation sheet.
    var wasCancelledByUser: Bool = false

    var totalItemsRemoved: Int {
        photosRemoved + screenshotsRemoved + videosRemoved + contactsRemoved
    }

    var hasFailures: Bool { !failures.isEmpty }

    /// Only true when every requested item is gone and nothing errored.
    var isCompleteSuccess: Bool { failures.isEmpty && !wasCancelledByUser }

    var headline: String {
        if wasCancelledByUser { return "Cleanup cancelled" }
        if totalItemsRemoved == 0 { return "Nothing was removed" }
        return hasFailures ? "Partly cleaned" : "Space reclaimed."
    }
}

/// A single item that could not be removed, with a reason worth showing.
struct CleanupFailure: Sendable, Equatable, Identifiable {
    let id: String
    let itemDescription: String
    let reason: String
    let domain: Domain

    enum Domain: String, Sendable {
        case photos, contacts

        var label: String {
            switch self {
            case .photos:   return "Photo library"
            case .contacts: return "Contacts"
            }
        }
    }
}

/// Errors that abort a cleanup before or during execution.
enum CleanupError: LocalizedError, Equatable {
    case photoLibraryUnavailable
    case contactsUnavailable
    case nothingSelected
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .photoLibraryUnavailable:
            return "RECLAIM doesn't have permission to change your photo library."
        case .contactsUnavailable:
            return "RECLAIM doesn't have permission to change your contacts."
        case .nothingSelected:
            return "Nothing was selected to clean."
        case .underlying(let message):
            return message
        }
    }
}
