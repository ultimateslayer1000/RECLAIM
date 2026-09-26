import Foundation
import Observation
import Photos
import SwiftUI

/// Application-level state: permissions, storage, scan lifecycle.
///
/// Owns no view logic and performs no deletion — it coordinates services and
/// publishes state. Deletion lives in `CleanupService`, reached only through the
/// Review screen.
@Observable
@MainActor
final class AppModel {

    // MARK: - Published state

    var photoAccess: AccessState = .notDetermined
    var contactsAccess: AccessState = .notDetermined
    var storage: StorageSnapshot = .unavailable
    var results = ScanResults()
    var progress = ScanProgress()
    var lastOutcome: CleanupOutcome?
    var scanFailure: String?

    /// True until the user has been through the permission explanation once.
    var needsOnboarding: Bool { !hasCompletedOnboarding }

    /// Stored, not computed: `@Observable` only tracks stored properties, so a
    /// UserDefaults-backed computed property would never notify the view that
    /// onboarding had finished. Persistence happens in `didSet`.
    private(set) var hasCompletedOnboarding: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: Self.onboardingKey)
        }
    }

    private static let onboardingKey = "reclaim.onboarding.completed.v1"

    // MARK: - Dependencies

    let permissions = PermissionService()
    private let storageService = StorageService()
    private let scanEngine = ScanEngine()
    private let cleanupService = CleanupService()
    private var scanTask: Task<Void, Never>?
    private var libraryObserver: LibraryObserver?

    init() {
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Self.onboardingKey)
        refreshPermissions()
        refreshStorage()
    }

    // MARK: - Permissions

    func refreshPermissions() {
        photoAccess = permissions.photoAccess()
        contactsAccess = permissions.contactsAccess()
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
    }

    /// Begins observing the photo library so external changes (a deletion made
    /// in Photos, or a widened limited selection) invalidate our results.
    func startObservingLibrary() {
        guard libraryObserver == nil, photoAccess.isUsable else { return }
        let observer = LibraryObserver { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshPermissions()
                await self.runScan()
            }
        }
        PHPhotoLibrary.shared().register(observer)
        libraryObserver = observer
    }

    // MARK: - Storage

    func refreshStorage() {
        storage = storageService.snapshot()
    }

    /// Upper bound of what a full accept-every-suggestion cleanup would free.
    var potentialReclaimableBytes: Int64 {
        CleanupCategory.allCases.reduce(0) { $0 + results.potentialBytes(for: $1) }
    }

    // MARK: - Scanning

    var isScanning: Bool { progress.isRunning }

    func runScan() async {
        scanTask?.cancel()
        scanFailure = nil

        let photo = photoAccess
        let contacts = contactsAccess

        guard photo.isUsable || contacts.isUsable else {
            progress = ScanProgress()
            results = ScanResults()
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            let engine = self.scanEngine

            let final = await engine.scan(
                photoAccess: photo,
                contactsAccess: contacts,
                onProgress: { update in
                    Task { @MainActor [weak self] in self?.progress = update }
                },
                onPartial: { partial in
                    Task { @MainActor [weak self] in self?.apply(partial) }
                }
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.apply(final)
                self.progress.phase = .complete
                self.progress.phaseFraction = 1
                self.refreshStorage()
            }
        }
        scanTask = task
        await task.value
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        progress = ScanProgress()
    }

    private func apply(_ incoming: ScanResults) {
        results = incoming
    }

    // MARK: - Cleanup

    /// Executes a plan the user has explicitly confirmed, then re-verifies
    /// device state. Never called from anywhere but the Review confirmation.
    func performCleanup(plan: CleanupPlan, selection: SelectionStore) async -> CleanupOutcome {
        let outcome = await cleanupService.execute(plan: plan)
        lastOutcome = outcome

        // Re-read the world rather than assuming the deletion succeeded.
        refreshStorage()
        if outcome.totalItemsRemoved > 0 || outcome.contactsMerged > 0 {
            ThumbnailProvider.shared.resetCaches()
            await runScan()
        }
        // Drop only what actually went; anything that failed stays selected so
        // the user can retry it.
        selection.reconcile(with: results)
        return outcome
    }
}

/// Bridges `PHPhotoLibraryChangeObserver` (an Objective-C protocol requiring a
/// class) into a closure the model can own.
private final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
