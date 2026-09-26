import SwiftUI

/// First-launch flow: explain, *then* ask. Never the other way round (§7).
///
/// Both permissions are skippable. Declining Photos still leaves Contacts
/// working and vice versa — the app degrades, it does not dead-end.
struct OnboardingView: View {

    @Environment(AppModel.self) private var model
    @State private var step: Step = .welcome
    @State private var isRequesting = false

    enum Step { case welcome, photos, contacts }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Theme.Space.xl)
            content
                .padding(.horizontal, Theme.Space.lg)
            Spacer()
            footer
                .padding(.horizontal, Theme.Space.lg)
                .padding(.bottom, Theme.Space.lg)
        }
        .screenBackground()
        .animation(Theme.Motion.standard, value: step)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:  welcome
        case .photos:   explanation(for: .photos)
        case .contacts: explanation(for: .contacts)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            BrandMark()
            Text("RECLAIM")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.Palette.ink)
            Text("Make space. Keep what matters.")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.inkSecondary)

            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                bullet("square.on.square", "Find duplicate and similar photos")
                bullet("iphone.gen3", "Clear out old screenshots")
                bullet("film.stack", "Spot the videos eating your storage")
                bullet("person.2", "Tidy up repeated contacts")
            }
            .padding(.top, Theme.Space.sm)

            PrivacyNote(text: "Everything happens on this iPhone. Nothing is uploaded, ever.")
                .padding(.top, Theme.Space.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func explanation(for kind: Kind) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Image(systemName: kind.symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Palette.accent)
            Text(kind.title)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.Palette.ink)
            Text(kind.explanation)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PrivacyNote(text: kind.privacyLine)
                .padding(.top, Theme.Space.xxs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 24)
            Text(text)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.ink)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Theme.Space.sm) {
            switch step {
            case .welcome:
                PrimaryButton(title: "Get started") { step = .photos }
            case .photos:
                PrimaryButton(title: "Allow photo access", isEnabled: !isRequesting) {
                    Task {
                        isRequesting = true
                        await model.permissions.requestPhotoAccess()
                        model.refreshPermissions()
                        isRequesting = false
                        step = .contacts
                    }
                }
                Button("Not now") { step = .contacts }
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.inkSecondary)
            case .contacts:
                PrimaryButton(title: "Allow contacts access", isEnabled: !isRequesting) {
                    Task {
                        isRequesting = true
                        await model.permissions.requestContactsAccess()
                        model.refreshPermissions()
                        isRequesting = false
                        finish()
                    }
                }
                Button("Skip contacts") { finish() }
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.inkSecondary)
            }
        }
        .frame(minHeight: 96)
    }

    private func finish() {
        model.completeOnboarding()
        model.refreshPermissions()
    }

    // MARK: - Copy

    private enum Kind {
        case photos, contacts

        var symbol: String {
            switch self {
            case .photos:   return "photo.on.rectangle.angled"
            case .contacts: return "person.2"
            }
        }

        var title: String {
            switch self {
            case .photos:   return "Access to your photos"
            case .contacts: return "Access to your contacts"
            }
        }

        var explanation: String {
            switch self {
            case .photos:
                return "We scan your photos on this iPhone to find duplicates, screenshots and large videos. Your photos never leave your device."
            case .contacts:
                return "We scan your contacts on this iPhone to identify likely duplicates. Your contacts never leave your device."
            }
        }

        var privacyLine: String {
            switch self {
            case .photos:
                return "Nothing is uploaded and nothing is deleted without your explicit approval."
            case .contacts:
                return "You can skip this and still use every photo feature."
            }
        }
    }
}

/// The app's mark, drawn in SwiftUI so it matches the icon exactly.
struct BrandMark: View {
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.09, to: 0.91)
                .stroke(Theme.Palette.accent,
                        style: .init(lineWidth: size * 0.115, lineCap: .round))
                .rotationEffect(.degrees(90))
            Image(systemName: "arrow.up")
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(Theme.Palette.ink)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
