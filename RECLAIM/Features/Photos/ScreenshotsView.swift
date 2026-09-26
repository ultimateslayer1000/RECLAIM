import SwiftUI

/// Screenshots grid with bulk selection (§13).
struct ScreenshotsView: View {

    @Environment(AppModel.self) private var model
    @Environment(SelectionStore.self) private var selection

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    private var shots: [PhotoCandidate] { model.results.screenshots }

    private var allSelected: Bool {
        !shots.isEmpty && shots.allSatisfy { selection.isSelected($0.id, in: .screenshots) }
    }

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
                } else if model.isScanning && shots.isEmpty {
                    ScanProgressView(progress: model.progress)
                } else if shots.isEmpty {
                    Card {
                        EmptyState(
                            symbol: "iphone.gen3",
                            title: "No screenshots",
                            message: "RECLAIM didn't find any screenshots in the photos it can access."
                        )
                    }
                } else {
                    header
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(shots) { shot in
                            cell(for: shot)
                        }
                    }
                }

                Color.clear.frame(height: selection.hasSelection ? 96 : Theme.Space.md)
            }
            .padding(Theme.Space.md)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(shots.count) screenshots · \(Format.bytes(totalBytes))")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Palette.ink)
                if selection.selectedCount(for: .screenshots) > 0 {
                    Text("\(selection.selectedCount(for: .screenshots)) selected · \(Format.bytes(selection.selectedBytes(for: .screenshots)))")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Palette.destructive)
                } else {
                    Text("Nothing is selected yet.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Palette.inkSecondary)
                }
            }
            Spacer()
            Button(allSelected ? "Deselect All" : "Select All") {
                selection.setSelected(shots.map(\.id), selected: !allSelected, in: .screenshots)
            }
            .font(Theme.Typography.footnote.weight(.semibold))
            .frame(minHeight: Theme.minimumTapTarget)
        }
    }

    private var totalBytes: Int64 {
        shots.reduce(0) { $0 + $1.byteSize }
    }

    private func cell(for shot: PhotoCandidate) -> some View {
        let isSelected = selection.isSelected(shot.id, in: .screenshots)
        return ZStack(alignment: .topTrailing) {
            MediaThumbnail(assetID: shot.id, targetSize: CGSize(width: 220, height: 220))
                .aspectRatio(1, contentMode: .fill)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .strokeBorder(isSelected ? Theme.Palette.destructive : .clear,
                                      lineWidth: 2.5)
                )
                .opacity(isSelected ? 0.6 : 1)
            SelectionBadge(isSelected: isSelected)
                .padding(5)
        }
        .contentShape(Rectangle())
        .onTapGesture { selection.toggle(shot.id, in: .screenshots) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Screenshot from \(Format.date(shot.creationDate)), \(Format.bytes(shot.byteSize))")
        .accessibilityValue(isSelected ? "Selected for removal" : "Not selected")
        .accessibilityAddTraits(.isButton)
    }
}
