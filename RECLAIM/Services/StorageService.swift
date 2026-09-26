import Foundation

/// Reads device volume capacity through public `URLResourceValues` keys only.
///
/// There is no public API for a per-app or per-category storage breakdown on
/// iOS — the figures in Settings › General › iPhone Storage are not vended to
/// third-party apps. RECLAIM therefore reports whole-volume numbers and is
/// explicit in the UI that "reclaimable" is its own estimate, not a system one.
struct StorageService: Sendable {

    private let volumeURL: URL

    init(volumeURL: URL? = nil) {
        // The Documents directory is guaranteed to exist and sits on the data
        // volume, which is what the user thinks of as their storage.
        self.volumeURL = volumeURL
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    /// Reads the volume. Returns `.unavailable` rather than throwing so the
    /// dashboard can degrade to a neutral state instead of erroring out.
    func snapshot() -> StorageSnapshot {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        do {
            let values = try volumeURL.resourceValues(forKeys: keys)
            guard let total = values.volumeTotalCapacity, total > 0 else {
                return .unavailable
            }
            // `forImportantUsage` reflects what iOS will actually free up for a
            // user-initiated write (it counts purgeable caches), which is the
            // honest "free space" figure. Fall back to the raw value if absent.
            let available: Int64
            if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
                available = important
            } else if let plain = values.volumeAvailableCapacity {
                available = Int64(plain)
            } else {
                return .unavailable
            }
            return StorageSnapshot(
                totalCapacity: Int64(total),
                availableCapacity: min(available, Int64(total)),
                capturedAt: Date()
            )
        } catch {
            return .unavailable
        }
    }

    /// Bytes freed between two readings, floored at zero.
    ///
    /// Only meaningful immediately around a deletion — other processes write to
    /// disk constantly, so a negative or wildly large delta means the reading is
    /// untrustworthy and the caller should fall back to its own estimate.
    static func reclaimedBytes(before: StorageSnapshot, after: StorageSnapshot) -> Int64? {
        guard before.isAvailable, after.isAvailable else { return nil }
        let delta = after.availableCapacity - before.availableCapacity
        guard delta > 0 else { return nil }
        return delta
    }
}
