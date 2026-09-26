import SwiftUI

/// Home. Answers four questions immediately: how much is used, how much is
/// free, how much could be reclaimed, and where the biggest wins are.
struct DashboardView: View {

    @Environment(AppModel.self) private var model
    @Environment(SelectionStore.self) private var selection

    let onOpenCategory: (CleanupCategory) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.md) {
                storageSection

                if model.isScanning {
                    ScanProgressView(progress: model.progress) {
                        model.cancelScan()
                    }
                }

                if model.photoAccess == .limited {
                    LimitedAccessBanner()
                }

                permissionsSection

                if !model.isScanning && model.results.isEmpty && model.photoAccess.isUsable {
                    Card {
                        EmptyState(
                            symbol: "checkmark.seal",
                            title: "Nothing to clean",
                            message: "We scanned your library and didn't find duplicates, screenshots or large videos worth removing.",
                            actionTitle: "Scan again",
                            action: { Task { await rescan() } }
                        )
                    }
                } else {
                    categorySection
                }

                PrivacyNote()
                    .padding(.horizontal, Theme.Space.xxs)

                // Breathing room so the review bar never covers content.
                Color.clear.frame(height: selection.hasSelection ? 96 : Theme.Space.md)
            }
            .padding(Theme.Space.md)
        }
        .screenBackground()
        .navigationTitle("RECLAIM")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await rescan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isScanning)
                .accessibilityLabel("Rescan library")
            }
        }
        .refreshable { await rescan() }
    }

    private func rescan() async {
        await model.runScan()
        selection.reconcile(with: model.results)
    }

    // MARK: - Storage

    private var storageSection: some View {
        Card(padding: Theme.Space.lg) {
            VStack(spacing: Theme.Space.md) {
                Overline(text: "Device storage")
                    .frame(maxWidth: .infinity, alignment: .leading)

                StorageRing(
                    snapshot: model.storage,
                    reclaimableBytes: reclaimableForDisplay
                )
                .frame(maxWidth: .infinity)

                StorageLegend(
                    snapshot: model.storage,
                    reclaimableBytes: reclaimableForDisplay
                )

                Divider().overlay(Theme.Palette.hairline)

                // Device storage and reclaimable space are deliberately
                // presented as two separate claims (§8).
                VStack(alignment: .leading, spacing: 2) {
                    Overline(text: "Estimated reclaimable storage")
                    Text(reclaimHeadline)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Palette.accent)
                    Text(reclaimSubtitle)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Once the user starts selecting, the ring tracks their actual selection
    /// rather than the theoretical maximum.
    private var reclaimableForDisplay: Int64 {
        selection.hasSelection ? selection.estimatedBytes : model.potentialReclaimableBytes
    }

    private var reclaimHeadline: String {
        if selection.hasSelection {
            return "\(Format.bytes(selection.estimatedBytes)) selected"
        }
        let potential = model.potentialReclaimableBytes
        return potential > 0 ? "Up to \(Format.bytes(potential))" : "Nothing found yet"
    }

    private var reclaimSubtitle: String {
        if selection.hasSelection {
            return "Based on the \(selection.totalSelectedItems) items you've selected. Nothing is removed until you confirm."
        }
        if model.isScanning { return "Still scanning — this figure will grow." }
        return "An estimate from what RECLAIM found. You choose what actually goes."
    }

    // MARK: - Permissions

    @ViewBuilder
    private var permissionsSection: some View {
        if model.photoAccess.isBlocked || model.photoAccess == .notDetermined {
            PermissionStateView(kind: .photos, state: model.photoAccess) {
                Task {
                    await model.permissions.requestPhotoAccess()
                    model.refreshPermissions()
                    await rescan()
                }
            }
        }
        if model.contactsAccess.isBlocked || model.contactsAccess == .notDetermined {
            PermissionStateView(kind: .contacts, state: model.contactsAccess) {
                Task {
                    await model.permissions.requestContactsAccess()
                    model.refreshPermissions()
                    await rescan()
                }
            }
        }
    }

    // MARK: - Categories

    private var categorySection: some View {
        VStack(spacing: Theme.Space.sm) {
            Overline(text: "Where the space is")
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(CleanupCategory.allCases) { category in
                CategoryCard(
                    category: category,
                    itemCount: model.results.itemCount(for: category),
                    bytes: model.results.potentialBytes(for: category),
                    selectedCount: selection.selectedCount(for: category),
                    isAvailable: isAvailable(category)
                ) {
                    onOpenCategory(category)
                }
            }
        }
    }

    private func isAvailable(_ category: CleanupCategory) -> Bool {
        switch category {
        case .duplicateContacts: return model.contactsAccess.isUsable
        default:                 return model.photoAccess.isUsable
        }
    }
}
