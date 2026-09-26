import Contacts
import Foundation
import Photos
import UIKit

/// Normalised permission state shared by both frameworks.
enum AccessState: String, Sendable, Equatable {
    case notDetermined
    case granted
    /// Photos only: the user picked a subset of their library.
    case limited
    case denied
    case restricted

    /// Whether RECLAIM can do *any* work with this permission.
    var isUsable: Bool { self == .granted || self == .limited }

    var isBlocked: Bool { self == .denied || self == .restricted }
}

/// Wraps the two system permission flows.
///
/// Nothing here requests access on its own — the onboarding flow explains why
/// first, then calls these. `@MainActor` because the underlying prompts are UI.
@MainActor
final class PermissionService {

    // MARK: - Reading current state

    func photoAccess() -> AccessState {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func contactsAccess() -> AccessState {
        Self.map(CNContactStore.authorizationStatus(for: .contacts))
    }

    // MARK: - Requesting

    /// Requests read *and* write — write is genuinely needed because the whole
    /// product is deletion. Read-only access would make the app pointless.
    @discardableResult
    func requestPhotoAccess() async -> AccessState {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return Self.map(status)
    }

    @discardableResult
    func requestContactsAccess() async -> AccessState {
        let store = CNContactStore()
        do {
            let granted = try await store.requestAccess(for: .contacts)
            return granted ? .granted : .denied
        } catch {
            // A thrown error here means the prompt could not be shown or the
            // user declined; either way we have no access.
            return .denied
        }
    }

    // MARK: - Limited library

    /// Presents Apple's supported flow for widening a limited photo selection.
    /// This is the only sanctioned way to change a limited selection in-app.
    func presentLimitedLibraryPicker(from controller: UIViewController) {
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    // MARK: - Settings

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Mapping

    private static func map(_ status: PHAuthorizationStatus) -> AccessState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted:    return .restricted
        case .denied:        return .denied
        case .authorized:    return .granted
        case .limited:       return .limited
        @unknown default:    return .denied
        }
    }

    private static func map(_ status: CNAuthorizationStatus) -> AccessState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted:    return .restricted
        case .denied:        return .denied
        case .authorized:    return .granted
        @unknown default:
            // iOS 18 adds `.limited` for contacts. RECLAIM targets iOS 17, and
            // treating an unknown-but-present state as usable would be unsafe,
            // so we degrade to denied and show the recovery UI.
            return .denied
        }
    }
}
