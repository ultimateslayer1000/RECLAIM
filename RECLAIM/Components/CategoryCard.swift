import SwiftUI

/// One opportunity on the dashboard: what it is, how much it's worth, how much
/// of it the user has already picked.
struct CategoryCard: View {

    let category: CleanupCategory
    let itemCount: Int
    let bytes: Int64
    let selectedCount: Int
    let isAvailable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Card {
                HStack(spacing: Theme.Space.sm) {
                    icon

                    VStack(alignment: .leading, spacing: 3) {
                        Text(category.title)
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.Palette.ink)
                        Text(detailLine)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.Palette.inkSecondary)
                        if selectedCount > 0 {
                            Chip(text: "\(selectedCount) selected",
                                 systemImage: "checkmark.circle.fill",
                                 tint: Theme.Palette.destructive,
                                 background: Theme.Palette.surface)
                                .padding(.top, 2)
                        }
                    }

                    Spacer(minLength: Theme.Space.xs)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(valueLine)
                            .font(Theme.Typography.headline)
                            .foregroundStyle(isAvailable && itemCount > 0
                                             ? Theme.Palette.accent
                                             : Theme.Palette.inkTertiary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.Palette.inkTertiary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(isAvailable ? 1 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.Palette.accentSoft)
            Image(systemName: category.symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Theme.Palette.accent)
        }
        .frame(width: 46, height: 46)
    }

    private var detailLine: String {
        guard isAvailable else { return "Permission needed" }
        guard itemCount > 0 else { return "Nothing found" }
        switch category {
        case .duplicateContacts:
            return Format.count(itemCount, singular: "possible duplicate")
        default:
            return Format.count(itemCount, singular: "item")
        }
    }

    private var valueLine: String {
        guard isAvailable else { return "—" }
        guard itemCount > 0 else { return "—" }
        if category.measuresBytes {
            return "Save \(Format.bytes(bytes))"
        }
        return "\(itemCount)"
    }

    private var accessibilityText: String {
        var parts = [category.title, detailLine]
        if isAvailable && itemCount > 0 && category.measuresBytes {
            parts.append("could save \(Format.bytes(bytes))")
        }
        if selectedCount > 0 { parts.append("\(selectedCount) selected") }
        return parts.joined(separator: ", ")
    }
}
