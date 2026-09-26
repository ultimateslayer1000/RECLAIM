import Foundation

/// The exact, frozen set of work the user approved on the Review screen.
///
/// This is the *only* input `CleanupService` accepts. Nothing can be deleted
/// that is not named here, and the plan is built solely from the user's
/// selection at the moment they tap the confirm button.
struct CleanupPlan: Sendable, Equatable {
    /// `PHAsset.localIdentifier` values, split by the surface they came from so
    /// the completion screen can report accurate per-category counts.
    let similarPhotoIDs: [String]
    let screenshotIDs: [String]
    let videoIDs: [String]
    /// Contact identifiers to delete outright.
    let contactDeletionIDs: [String]
    /// Merges the user explicitly confirmed.
    let contactMerges: [ContactMergeInstruction]
    /// Best-effort byte estimate shown to the user before confirming.
    let estimatedBytes: Int64

    /// Every photo-library identifier in the plan, de-duplicated.
    /// An asset could in principle appear in two surfaces; deleting twice would
    /// error, so the union is taken once here.
    var allAssetIDs: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in similarPhotoIDs + screenshotIDs + videoIDs where seen.insert(id).inserted {
            out.append(id)
        }
        return out
    }

    var totalPhotoCount: Int { similarPhotoIDs.count }
    var totalScreenshotCount: Int { screenshotIDs.count }
    var totalVideoCount: Int { videoIDs.count }
    var totalContactCount: Int {
        contactDeletionIDs.count + contactMerges.reduce(0) { $0 + $1.absorbedIDs.count }
    }

    var isEmpty: Bool {
        allAssetIDs.isEmpty && contactDeletionIDs.isEmpty && contactMerges.isEmpty
    }

    var touchesPhotoLibrary: Bool { !allAssetIDs.isEmpty }
    var touchesContacts: Bool { !contactDeletionIDs.isEmpty || !contactMerges.isEmpty }

    static let empty = CleanupPlan(
        similarPhotoIDs: [], screenshotIDs: [], videoIDs: [],
        contactDeletionIDs: [], contactMerges: [], estimatedBytes: 0
    )
}

/// One confirmed merge: fold `absorbedIDs` into `keepID`, then delete them.
struct ContactMergeInstruction: Sendable, Equatable, Identifiable {
    let id: String
    let keepID: String
    let absorbedIDs: [String]
    /// The exact field set the user was shown before approving.
    let resultingPhoneNumbers: [String]
    let resultingEmailAddresses: [String]
    let resultingGivenName: String
    let resultingFamilyName: String
    let resultingOrganization: String
}
