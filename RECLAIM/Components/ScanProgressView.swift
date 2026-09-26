import SwiftUI

/// Live scan readout: overall bar plus a per-phase checklist.
struct ScanProgressView: View {

    let progress: ScanProgress
    var onCancel: (() -> Void)?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack {
                    Text("Scanning your library")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Palette.ink)
                    Spacer()
                    if let onCancel {
                        Button("Cancel", action: onCancel)
                            .font(Theme.Typography.footnote.weight(.medium))
                            .foregroundStyle(Theme.Palette.inkSecondary)
                    }
                }

                ProgressView(value: progress.overallFraction)
                    .tint(Theme.Palette.accent)

                if progress.totalAssets > 0 {
                    Text("\(progress.processedAssets) of \(progress.totalAssets) items")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.inkSecondary)
                }

                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(ScanPhase.workingPhases, id: \.rawValue) { phase in
                        row(for: phase)
                    }
                }
                .padding(.top, Theme.Space.xxs)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scanning. \(progress.phase.label). \(Int(progress.overallFraction * 100)) percent complete.")
    }

    private func row(for phase: ScanPhase) -> some View {
        let phases = ScanPhase.workingPhases
        let currentIndex = phases.firstIndex(of: progress.phase) ?? phases.count
        let thisIndex = phases.firstIndex(of: phase) ?? 0
        let isDone = progress.phase == .complete || thisIndex < currentIndex
        let isActive = thisIndex == currentIndex && progress.phase != .complete

        return HStack(spacing: Theme.Space.xs) {
            Group {
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Palette.accent)
                } else if isActive {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(Theme.Palette.inkTertiary.opacity(0.5))
                }
            }
            .frame(width: 18)

            Text(phase.label)
                .font(Theme.Typography.footnote)
                .foregroundStyle(isDone || isActive
                                 ? Theme.Palette.ink
                                 : Theme.Palette.inkTertiary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The persistent bottom bar shown whenever a selection exists.
struct ReviewBar: View {

    @Environment(SelectionStore.self) private var selection
    let onReview: () -> Void

    var body: some View {
        Button(action: onReview) {
            HStack(spacing: Theme.Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Format.count(selection.totalSelectedItems, singular: "item") + " selected")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.Palette.ink)
                    Text("About \(Format.bytes(selection.estimatedBytes))")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.inkSecondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Text("Review")
                    Image(systemName: "arrow.right")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, Theme.Space.xs + 2)
                .background(Theme.Palette.accent)
                .clipShape(Capsule())
            }
            .padding(Theme.Space.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .fill(Theme.Palette.surface)
                    .shadow(color: Color.black.opacity(0.12), radius: 16, y: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Review \(selection.totalSelectedItems) selected items, about \(Format.bytes(selection.estimatedBytes))")
        .accessibilityHint("Opens the review screen. Nothing is deleted until you confirm there.")
    }
}
