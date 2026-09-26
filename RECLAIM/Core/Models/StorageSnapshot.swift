import Foundation

/// A point-in-time reading of the device volume, taken from public
/// `URLResourceValues` keys. Never cached for long — re-read after cleanup.
struct StorageSnapshot: Equatable, Sendable {
    let totalCapacity: Int64
    let availableCapacity: Int64
    let capturedAt: Date

    var usedCapacity: Int64 { max(0, totalCapacity - availableCapacity) }

    /// 0...1. Returns 0 rather than NaN when capacity is unknown.
    var usedFraction: Double {
        guard totalCapacity > 0 else { return 0 }
        return min(1, max(0, Double(usedCapacity) / Double(totalCapacity)))
    }

    static let unavailable = StorageSnapshot(
        totalCapacity: 0, availableCapacity: 0, capturedAt: .distantPast
    )

    var isAvailable: Bool { totalCapacity > 0 }
}
