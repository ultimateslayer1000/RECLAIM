import SwiftUI

/// RECLAIM design tokens.
///
/// Brand: premium, calm, utility-focused. Warm off-white ground, near-black ink,
/// a single teal accent. Destructive actions get their own hue so they can never
/// be confused with the accent.
enum Theme {

    // MARK: - Palette

    enum Palette {
        /// Warm off-white page background.
        static let canvas = Color("Canvas", bundle: .main)
        /// Card surface, sits just above the canvas.
        static let surface = Color("Surface", bundle: .main)
        /// Near-black primary ink.
        static let ink = Color("Ink", bundle: .main)
        /// Muted secondary ink for supporting copy.
        static let inkSecondary = Color("InkSecondary", bundle: .main)
        /// Faint ink for tertiary detail.
        static let inkTertiary = Color("InkTertiary", bundle: .main)
        /// The single brand accent.
        static let accent = Color("Accent", bundle: .main)
        /// Low-emphasis accent wash for fills and badges.
        static let accentSoft = Color("AccentSoft", bundle: .main)
        /// Reserved exclusively for destructive affordances.
        static let destructive = Color("Destructive", bundle: .main)
        /// Hairline separators and card borders.
        static let hairline = Color("Hairline", bundle: .main)
        /// Track colour behind the storage ring.
        static let ringTrack = Color("RingTrack", bundle: .main)
    }

    // MARK: - Spacing

    /// 4pt base scale. Generous by default — the brand is calm, not dense.
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    // MARK: - Radius

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 14
        static let lg: CGFloat = 20
        static let pill: CGFloat = 999
    }

    // MARK: - Typography

    /// All type is system SF Pro so Dynamic Type works with no extra plumbing.
    enum Typography {
        static let display = Font.system(size: 40, weight: .semibold, design: .rounded)
        static let title = Font.system(.title2, design: .rounded).weight(.semibold)
        static let headline = Font.system(.headline, design: .rounded)
        static let body = Font.system(.body)
        static let callout = Font.system(.callout)
        static let footnote = Font.system(.footnote)
        static let caption = Font.system(.caption)
        /// Small all-caps section label.
        static let overline = Font.system(.caption, design: .rounded).weight(.semibold)
    }

    // MARK: - Elevation

    enum Shadow {
        static let card = Color.black.opacity(0.05)
        static let cardRadius: CGFloat = 12
        static let cardY: CGFloat = 4
    }

    // MARK: - Motion

    enum Motion {
        static let standard = Animation.smooth(duration: 0.28)
        static let quick = Animation.smooth(duration: 0.18)
        /// Used only by the cleanup-complete celebration.
        static let celebrate = Animation.spring(response: 0.55, dampingFraction: 0.7)
    }

    /// Minimum tap target, per Apple HIG accessibility guidance.
    static let minimumTapTarget: CGFloat = 44
}
