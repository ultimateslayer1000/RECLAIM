import SwiftUI

/// Circular storage visualisation.
///
/// Two concentric arcs on one track: the outer arc is storage actually in use,
/// the inner accent arc is what RECLAIM estimates it could reclaim. Keeping them
/// visually distinct is a requirement (§8) — device storage and reclaimable
/// space are different claims and must never read as one number.
struct StorageRing: View {

    let snapshot: StorageSnapshot
    let reclaimableBytes: Int64
    var isIndeterminate: Bool = false

    @State private var animatedUsed: Double = 0
    @State private var animatedReclaim: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var usedFraction: Double { snapshot.usedFraction }

    /// Reclaimable, expressed against total capacity so both arcs share a scale.
    private var reclaimFraction: Double {
        guard snapshot.totalCapacity > 0 else { return 0 }
        return min(usedFraction, Double(reclaimableBytes) / Double(snapshot.totalCapacity))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.Palette.ringTrack, style: .init(lineWidth: 18, lineCap: .round))

            Circle()
                .trim(from: 0, to: animatedUsed)
                .stroke(Theme.Palette.ink, style: .init(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))

            // Reclaimable sits inside, so it reads as a subset of what's used.
            Circle()
                .inset(by: 15)
                .trim(from: 0, to: animatedReclaim)
                .stroke(Theme.Palette.accent, style: .init(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))

            centreLabel
        }
        .frame(width: 188, height: 188)
        .onAppear { animate() }
        .onChange(of: usedFraction) { _, _ in animate() }
        .onChange(of: reclaimFraction) { _, _ in animate() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var centreLabel: some View {
        VStack(spacing: 2) {
            if snapshot.isAvailable {
                Text(Format.bytes(snapshot.usedCapacity))
                    .font(Theme.Typography.display)
                    .foregroundStyle(Theme.Palette.ink)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("of \(Format.bytes(snapshot.totalCapacity)) used")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Palette.inkSecondary)
            } else {
                Text("—")
                    .font(Theme.Typography.display)
                    .foregroundStyle(Theme.Palette.inkTertiary)
                Text("Storage unavailable")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Palette.inkSecondary)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
    }

    private var accessibilityDescription: String {
        guard snapshot.isAvailable else { return "Device storage unavailable" }
        var parts = [
            "\(Format.bytes(snapshot.usedCapacity)) used of \(Format.bytes(snapshot.totalCapacity))",
            "\(Format.bytes(snapshot.availableCapacity)) free"
        ]
        if reclaimableBytes > 0 {
            parts.append("up to \(Format.bytes(reclaimableBytes)) can be reclaimed")
        }
        return parts.joined(separator: ", ")
    }

    private func animate() {
        guard !reduceMotion else {
            animatedUsed = usedFraction
            animatedReclaim = reclaimFraction
            return
        }
        withAnimation(Theme.Motion.standard) {
            animatedUsed = usedFraction
        }
        withAnimation(Theme.Motion.standard.delay(0.12)) {
            animatedReclaim = reclaimFraction
        }
    }
}

/// Legend clarifying the two arcs.
struct StorageLegend: View {
    let snapshot: StorageSnapshot
    let reclaimableBytes: Int64

    var body: some View {
        HStack(spacing: Theme.Space.lg) {
            item(color: Theme.Palette.ink, label: "Used",
                 value: Format.bytes(snapshot.usedCapacity))
            item(color: Theme.Palette.ringTrack, label: "Free",
                 value: Format.bytes(snapshot.availableCapacity))
            item(color: Theme.Palette.accent, label: "Reclaimable",
                 value: Format.bytes(reclaimableBytes))
        }
    }

    private func item(color: Color, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.inkSecondary)
            }
            Text(value)
                .font(Theme.Typography.callout.weight(.semibold))
                .foregroundStyle(Theme.Palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}
