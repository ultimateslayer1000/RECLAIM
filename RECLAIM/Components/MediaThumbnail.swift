import Photos
import SwiftUI

/// Loads and displays one asset's thumbnail.
///
/// The `PHAsset` is resolved from its identifier inside the view, so the rest of
/// the app only ever passes `Sendable` values around. Loading is cancelled when
/// the view disappears, which matters when a grid of hundreds of cells is
/// flicked past quickly.
struct MediaThumbnail: View {

    let assetID: String
    var targetSize: CGSize = CGSize(width: 240, height: 240)
    var cornerRadius: CGFloat = Theme.Radius.sm

    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Theme.Palette.ringTrack)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if didFail {
                // An iCloud-only asset with nothing cached locally is a normal
                // state, not an error — show a placeholder and say so.
                VStack(spacing: 4) {
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 16, weight: .light))
                    Text("Not downloaded")
                        .font(.system(size: 9))
                }
                .foregroundStyle(Theme.Palette.inkTertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(Theme.Motion.quick, value: image != nil)
        .task(id: assetID) { await load() }
        .accessibilityHidden(true)
    }

    private func load() async {
        image = nil
        didFail = false
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetID], options: nil
        ).firstObject else {
            didFail = true
            return
        }
        let loaded = await ThumbnailProvider.shared.thumbnail(for: asset, targetSize: targetSize)
        guard !Task.isCancelled else { return }
        if let loaded {
            image = loaded
        } else {
            didFail = true
        }
    }
}

/// Full-screen preview so the user can actually inspect a photo before deciding.
struct PhotoPreviewSheet: View {

    let candidate: PhotoCandidate
    let isSelected: Bool
    let isSuggestedKeep: Bool
    let onToggle: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: Theme.Space.sm) {
                    HStack(spacing: Theme.Space.xs) {
                        Chip(text: Format.megapixels(candidate), systemImage: "viewfinder")
                        Chip(text: Format.bytes(candidate.byteSize), systemImage: "internaldrive")
                        if isSuggestedKeep {
                            Chip(text: "Suggested keep",
                                 systemImage: "star.fill",
                                 tint: Theme.Palette.accent,
                                 background: Theme.Palette.accentSoft)
                        }
                    }
                    Text(Format.date(candidate.creationDate))
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Palette.inkSecondary)

                    PrimaryButton(
                        title: isSelected ? "Keep this photo" : "Mark for removal",
                        isDestructive: !isSelected,
                        systemImage: isSelected ? "arrow.uturn.backward" : "trash"
                    ) {
                        onToggle()
                    }
                }
                .padding(Theme.Space.md)
                .background(Theme.Palette.surface)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [candidate.id], options: nil
        ).firstObject else { return }
        // Capped at a screen-sized request — never the full-resolution original.
        let size = CGSize(width: 1200, height: 1200)
        image = await ThumbnailProvider.shared.previewImage(for: asset, targetSize: size)
    }
}
