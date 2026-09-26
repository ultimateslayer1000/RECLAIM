import SwiftUI

/// Post-cleanup summary (§21).
///
/// Reports what was *verified* removed, not what was requested. If anything
/// failed, the failures are listed rather than glossed over.
struct CleanupCompleteView: View {

    let outcome: CleanupOutcome
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var celebrate = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.lg) {
                Spacer(minLength: Theme.Space.xl)
                mark
                headline
                if outcome.totalItemsRemoved > 0 { breakdown }
                if outcome.hasFailures { failureCard }
                if outcome.isCompleteSuccess && outcome.totalItemsRemoved > 0 { recoveryNote }
                Spacer(minLength: Theme.Space.lg)
                PrimaryButton(title: "Back to Dashboard") { onDismiss() }
                    .padding(.horizontal, Theme.Space.md)
            }
            .padding(.bottom, Theme.Space.xl)
        }
        .screenBackground()
        .onAppear {
            guard !reduceMotion else { celebrate = true; return }
            withAnimation(Theme.Motion.celebrate.delay(0.1)) { celebrate = true }
        }
    }

    // MARK: - Mark

    private var mark: some View {
        ZStack {
            Circle()
                .fill(Theme.Palette.accentSoft)
                .frame(width: 118, height: 118)
                .scaleEffect(celebrate ? 1 : 0.6)
                .opacity(celebrate ? 1 : 0)

            Image(systemName: symbol)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Theme.Palette.accent)
                .scaleEffect(celebrate ? 1 : 0.4)
                .opacity(celebrate ? 1 : 0)
        }
        .accessibilityHidden(true)
    }

    private var symbol: String {
        if outcome.wasCancelledByUser { return "xmark.circle" }
        if outcome.hasFailures { return "exclamationmark.triangle" }
        return "checkmark.circle"
    }

    private var headline: some View {
        VStack(spacing: Theme.Space.xs) {
            Text(outcome.headline)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.Palette.ink)
                .multilineTextAlignment(.center)

            if outcome.totalItemsRemoved > 0 {
                Text(bytesLine)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.accent)
                if outcome.bytesReclaimedIsEstimate {
                    Text("Estimated — iOS doesn't report exact per-item sizes.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.inkTertiary)
                }
            } else if outcome.wasCancelledByUser {
                Text("You cancelled the deletion. Your selection is still there if you want to try again.")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.lg)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .accessibilityElement(children: .combine)
    }

    private var bytesLine: String {
        "\(Format.bytes(outcome.bytesReclaimed)) reclaimed"
    }

    // MARK: - Breakdown

    private var breakdown: some View {
        Card {
            VStack(spacing: Theme.Space.xs) {
                if outcome.photosRemoved > 0 {
                    row("photo", Format.count(outcome.photosRemoved, singular: "photo") + " removed")
                }
                if outcome.screenshotsRemoved > 0 {
                    row("iphone.gen3", Format.count(outcome.screenshotsRemoved, singular: "screenshot") + " removed")
                }
                if outcome.videosRemoved > 0 {
                    row("film", Format.count(outcome.videosRemoved, singular: "video") + " removed")
                }
                if outcome.contactsRemoved > 0 {
                    row("person.badge.minus", Format.count(outcome.contactsRemoved, singular: "contact") + " removed")
                }
                if outcome.contactsMerged > 0 {
                    row("arrow.triangle.merge", Format.count(outcome.contactsMerged, singular: "contact group") + " merged")
                }
            }
        }
        .padding(.horizontal, Theme.Space.md)
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 24)
            Text(text)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.ink)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Failures

    private var failureCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Palette.destructive)
                    Text("Some items couldn't be removed")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Palette.ink)
                }
                Text("\(outcome.failures.count) of the items you selected are still on your device. They remain selected so you can try again.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(Theme.Palette.hairline)

                ForEach(outcome.failures.prefix(6)) { failure in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(failure.domain.label): \(failure.itemDescription)")
                            .font(Theme.Typography.caption.weight(.semibold))
                            .foregroundStyle(Theme.Palette.ink)
                        Text(failure.reason)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                if outcome.failures.count > 6 {
                    Text("+ \(outcome.failures.count - 6) more")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.inkTertiary)
                }
            }
        }
        .padding(.horizontal, Theme.Space.md)
    }

    private var recoveryNote: some View {
        HStack(alignment: .top, spacing: Theme.Space.xs) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.footnote)
                .foregroundStyle(Theme.Palette.accent)
            Text("Photos and videos are in Recently Deleted for 30 days. Empty that album in the Photos app to free the space immediately.")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.sm)
        .background(Theme.Palette.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .padding(.horizontal, Theme.Space.md)
        .accessibilityElement(children: .combine)
    }
}
