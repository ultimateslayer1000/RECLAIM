import Contacts
import Foundation
import Photos

/// Executes an approved `CleanupPlan` — and nothing else.
///
/// ## Safety model
///
/// * The only entry point takes a `CleanupPlan`, which can only be produced by
///   the Review screen's confirm action. There is no code path from a selection
///   tap to a deletion.
/// * Identifiers are re-resolved to live objects at execution time, so a stale
///   reference can never cause the wrong item to be removed.
/// * **Success is verified, never assumed.** After the write, the library and
///   the contact store are re-read. Anything still present is reported as a
///   failure. A request that returns `success == true` but leaves items behind
///   is reported honestly as a partial failure.
/// * Photo deletion is issued as a single `performChanges` so the user sees one
///   system confirmation rather than one per asset. Cancelling that sheet is
///   detected explicitly and reported as a cancellation, not an error.
actor CleanupService {

    private let photoLibrary: PhotoLibraryService
    private let contacts: ContactService
    private let storage: StorageService

    init(photoLibrary: PhotoLibraryService = PhotoLibraryService(),
         contacts: ContactService = ContactService(),
         storage: StorageService = StorageService()) {
        self.photoLibrary = photoLibrary
        self.contacts = contacts
        self.storage = storage
    }

    func execute(plan: CleanupPlan) async -> CleanupOutcome {
        var outcome = CleanupOutcome()
        guard !plan.isEmpty else { return outcome }

        let before = storage.snapshot()

        if plan.touchesPhotoLibrary {
            await deletePhotos(plan: plan, into: &outcome)
        }
        if plan.touchesContacts && !outcome.wasCancelledByUser {
            await updateContacts(plan: plan, into: &outcome)
        }

        // Prefer a measured delta; fall back to the estimate when the reading is
        // not trustworthy. Never present an estimate as if it were measured.
        let after = storage.snapshot()
        if let measured = StorageService.reclaimedBytes(before: before, after: after),
           measured < plan.estimatedBytes * 4 {
            outcome.bytesReclaimed = measured
            outcome.bytesReclaimedIsEstimate = false
        } else {
            outcome.bytesReclaimed = proportionalEstimate(plan: plan, outcome: outcome)
            outcome.bytesReclaimedIsEstimate = true
        }
        return outcome
    }

    // MARK: - Photos

    private func deletePhotos(plan: CleanupPlan, into outcome: inout CleanupOutcome) async {
        let requestedIDs = plan.allAssetIDs
        let assets = photoLibrary.assets(withIdentifiers: requestedIDs)

        // Identifiers with no live asset are already gone — not a failure, but
        // they must not be counted as something this run removed.
        let resolvedIDs = Set(assets.map(\.localIdentifier))

        guard !assets.isEmpty else {
            recordPhotoOutcome(plan: plan, removedIDs: [], into: &outcome)
            return
        }

        var requestError: Error?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
        } catch {
            requestError = error
        }

        if let requestError, Self.isUserCancellation(requestError) {
            outcome.wasCancelledByUser = true
            return
        }

        // Verification pass — the source of truth for what actually happened.
        let surviving = photoLibrary.survivingIdentifiers(from: Array(resolvedIDs))
        let removedIDs = resolvedIDs.subtracting(surviving)

        recordPhotoOutcome(plan: plan, removedIDs: removedIDs, into: &outcome)

        for id in surviving {
            outcome.failures.append(
                CleanupFailure(
                    id: id,
                    itemDescription: "Photo or video",
                    reason: requestError?.localizedDescription
                        ?? "The photo library reported success but this item is still present.",
                    domain: .photos
                )
            )
        }
    }

    /// Attributes removals back to the category they were selected from, so the
    /// completion screen can say "18 photos, 6 screenshots, 3 videos" truthfully.
    private func recordPhotoOutcome(
        plan: CleanupPlan,
        removedIDs: Set<String>,
        into outcome: inout CleanupOutcome
    ) {
        outcome.photosRemoved = plan.similarPhotoIDs.filter { removedIDs.contains($0) }.count
        outcome.screenshotsRemoved = plan.screenshotIDs.filter { removedIDs.contains($0) }.count
        outcome.videosRemoved = plan.videoIDs.filter { removedIDs.contains($0) }.count
    }

    /// Domain and code for `PHPhotosErrorUserCancelled`.
    ///
    /// Matched against the raw `NSError` rather than the Swift-bridged
    /// `PHPhotosError` enum: the bridged spelling has shifted between SDK
    /// versions, whereas the domain string and numeric code are stable public
    /// API and compile against every supported SDK.
    private static let photosErrorDomain = "PHPhotosErrorDomain"
    private static let userCancelledCode = 3072

    /// The system reports this when the user declines the deletion
    /// confirmation sheet. A normal outcome, not a bug — and importantly not a
    /// failure, so it is surfaced as "cancelled" rather than "couldn't delete".
    private static func isUserCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == photosErrorDomain && nsError.code == userCancelledCode
    }

    // MARK: - Contacts

    private func updateContacts(plan: CleanupPlan, into outcome: inout CleanupOutcome) async {
        let store = CNContactStore()

        // --- Merges first, so a merge's absorbed records are folded in before
        //     any outright deletion touches the same group. ---
        for merge in plan.contactMerges {
            do {
                try applyMerge(merge, store: store)
                outcome.contactsMerged += 1
            } catch {
                outcome.failures.append(
                    CleanupFailure(
                        id: merge.id,
                        itemDescription: "Merge into \(merge.resultingGivenName) \(merge.resultingFamilyName)"
                            .trimmingCharacters(in: .whitespaces),
                        reason: error.localizedDescription,
                        domain: .contacts
                    )
                )
                // A failed merge must not delete the absorbed records.
                continue
            }

            for absorbedID in merge.absorbedIDs {
                deleteContact(id: absorbedID, store: store, into: &outcome)
            }
        }

        // --- Straight deletions. Each gets its own save request so one failure
        //     cannot take the rest down with it. ---
        for id in plan.contactDeletionIDs {
            deleteContact(id: id, store: store, into: &outcome)
        }

        // Verify: anything still present that we tried to remove is a failure.
        let attempted = plan.contactDeletionIDs + plan.contactMerges.flatMap(\.absorbedIDs)
        guard !attempted.isEmpty else { return }
        let stillThere = contacts.existingIdentifiers(from: attempted)
        for id in stillThere where !outcome.failures.contains(where: { $0.id == id }) {
            outcome.failures.append(
                CleanupFailure(
                    id: id,
                    itemDescription: "Contact",
                    reason: "The contact store reported success but this contact still exists.",
                    domain: .contacts
                )
            )
            outcome.contactsRemoved = max(0, outcome.contactsRemoved - 1)
        }
    }

    private func applyMerge(_ merge: ContactMergeInstruction, store: CNContactStore) throws {
        guard let keeper = try contacts.mutableContact(id: merge.keepID) else {
            throw CleanupError.underlying("The contact to keep could not be found.")
        }

        // Write back exactly the field set the user was shown on the Review
        // screen — not a freshly recomputed union, which could differ if the
        // address book changed underneath us.
        keeper.givenName = merge.resultingGivenName
        keeper.familyName = merge.resultingFamilyName
        keeper.organizationName = merge.resultingOrganization
        keeper.phoneNumbers = merge.resultingPhoneNumbers.map {
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: $0))
        }
        keeper.emailAddresses = merge.resultingEmailAddresses.map {
            CNLabeledValue(label: CNLabelOther, value: $0 as NSString)
        }

        let request = CNSaveRequest()
        request.update(keeper)
        try store.execute(request)
    }

    private func deleteContact(id: String, store: CNContactStore, into outcome: inout CleanupOutcome) {
        do {
            guard let contact = try contacts.mutableContact(id: id) else {
                // Already absent — nothing to do and nothing to report.
                return
            }
            let request = CNSaveRequest()
            request.delete(contact)
            try store.execute(request)
            outcome.contactsRemoved += 1
        } catch {
            outcome.failures.append(
                CleanupFailure(
                    id: id,
                    itemDescription: "Contact",
                    reason: error.localizedDescription,
                    domain: .contacts
                )
            )
        }
    }

    // MARK: - Estimation

    /// Scales the plan's estimate by the fraction of items that actually went.
    /// If half the assets failed, we claim half the bytes — never the full total.
    private func proportionalEstimate(plan: CleanupPlan, outcome: CleanupOutcome) -> Int64 {
        let requested = plan.allAssetIDs.count
        guard requested > 0 else { return 0 }
        let removed = outcome.photosRemoved + outcome.screenshotsRemoved + outcome.videosRemoved
        guard removed > 0 else { return 0 }
        let ratio = Double(removed) / Double(requested)
        return Int64(Double(plan.estimatedBytes) * ratio)
    }
}
