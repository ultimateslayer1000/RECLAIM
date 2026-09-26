import SwiftUI

// MARK: - Card

/// The app's one container style. Every surface uses it, which is what makes
/// the screens feel related without any per-screen styling.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Space.md
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
            )
            .shadow(color: Theme.Shadow.card,
                    radius: Theme.Shadow.cardRadius,
                    y: Theme.Shadow.cardY)
    }
}

// MARK: - Screen background

struct ScreenBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.Palette.canvas.ignoresSafeArea())
    }
}

extension View {
    func screenBackground() -> some View { modifier(ScreenBackground()) }
}

// MARK: - Section label

struct Overline: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Theme.Typography.overline)
            .kerning(0.8)
            .foregroundStyle(Theme.Palette.inkTertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Buttons

/// Primary call to action. `isDestructive` switches the fill to the destructive
/// hue — the only place that colour is ever used for a filled control, so a
/// deletion button can never be mistaken for a benign one.
struct PrimaryButton: View {
    let title: String
    var subtitle: String?
    var isDestructive: Bool = false
    var isEnabled: Bool = true
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                }
                VStack(spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.Typography.caption)
                            .opacity(0.85)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: Theme.minimumTapTarget + 8)
            .foregroundStyle(.white)
            .background(isDestructive ? Theme.Palette.destructive : Theme.Palette.accent)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(.isButton)
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity)
            .frame(minHeight: Theme.minimumTapTarget)
            .foregroundStyle(Theme.Palette.ink)
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Small pill used for counts, badges and reasons.
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = Theme.Palette.inkSecondary
    var background: Color = Theme.Palette.canvas

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2.weight(.semibold))
            }
            Text(text).font(Theme.Typography.caption.weight(.medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.Space.xs)
        .padding(.vertical, 5)
        .background(background)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.18), lineWidth: 1))
    }
}

// MARK: - Selection indicator

/// Selection is communicated three ways — fill, border and an explicit
/// checkmark glyph — so it never depends on colour alone (§26).
struct SelectionBadge: View {
    let isSelected: Bool
    var isDestructiveIntent: Bool = true

    private var tint: Color {
        isDestructiveIntent ? Theme.Palette.destructive : Theme.Palette.accent
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? tint : Color.black.opacity(0.25))
            Circle()
                .strokeBorder(.white.opacity(isSelected ? 0 : 0.9), lineWidth: 1.5)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
        .animation(Theme.Motion.quick, value: isSelected)
        .accessibilityHidden(true)
    }
}

// MARK: - Empty state

/// Every list uses this rather than rendering nothing, per §24.
struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.Palette.accent)
                .padding(.bottom, Theme.Space.xxs)
            Text(title)
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Palette.ink)
            Text(message)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.callout.weight(.semibold))
                    .padding(.top, Theme.Space.xxs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
        .padding(.horizontal, Theme.Space.lg)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Privacy note

/// Reused wherever it reassures: the dashboard, onboarding and review.
struct PrivacyNote: View {
    var text = "Your photos and contacts stay on this iPhone."

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "lock.shield")
                .font(.footnote)
                .foregroundStyle(Theme.Palette.accent)
            Text(text)
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.Palette.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
