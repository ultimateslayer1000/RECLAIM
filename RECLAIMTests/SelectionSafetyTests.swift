import XCTest
@testable import RECLAIM

/// Covers the safety guarantees from §31.
///
/// These assert the property that matters most: **selection is not deletion**.
/// `SelectionStore` has no access to `PHPhotoLibrary` or `CNContactStore` at
/// all, and the only way to reach `CleanupService` is a `CleanupPlan` produced
/// by `buildPlan()`. The tests below pin that boundary in place so a future
/// refactor cannot quietly erode it.
@MainActor
final class SelectionSafetyTests: XCTestCase {

    private func candidate(_ id: String, bytes: Int64 = 1_000_000,
                           isScreenshot: Bool = false) -> PhotoCandidate {
        PhotoCandidate(id: id, pixelWidth: 4032, pixelHeight: 3024,
                       creationDate: Date(), isScreenshot: isScreenshot,
                       byteSize: bytes, sizeAccuracy: .estimated)
    }

    private func makeResults() -> ScanResults {
        var results = ScanResults()
        let members = [candidate("p1"), candidate("p2"), candidate("p3")]
        results.similarGroups = [
            SimilarGroup(id: "g1", members: members,
                         suggestedKeepID: "p1", kind: .similar)
        ]
        results.screenshots = [candidate("s1", bytes: 500_000, isScreenshot: true),
                               candidate("s2", bytes: 500_000, isScreenshot: true)]
        results.largeVideos = [candidate("v1", bytes: 100_000_000)]
        return results
    }

    private func makeStore() -> SelectionStore {
        let store = SelectionStore()
        store.reconcile(with: makeResults())
        return store
    }

    // MARK: - TEST 1 & 2: leaving review deletes nothing

    func testSelectingDoesNotProduceAnyDeletionByItself() {
        let store = makeStore()
        store.toggle("p2", in: .similarPhotos)
        store.toggle("s1", in: .screenshots)

        // Selection is recorded...
        XCTAssertEqual(store.totalSelectedItems, 2)
        // ...and that is all it is. A plan must be built explicitly.
        let plan = store.buildPlan()
        XCTAssertEqual(Set(plan.allAssetIDs), ["p2", "s1"])
        XCTAssertFalse(plan.isEmpty)
    }

    func testAbandoningReviewLeavesSelectionIntactAndNothingDeleted() {
        let store = makeStore()
        store.toggle("p2", in: .similarPhotos)

        // Simulate opening Review (which only *reads* the store) then leaving.
        _ = store.buildPlan()

        // Building a plan must not mutate or consume the selection.
        XCTAssertEqual(store.totalSelectedItems, 1)
        XCTAssertTrue(store.isSelected("p2", in: .similarPhotos))
    }

    // MARK: - TEST 3: only the selected items enter the plan

    func testPlanContainsExactlyWhatWasSelectedAndNothingElse() {
        let store = makeStore()
        store.toggle("p2", in: .similarPhotos)
        store.toggle("v1", in: .largeVideos)

        let plan = store.buildPlan()
        XCTAssertEqual(plan.similarPhotoIDs, ["p2"])
        XCTAssertEqual(plan.videoIDs, ["v1"])
        XCTAssertTrue(plan.screenshotIDs.isEmpty)
        XCTAssertFalse(plan.allAssetIDs.contains("p1"), "Unselected items must never appear")
        XCTAssertFalse(plan.allAssetIDs.contains("p3"))
    }

    func testSuggestedKeepIsNeverIncludedBySelectAllButSuggested() {
        let store = makeStore()
        let group = makeResults().similarGroups[0]
        store.selectAllButSuggested(in: group)

        XCTAssertFalse(store.isSelected("p1", in: .similarPhotos),
                       "The suggested keep must never be marked for deletion")
        XCTAssertTrue(store.isSelected("p2", in: .similarPhotos))
        XCTAssertTrue(store.isSelected("p3", in: .similarPhotos))
    }

    func testSelectAllButSuggestedRemovesAPreviouslySelectedKeeper() {
        let store = makeStore()
        store.toggle("p1", in: .similarPhotos)   // user selected the keeper first
        store.selectAllButSuggested(in: makeResults().similarGroups[0])
        XCTAssertFalse(store.isSelected("p1", in: .similarPhotos))
    }

    // MARK: - Deduplication

    func testPlanDeduplicatesAnAssetSelectedInTwoCategories() {
        // A screenshot could also surface as a duplicate. Deleting it twice in
        // one change request would fail, so the union is taken once.
        let store = SelectionStore()
        var results = ScanResults()
        let shared = candidate("dup1", isScreenshot: true)
        results.similarGroups = [
            SimilarGroup(id: "g", members: [shared, candidate("other")],
                         suggestedKeepID: "other", kind: .exactDuplicate)
        ]
        results.screenshots = [shared]
        store.reconcile(with: results)

        store.toggle("dup1", in: .similarPhotos)
        store.toggle("dup1", in: .screenshots)

        let plan = store.buildPlan()
        XCTAssertEqual(plan.allAssetIDs.count, 1)
        XCTAssertEqual(plan.allAssetIDs, ["dup1"])
    }

    // MARK: - Selection persistence (§17)

    func testSelectionSurvivesReconcileWhenItemsStillExist() {
        let store = makeStore()
        store.toggle("p2", in: .similarPhotos)
        store.toggle("s1", in: .screenshots)

        // Navigating between screens triggers no reset; a rescan reconciles.
        store.reconcile(with: makeResults())

        XCTAssertTrue(store.isSelected("p2", in: .similarPhotos))
        XCTAssertTrue(store.isSelected("s1", in: .screenshots))
    }

    func testReconcileDropsSelectionsForItemsThatNoLongerExist() {
        let store = makeStore()
        store.toggle("p2", in: .similarPhotos)
        store.toggle("s1", in: .screenshots)

        // Simulate the item vanishing (deleted in Photos.app, or already cleaned).
        var shrunk = ScanResults()
        shrunk.similarGroups = []
        shrunk.screenshots = [candidate("s1", isScreenshot: true)]
        store.reconcile(with: shrunk)

        XCTAssertFalse(store.isSelected("p2", in: .similarPhotos),
                       "A stale identifier must never survive into a plan")
        XCTAssertTrue(store.isSelected("s1", in: .screenshots))
    }

    // MARK: - Byte accounting

    func testEstimatedBytesSumsOnlySelectedItems() {
        let store = makeStore()
        store.toggle("p2", in: .similarPhotos)       // 1,000,000
        store.toggle("v1", in: .largeVideos)         // 100,000,000
        XCTAssertEqual(store.estimatedBytes, 101_000_000)
    }

    func testEstimatedBytesIsZeroWithNoSelection() {
        XCTAssertEqual(makeStore().estimatedBytes, 0)
    }

    func testContactsContributeNoBytes() {
        let store = SelectionStore()
        var results = ScanResults()
        results.contactGroups = [
            ContactDuplicateGroup(
                id: "cg",
                members: [
                    ContactRecord(id: "c1", givenName: "A", familyName: "B",
                                  organizationName: "", phoneNumbers: ["9876543210"],
                                  emailAddresses: [], hasImage: false),
                    ContactRecord(id: "c2", givenName: "A", familyName: "B",
                                  organizationName: "", phoneNumbers: ["9876543210"],
                                  emailAddresses: [], hasImage: false)
                ],
                signals: [.samePhoneNumber], score: 100)
        ]
        store.reconcile(with: results)
        store.setDecision(.delete(ids: ["c2"]), for: "cg")

        XCTAssertEqual(store.selectedContactCount, 1)
        XCTAssertEqual(store.estimatedBytes, 0, "Contacts free no meaningful disk space")
        XCTAssertEqual(store.buildPlan().contactDeletionIDs, ["c2"])
    }

    // MARK: - Contact decisions

    func testIgnoreDecisionRemovesTheGroupFromThePlan() {
        let store = SelectionStore()
        var results = ScanResults()
        results.contactGroups = [
            ContactDuplicateGroup(
                id: "cg",
                members: [
                    ContactRecord(id: "c1", givenName: "A", familyName: "",
                                  organizationName: "", phoneNumbers: ["9876543210"],
                                  emailAddresses: [], hasImage: false),
                    ContactRecord(id: "c2", givenName: "A", familyName: "",
                                  organizationName: "", phoneNumbers: ["9876543210"],
                                  emailAddresses: [], hasImage: false)
                ],
                signals: [.samePhoneNumber], score: 100)
        ]
        store.reconcile(with: results)

        store.setDecision(.delete(ids: ["c2"]), for: "cg")
        XCTAssertEqual(store.buildPlan().contactDeletionIDs.count, 1)

        store.setDecision(.ignore, for: "cg")
        XCTAssertTrue(store.buildPlan().contactDeletionIDs.isEmpty)
        XCTAssertEqual(store.selectedContactCount, 0)
    }

    func testClearAllEmptiesEverySurface() {
        let store = makeStore()
        store.toggle("p2", in: .similarPhotos)
        store.toggle("s1", in: .screenshots)
        store.toggle("v1", in: .largeVideos)

        store.clearAll()

        XCTAssertFalse(store.hasSelection)
        XCTAssertTrue(store.buildPlan().isEmpty)
    }

    // MARK: - Empty plan

    func testEmptyPlanIsRecognisedAsEmpty() {
        XCTAssertTrue(CleanupPlan.empty.isEmpty)
        XCTAssertFalse(CleanupPlan.empty.touchesPhotoLibrary)
        XCTAssertFalse(CleanupPlan.empty.touchesContacts)
    }
}
