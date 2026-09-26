import SwiftUI

/// The mandatory confirmation gate (§18).
///
/// Everything on this screen is read-only until the user presses the destructive
/// primary action. Dismissing the sheet, tapping "Go back", or swiping it away
/// all leave the selection intact and delete nothing — the selection lives in
/// `SelectionStore`, which this screen only reads.
struct ReviewView: View {

    @Environment(AppModel.self) private var model
    @Environment(SelectionStore.self) private var selection
    @Environment(\.dismiss) private var dismiss

    let onFinished: (CleanupOutcome) -> Void

    @State private var expanded: Set<CleanupCategory> = []
    @State private var isConfirming = false
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Space.md) {
                    summaryCard
                    sections
                    noticeCard
                    PrivacyNote()
                        .padding(.horizontal, Theme.Space.xxs)
                    Color.clear.frame(height: Theme.Space.xl)
                }
                .padding(Theme.Space.md)
            }
            .screenBackground()
            .navigationTitle("Ready to clean")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Go back") { dismiss() }
                        .accessibilityHint("Closes review. Nothing is deleted.")
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
            .disabled(isWorking)
            .confirmationDialog(
                "Delete \(selection.totalSelectedItems) items?",
                isPresented: $isConfirming,
                titleVisibility: .visible
            ) {
                Button("Delete \(selection.totalSelectedItems) items", role: .destructive) {
                    Task { await execute() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(confirmationMessage)
            }
        }
        .interactiveDismissDisabled(isWorking)
    }

    // MARK: - Summary

    private var summaryCard: some View {
        Card(padding: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Overline(text: "Estimated space recovered")
                Text(Format.bytes(selection.estimatedBytes))
                    .font(Theme.Typography.display)
                    .foregroundStyle(Theme.Palette.ink)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                Divider().overlay(Theme.Palette.hairline)

                VStack(spacing: Theme.Space.xxs) {
                    ForEach(CleanupCategory.allCases) { category in
                        let count = selection.selectedCount(for: category)
                        if count > 0 {
                            HStack {
                                Image(systemName: category.symbol)
                                    .font(.caption)
                                    .foregroundStyle(Theme.Palette.accent)
                                    .frame(width: 20)
                                Text(countLabel(category, count))
                                    .font(Theme.Typography.callout)
                                    .foregroundStyle(Theme.Palette.ink)
                                Spacer()
                                if category.measuresBytes {
                                    Text(Format.bytes(selection.selectedBytes(for: category)))
                                        .font(Theme.Typography.callout.weight(.medium))
                                        .foregroundStyle(Theme.Palette.inkSecondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }

    private func countLabel(_ category: CleanupCategory, _ count: Int) -> String {
        switch category {
        case .similarPhotos:     return Format.count(count, singular: "photo")
        case .screenshots:       return Format.count(count, singular: "screenshot")
        case .largeVideos:       return Format.count(count, singular: "video")
        case .duplicateContacts: return Format.count(count, singular: "contact")
        }
    }

    // MARK: - Expandable detail

    private var sections: some View {
        VStack(spacing: Theme.Space.sm) {
            ForEach(CleanupCategory.allCases) { category in
                let count = selection.selectedCount(for: category)
                if count > 0 {
                    detailSection(category, count: count)
                }
            }
        }
    }

    private func detailSection(_ category: CleanupCategory, count: Int) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Button {
                    withAnimation(Theme.Motion.quick) {
                        expanded.formSymmetricDifference([category])
                    }
                } label: {
                    HStack {
                        Text(category.title)
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.Palette.ink)
                        Spacer()
                        Text("\(count)")
                            .font(Theme.Typography.callout)
                            .foregroundStyle(Theme.Palette.inkSecondary)
                        Image(systemName: expanded.contains(category) ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.Palette.inkTertiary)
                    }
                    .frame(minHeight: Theme.minimumTapTarget)
                }
                .buttonStyle(.plain)
                .accessibilityHint(expanded.contains(category) ? "Collapses the list" : "Expands to show exactly what will be removed")

                if expanded.contains(category) {
                    Divider().overlay(Theme.Palette.hairline)
                    detailList(for: category)
                }
            }
        }
    }

    @ViewBuilder
    private func detailList(for category: CleanupCategory) -> some View {
        switch category {
        case .duplicateContacts:
            contactDetail
        default:
            let ids = assetIDs(for: category)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4),
                      spacing: 5) {
                ForEach(ids.prefix(24), id: \.self) { id in
                    MediaThumbnail(assetID: id, targetSize: CGSize(width: 160, height: 160))
                        .aspectRatio(1, contentMode: .fill)
                }
            }
            if ids.count > 24 {
                Text("+ \(ids.count - 24) more")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.inkSecondary)
            }
        }
    }

    private func assetIDs(for category: CleanupCategory) -> [String] {
        switch category {
        case .similarPhotos: return Array(selection.similarPhotoIDs)
        case .screenshots:   return Array(selection.screenshotIDs)
        case .largeVideos:   return Array(selection.videoIDs)
        default:             return []
        }
    }

    private var contactDetail: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(model.results.contactGroups) { group in
                let decision = selection.decision(for: group.id)
                if decision.isActionable {
                    VStack(alignment: .leading, spacing: 2) {
                        switch decision {
                        case .merge(let instruction):
                            Text("Merge \(instruction.absorbedIDs.count + 1) records into \(instruction.resultingGivenName) \(instruction.resultingFamilyName)".trimmingCharacters(in: .whitespaces))
                                .font(Theme.Typography.callout)
                                .foregroundStyle(Theme.Palette.ink)
                        case .delete(let ids):
                            Text("Delete \(Format.count(ids.count, singular: "record")) from \(group.members.first?.displayName ?? "this group")")
                                .font(Theme.Typography.callout)
                                .foregroundStyle(Theme.Palette.ink)
                        case .ignore:
                            EmptyView()
                        }
                        Text(group.reasonText)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.inkTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: - Notices

    private var noticeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                // This is the single most important honesty note in the app.
                // iOS moves deleted assets to Recently Deleted, where they keep
                // occupying storage for up to 30 days. Claiming instant space
                // would simply be untrue.
                noticeRow(
                    symbol: "trash.slash",
                    title: "Photos go to Recently Deleted first",
                    body: "iOS keeps deleted photos and videos for 30 days. The space is fully freed once you empty Recently Deleted in the Photos app."
                )
                Divider().overlay(Theme.Palette.hairline)
                noticeRow(
                    symbol: "questionmark.circle",
                    title: "Sizes are estimates",
                    body: "iOS doesn't publish exact per-photo sizes to apps, so totals are calculated. Video sizes are read from the file where possible."
                )
                if selection.selectedContactCount > 0 {
                    Divider().overlay(Theme.Palette.hairline)
                    noticeRow(
                        symbol: "person.crop.circle.badge.exclamationmark",
                        title: "Contact changes are immediate",
                        body: "Unlike photos, deleted contacts are not recoverable from within iOS. Double-check the list above."
                    )
                }
            }
        }
    }

    private func noticeRow(symbol: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.xs) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(body)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Theme.Space.xs) {
            if isWorking {
                HStack(spacing: Theme.Space.xs) {
                    ProgressView()
                    Text("Cleaning…")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.inkSecondary)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: Theme.minimumTapTarget + 8)
            } else {
                PrimaryButton(
                    title: "Clean \(Format.bytes(selection.estimatedBytes))",
                    subtitle: "Removes \(Format.count(selection.totalSelectedItems, singular: "item"))",
                    isDestructive: true,
                    isEnabled: selection.hasSelection,
                    systemImage: "trash"
                ) {
                    isConfirming = true
                }
                SecondaryButton(title: "Go back") { dismiss() }
            }
        }
        .padding(Theme.Space.md)
        .background(.bar)
    }

    private var confirmationMessage: String {
        var parts: [String] = []
        if selection.selectedCount(for: .similarPhotos) > 0 {
            parts.append(Format.count(selection.selectedCount(for: .similarPhotos), singular: "photo"))
        }
        if selection.selectedCount(for: .screenshots) > 0 {
            parts.append(Format.count(selection.selectedCount(for: .screenshots), singular: "screenshot"))
        }
        if selection.selectedCount(for: .largeVideos) > 0 {
            parts.append(Format.count(selection.selectedCount(for: .largeVideos), singular: "video"))
        }
        if selection.selectedContactCount > 0 {
            parts.append(Format.count(selection.selectedContactCount, singular: "contact"))
        }
        return "This removes \(parts.joined(separator: ", ")). Photos and videos move to Recently Deleted; contact changes can't be undone."
    }

    // MARK: - Execute

    /// The one and only deletion trigger in the app.
    private func execute() async {
        isWorking = true
        // Freeze the selection into an immutable plan at the moment of consent.
        // Anything the user changes afterwards cannot affect this run.
        let frozen = selection.buildPlan()
        let outcome = await model.performCleanup(plan: frozen, selection: selection)
        isWorking = false
        onFinished(outcome)
    }
}
