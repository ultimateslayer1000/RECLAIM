import SwiftUI

/// Grouped near-identical photos.
///
/// Nothing is pre-selected. The engine marks a "Suggested keep" and offers a
/// one-tap "Select all but suggested", but the user makes every actual choice —
/// and the suggestion itself can be reassigned to any frame in the group.
struct SimilarPhotosView: View {

    @Environment(AppModel.self) private var model
    @Environment(SelectionStore.self) private var selection

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Space.md) {
                if model.photoAccess == .limited {
                    LimitedAccessBanner()
                }

                if !model.photoAccess.isUsable {
                    PermissionStateView(kind: .photos, state: model.photoAccess) {
                        Task {
                            await model.permissions.requestPhotoAccess()
                            model.refreshPermissions()
                            await model.runScan()
                        }
                    }
                } else if model.isScanning && model.results.similarGroups.isEmpty {
                    ScanProgressView(progress: model.progress)
                } else if model.results.similarGroups.isEmpty {
                    Card {
                        EmptyState(
                            symbol: "sparkles",
                            title: "No duplicates found",
                            message: "We compared every photo RECLAIM can see and didn't find near-identical shots. Your library is already tidy."
                        )
                    }
                } else {
                    header
                    ForEach(model.results.similarGroups) { group in
                        SimilarGroupCard(group: group)
                    }
                }

                Color.clear.frame(height: selection.hasSelection ? 96 : Theme.Space.md)
            }
            .padding(Theme.Space.md)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.results.similarGroups.count) groups · \(model.results.photosInGroups) photos")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Palette.ink)
                Text("Review each group and choose what to remove.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Palette.inkSecondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

/// One group card: thumbnails, the suggestion, and per-group bulk actions.
struct SimilarGroupCard: View {

    let group: SimilarGroup
    @Environment(SelectionStore.self) private var selection
    @State private var preview: PhotoCandidate?
    /// Local override of the engine's suggestion, so the user can say "actually,
    /// keep that one instead" without losing the group structure.
    @State private var overriddenKeepID: String?

    private var keepID: String { overriddenKeepID ?? group.suggestedKeepID }

    private var effectiveGroup: SimilarGroup {
        SimilarGroup(id: group.id, members: group.members,
                     suggestedKeepID: keepID, kind: group.kind)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                headerRow

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.xs) {
                        ForEach(group.members) { member in
                            thumbnail(for: member)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Text(group.kind.explanation)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.inkTertiary)

                actionRow
            }
        }
        .sheet(item: $preview) { candidate in
            PhotoPreviewSheet(
                candidate: candidate,
                isSelected: selection.isSelected(candidate.id, in: .similarPhotos),
                isSuggestedKeep: candidate.id == keepID
            ) {
                selection.toggle(candidate.id, in: .similarPhotos)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: Theme.Space.xs) {
            Chip(text: group.kind.label,
                 systemImage: group.kind == .exactDuplicate ? "doc.on.doc" : "wand.and.stars",
                 tint: Theme.Palette.accent,
                 background: Theme.Palette.accentSoft)
            Text(Format.count(group.members.count, singular: "photo"))
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.Palette.inkSecondary)
            Spacer()
            Text(Format.bytes(effectiveGroup.reclaimableBytes))
                .font(Theme.Typography.footnote.weight(.semibold))
                .foregroundStyle(Theme.Palette.ink)
        }
        .accessibilityElement(children: .combine)
    }

    private func thumbnail(for member: PhotoCandidate) -> some View {
        let isSelected = selection.isSelected(member.id, in: .similarPhotos)
        let isKeep = member.id == keepID

        return VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                MediaThumbnail(assetID: member.id,
                               targetSize: CGSize(width: 260, height: 260))
                    .frame(width: 104, height: 104)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .strokeBorder(
                                isSelected ? Theme.Palette.destructive
                                           : (isKeep ? Theme.Palette.accent : .clear),
                                lineWidth: 2.5
                            )
                    )
                    .opacity(isSelected ? 0.6 : 1)

                SelectionBadge(isSelected: isSelected)
                    .padding(5)
            }
            .contentShape(Rectangle())
            .onTapGesture { selection.toggle(member.id, in: .similarPhotos) }
            .onLongPressGesture { preview = member }

            if isKeep {
                Chip(text: "Suggested keep",
                     systemImage: "star.fill",
                     tint: Theme.Palette.accent,
                     background: Theme.Palette.accentSoft)
            } else {
                Button("Keep this") { setKeep(member.id) }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.Palette.inkSecondary)
                    .frame(minHeight: 20)
            }
        }
        .frame(width: 104)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(for: member, isKeep: isKeep))
        .accessibilityValue(isSelected ? "Marked for removal" : "Kept")
        .accessibilityHint("Double tap to toggle. Nothing is deleted until you confirm on the review screen.")
        .accessibilityAddTraits(.isButton)
    }

    private func label(for member: PhotoCandidate, isKeep: Bool) -> String {
        var parts = ["Photo from \(Format.date(member.creationDate))",
                     Format.megapixels(member),
                     Format.bytes(member.byteSize)]
        if isKeep { parts.append("suggested keep") }
        return parts.joined(separator: ", ")
    }

    private var actionRow: some View {
        HStack(spacing: Theme.Space.xs) {
            Button {
                selection.selectAllButSuggested(in: effectiveGroup)
            } label: {
                Text("Select all but suggested")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Theme.minimumTapTarget - 8)
                    .foregroundStyle(Theme.Palette.destructive)
                    .background(Theme.Palette.destructive.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                selection.clearSelection(in: group)
            } label: {
                Text("Clear")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Theme.minimumTapTarget - 8)
                    .foregroundStyle(Theme.Palette.inkSecondary)
                    .background(Theme.Palette.canvas)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    /// Reassigning the keeper also un-selects it, so the user can never end up
    /// having marked their own chosen keeper for deletion.
    private func setKeep(_ id: String) {
        overriddenKeepID = id
        selection.setSelected([id], selected: false, in: .similarPhotos)
    }
}
