import Photos
import SwiftUI
import UIKit

/// Recovery UI for a blocked or partial permission.
///
/// Per §7 it always states which feature is unavailable, why access is needed,
/// and offers a route to Settings — while the rest of the app keeps working.
struct PermissionStateView: View {

    enum Kind { case photos, contacts }

    let kind: Kind
    let state: AccessState
    var onRequest: (() -> Void)?

    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: symbol)
                        .foregroundStyle(Theme.Palette.accent)
                    Text(title)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Palette.ink)
                }

                Text(unavailableFeature)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(reason)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                actions
                    .padding(.top, Theme.Space.xxs)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .notDetermined:
            PrimaryButton(title: requestTitle) { onRequest?() }
        case .limited:
            VStack(spacing: Theme.Space.xs) {
                // The in-app picker is a Photos-only affordance. Limited
                // *contacts* access is widened through Settings instead.
                if kind == .photos {
                    SecondaryButton(title: "Select more photos",
                                    systemImage: "photo.badge.plus") {
                        presentLimitedPicker()
                    }
                }
                SecondaryButton(title: "Open Settings", systemImage: "gear") {
                    model.permissions.openSettings()
                }
            }
        case .denied, .restricted:
            SecondaryButton(title: "Open Settings", systemImage: "gear") {
                model.permissions.openSettings()
            }
        case .granted:
            EmptyView()
        }
    }

    /// Apple's supported flow for widening a limited selection. Requires a
    /// presenting `UIViewController`, which is reached through the active scene.
    private func presentLimitedPicker() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController else { return }

        var presenter = root
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        model.permissions.presentLimitedLibraryPicker(from: presenter)
    }

    // MARK: - Copy

    private var symbol: String {
        switch state {
        case .limited: return "photo.badge.checkmark"
        case .denied, .restricted: return "lock.fill"
        default: return kind == .photos ? "photo.on.rectangle.angled" : "person.2"
        }
    }

    private var title: String {
        switch state {
        case .limited:    return kind == .photos ? "Limited Photo Access"
                                                 : "Limited Contacts Access"
        case .denied:     return kind == .photos ? "Photo access is off" : "Contacts access is off"
        case .restricted: return "Access is restricted"
        default:          return kind == .photos ? "Photo access needed" : "Contacts access needed"
        }
    }

    private var unavailableFeature: String {
        switch (kind, state) {
        case (.photos, .limited):
            return "RECLAIM can only see the photos you've chosen to share, so duplicate, screenshot and video results cover just that selection."
        case (.photos, _):
            return "Duplicate photos, screenshots and large videos can't be scanned."
        case (.contacts, .limited):
            return "RECLAIM can only see the contacts you've chosen to share, so duplicate results cover just that selection."
        case (.contacts, _):
            return "Duplicate contacts can't be scanned. Photo features still work normally."
        }
    }

    private var reason: String {
        switch kind {
        case .photos:
            return "We scan your photos on this iPhone to find duplicates, screenshots and large videos. Your photos never leave your device."
        case .contacts:
            return "We scan your contacts on this iPhone to identify likely duplicates. Your contacts never leave your device."
        }
    }

    private var requestTitle: String {
        kind == .photos ? "Allow photo access" : "Allow contacts access"
    }
}

/// Compact inline banner for the limited-access state on list screens.
struct LimitedAccessBanner: View {

    @Environment(AppModel.self) private var model
    @State private var isPresentingPicker = false

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "photo.badge.checkmark")
                .foregroundStyle(Theme.Palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Limited Photo Access")
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text("Showing only the photos you've shared with RECLAIM.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.inkSecondary)
            }
            Spacer()
            Button("Manage") { present() }
                .font(Theme.Typography.caption.weight(.semibold))
        }
        .padding(Theme.Space.sm)
        .background(Theme.Palette.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func present() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        model.permissions.presentLimitedLibraryPicker(from: presenter)
    }
}
