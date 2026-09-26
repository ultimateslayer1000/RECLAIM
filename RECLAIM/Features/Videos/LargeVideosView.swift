import SwiftUI

/// Videos, largest first (§14).
///
/// The bar under each row is scaled against the largest video in the list, so
/// the storage hogs are obvious at a glance rather than requiring the user to
/// compare numbers.
struct LargeVideosView: View {

    @Environment(AppModel.self) private var model
    @Environment(SelectionStore.self) private var selection

    private var videos: [PhotoCandidate] { model.results.largeVideos }

    private var allSelected: Bool {
        !videos.isEmpty && videos.allSatisfy { selection.isSelected($0.id, in: .largeVideos) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Space.sm) {
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
                } else if model.isScanning && videos.isEmpty {
                    ScanProgressView(progress: model.progress)
                } else if videos.isEmpty {
                    Card {
                        EmptyState(
                            symbol: "film.stack",
                            title: "No videos found",
                            message: "RECLAIM didn't find any videos in the photos it can access."
                        )
                    }
                } else {
                    header
                    ForEach(videos) { video in
                        VideoRow(video: video, largestBytes: videos.first?.byteSize ?? 1)
                    }
                }

                Color.clear.frame(height: selection.hasSelection ? 96 : Theme.Space.md)
            }
            .padding(Theme.Space.md)
        }
        .screenBackground()
        .navigationTitle("Large Videos")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(videos.count) videos · \(Format.bytes(totalBytes))")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Palette.ink)
                Text("Sorted largest first")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Palette.inkSecondary)
            }
            Spacer()
            Button(allSelected ? "Deselect All" : "Select All") {
                selection.setSelected(videos.map(\.id), selected: !allSelected, in: .largeVideos)
            }
            .font(Theme.Typography.footnote.weight(.semibold))
            .frame(minHeight: Theme.minimumTapTarget)
        }
    }

    private var totalBytes: Int64 {
        videos.reduce(0) { $0 + $1.byteSize }
    }
}

struct VideoRow: View {

    let video: PhotoCandidate
    let largestBytes: Int64
    @Environment(SelectionStore.self) private var selection

    private var isSelected: Bool { selection.isSelected(video.id, in: .largeVideos) }

    private var relativeWidth: Double {
        guard largestBytes > 0 else { return 0 }
        return max(0.04, min(1, Double(video.byteSize) / Double(largestBytes)))
    }

    var body: some View {
        Button {
            selection.toggle(video.id, in: .largeVideos)
        } label: {
            Card(padding: Theme.Space.sm) {
                HStack(spacing: Theme.Space.sm) {
                    ZStack(alignment: .bottomLeading) {
                        MediaThumbnail(assetID: video.id,
                                       targetSize: CGSize(width: 200, height: 200))
                            .frame(width: 66, height: 66)
                        Text(Format.duration(video.duration))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(4)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(Format.date(video.creationDate))
                            .font(Theme.Typography.callout.weight(.medium))
                            .foregroundStyle(Theme.Palette.ink)
                            .lineLimit(1)

                        HStack(spacing: 5) {
                            Text(Format.bytes(video.byteSize))
                                .font(Theme.Typography.footnote.weight(.semibold))
                                .foregroundStyle(Theme.Palette.ink)
                            if video.byteSize >= VideoService.largeThreshold {
                                Chip(text: "Large",
                                     tint: Theme.Palette.accent,
                                     background: Theme.Palette.accentSoft)
                            }
                            // Honest labelling: an iCloud-only asset's size is a
                            // calculation, not a measurement, and says so.
                            if video.sizeAccuracy != .exact {
                                Chip(text: video.sizeAccuracy == .estimated ? "Estimated" : "Size unknown",
                                     systemImage: "icloud")
                            }
                        }

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.Palette.ringTrack)
                                Capsule()
                                    .fill(isSelected ? Theme.Palette.destructive : Theme.Palette.accent)
                                    .frame(width: proxy.size.width * relativeWidth)
                            }
                        }
                        .frame(height: 5)
                    }

                    SelectionBadge(isSelected: isSelected)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(isSelected ? "Selected for removal" : "Not selected")
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var parts = ["Video from \(Format.date(video.creationDate))",
                     Format.duration(video.duration),
                     Format.bytes(video.byteSize)]
        if video.sizeAccuracy == .estimated { parts.append("size estimated") }
        return parts.joined(separator: ", ")
    }
}
