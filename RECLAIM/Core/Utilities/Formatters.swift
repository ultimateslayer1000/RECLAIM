import Foundation

enum Format {
    /// Byte counts use the `.file` convention (base 1000, matching iOS Settings)
    /// so RECLAIM's numbers line up with what the user sees in Storage.
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "0 KB" }
        return byteFormatter.string(fromByteCount: value)
    }

    /// Compact duration: 1:05, 12:04, 1:02:33.
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func date(_ date: Date?) -> String {
        guard let date else { return "Unknown date" }
        return dateFormatter.string(from: date)
    }

    /// "3 photos" / "1 photo"
    static func count(_ n: Int, singular: String, plural: String? = nil) -> String {
        let word = n == 1 ? singular : (plural ?? singular + "s")
        return "\(n) \(word)"
    }

    static func megapixels(_ candidate: PhotoCandidate) -> String {
        guard candidate.pixelCount > 0 else { return "Unknown size" }
        return String(format: "%.1f MP", candidate.megapixels)
    }
}
