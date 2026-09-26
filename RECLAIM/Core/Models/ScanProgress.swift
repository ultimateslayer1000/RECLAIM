import Foundation

/// Stages of a full scan, in execution order.
enum ScanPhase: String, CaseIterable, Sendable {
    case idle
    case readingLibrary
    case fingerprinting
    case findingSimilar
    case findingScreenshots
    case measuringVideos
    case readingContacts
    case complete

    var label: String {
        switch self {
        case .idle:               return "Ready to scan"
        case .readingLibrary:     return "Reading your library"
        case .fingerprinting:     return "Finding duplicates"
        case .findingSimilar:     return "Finding similar photos"
        case .findingScreenshots: return "Finding screenshots"
        case .measuringVideos:    return "Measuring large videos"
        case .readingContacts:    return "Checking contacts"
        case .complete:           return "Scan complete"
        }
    }

    var symbol: String {
        switch self {
        case .idle:               return "circle"
        case .readingLibrary:     return "photo.on.rectangle"
        case .fingerprinting:     return "square.on.square"
        case .findingSimilar:     return "wand.and.stars"
        case .findingScreenshots: return "iphone.gen3"
        case .measuringVideos:    return "film.stack"
        case .readingContacts:    return "person.2"
        case .complete:           return "checkmark.circle.fill"
        }
    }

    /// Phases shown in the progress list, excluding terminal states.
    static var workingPhases: [ScanPhase] {
        [.readingLibrary, .fingerprinting, .findingSimilar,
         .findingScreenshots, .measuringVideos, .readingContacts]
    }
}

/// Progress emitted by the scan engine. Streamed to the UI via `AsyncStream`.
struct ScanProgress: Sendable, Equatable {
    var phase: ScanPhase = .idle
    /// 0...1 within the current phase.
    var phaseFraction: Double = 0
    var processedAssets: Int = 0
    var totalAssets: Int = 0

    /// 0...1 across the whole scan, weighting each phase by typical cost.
    var overallFraction: Double {
        let phases = ScanPhase.workingPhases
        guard let index = phases.firstIndex(of: phase) else {
            return phase == .complete ? 1 : 0
        }
        let weights: [Double] = [0.10, 0.30, 0.34, 0.03, 0.18, 0.05]
        let completed = weights[0..<index].reduce(0, +)
        return min(1, completed + weights[index] * phaseFraction)
    }

    var isRunning: Bool { phase != .idle && phase != .complete }
}
