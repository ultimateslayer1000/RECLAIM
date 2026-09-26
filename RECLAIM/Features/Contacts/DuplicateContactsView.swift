import SwiftUI

/// Duplicate contacts, each group offering Merge / Delete / Ignore (§15–16).
struct DuplicateContactsView: View {

    @Environment(AppModel.self) private var model
    @Environment(SelectionStore.self) private var selection

    private var groups: [ContactDuplicateGroup] { model.results.contactGroups }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Space.md) {
                if !model.contactsAccess.isUsable {
                    PermissionStateView(kind: .contacts, state: model.contactsAccess) {
                        Task {
                            await model.permissions.requestContactsAccess()
                            model.refreshPermissions()
                            await model.runScan()
                        }
                    }
                } else if model.isScanning && groups.isEmpty {
                    ScanProgressView(progress: model.progress)
                } else if groups.isEmpty {
                    Card {
                        EmptyState(
                            symbol: "person.crop.circle.badge.checkmark",
                            title: "No duplicate contacts",
                            message: "We compared phone numbers, email addresses and names and didn't find any likely duplicates."
                        )
                    }
                } else {
                    header
                    ForEach(groups) { group in
                        ContactGroupCard(group: group)
                    }
                }

                Color.clear.frame(height: selection.hasSelection ? 96 : Theme.Space.md)
            }
            .padding(Theme.Space.md)
        }
        .screenBackground()
        .navigationTitle("Duplicate Contacts")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(groups.count) possible duplicate groups")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Palette.ink)
            Text("Nothing changes until you choose an action and confirm on the review screen.")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct ContactGroupCard: View {

    let group: ContactDuplicateGroup
    @Environment(SelectionStore.self) private var selection
    @State private var showingMergePreview = false

    private var decision: ContactDecision { selection.decision(for: group.id) }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                headerRow

                VStack(spacing: Theme.Space.xs) {
                    ForEach(group.members) { member in
                        memberRow(member)
                    }
                }

                statusRow
                actionRow
            }
        }
        .sheet(isPresented: $showingMergePreview) {
            ContactMergePreview(group: group) { instruction in
                selection.setDecision(.merge(instruction: instruction), for: group.id)
                showingMergePreview = false
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: Theme.Space.xs) {
            Chip(text: group.confidence.label,
                 systemImage: "person.2.fill",
                 tint: Theme.Palette.accent,
                 background: Theme.Palette.accentSoft)
            Spacer()
            Text(Format.count(group.members.count, singular: "record"))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.inkTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private func memberRow(_ member: ContactRecord) -> some View {
        let isMarkedForDeletion: Bool = {
            switch decision {
            case .delete(let ids): return ids.contains(member.id)
            case .merge(let instruction): return instruction.absorbedIDs.contains(member.id)
            case .ignore: return false
            }
        }()
        let isKeeper: Bool = {
            if case .merge(let instruction) = decision { return instruction.keepID == member.id }
            return false
        }()

        return HStack(spacing: Theme.Space.sm) {
            ZStack {
                Circle().fill(Theme.Palette.accentSoft)
                Text(member.initials)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.Palette.accent)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text(member.displayName)
                    .font(Theme.Typography.callout.weight(.medium))
                    .foregroundStyle(Theme.Palette.ink)
                    .strikethrough(isMarkedForDeletion, color: Theme.Palette.destructive)
                if !member.organizationName.isEmpty {
                    Text(member.organizationName)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.inkTertiary)
                }
                if let detail = member.phoneNumbers.first ?? member.emailAddresses.first {
                    Text(detail)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.inkSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isKeeper {
                Chip(text: "Keeping", systemImage: "checkmark",
                     tint: Theme.Palette.accent, background: Theme.Palette.accentSoft)
            } else if isMarkedForDeletion {
                Chip(text: "Removing", systemImage: "trash",
                     tint: Theme.Palette.destructive, background: Theme.Palette.surface)
            } else {
                Button {
                    toggleDeletion(of: member.id)
                } label: {
                    Text("Delete")
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.destructive)
                        .frame(minHeight: Theme.minimumTapTarget - 12)
                        .padding(.horizontal, Theme.Space.xs)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Space.xs)
        .background(Theme.Palette.canvas)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(member.displayName). \(isMarkedForDeletion ? "Marked for removal" : "Kept")")
    }

    private var statusRow: some View {
        HStack(spacing: Theme.Space.xxs) {
            Image(systemName: "info.circle")
                .font(.caption2)
                .foregroundStyle(Theme.Palette.inkTertiary)
            // Always explain *why* these were grouped (§15).
            Text("Grouped because: \(group.reasonText)")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.inkSecondary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var actionRow: some View {
        HStack(spacing: Theme.Space.xs) {
            actionButton(title: "Merge", symbol: "arrow.triangle.merge",
                         tint: Theme.Palette.accent) {
                showingMergePreview = true
            }
            actionButton(title: "Delete extras", symbol: "trash",
                         tint: Theme.Palette.destructive) {
                let others = Set(group.members.map(\.id)).subtracting([group.suggestedKeepID])
                selection.setDecision(.delete(ids: others), for: group.id)
            }
            actionButton(title: decision.isActionable ? "Undo" : "Ignore",
                         symbol: decision.isActionable ? "arrow.uturn.backward" : "xmark",
                         tint: Theme.Palette.inkSecondary) {
                selection.setDecision(.ignore, for: group.id)
            }
        }
    }

    private func actionButton(title: String, symbol: String, tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.caption)
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: Theme.minimumTapTarget)
            .foregroundStyle(tint)
            .background(tint.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func toggleDeletion(of id: String) {
        var ids: Set<String>
        if case .delete(let existing) = decision { ids = existing } else { ids = [] }
        ids.formSymmetricDifference([id])
        // Never let the user delete every record in a group — that would lose
        // the person entirely, which is not what "remove a duplicate" means.
        if ids.count >= group.members.count {
            ids.remove(group.suggestedKeepID)
        }
        selection.setDecision(ids.isEmpty ? .ignore : .delete(ids: ids), for: group.id)
    }
}
