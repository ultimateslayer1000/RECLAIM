import Foundation

/// The four cleanup surfaces the app exposes. Drives the dashboard cards,
/// the review sections and the completion summary.
enum CleanupCategory: String, CaseIterable, Identifiable, Sendable {
    case similarPhotos
    case screenshots
    case largeVideos
    case duplicateContacts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .similarPhotos:     return "Similar Photos"
        case .screenshots:       return "Screenshots"
        case .largeVideos:       return "Large Videos"
        case .duplicateContacts: return "Duplicate Contacts"
        }
    }

    var symbol: String {
        switch self {
        case .similarPhotos:     return "square.on.square"
        case .screenshots:       return "iphone.gen3"
        case .largeVideos:       return "film.stack"
        case .duplicateContacts: return "person.2"
        }
    }

    var blurb: String {
        switch self {
        case .similarPhotos:     return "Near-identical shots, grouped"
        case .screenshots:       return "Captures you probably don't need"
        case .largeVideos:       return "Your biggest files, largest first"
        case .duplicateContacts: return "Likely repeated entries"
        }
    }

    /// Contacts free no meaningful disk space, so their card reports a count
    /// instead of a byte total.
    var measuresBytes: Bool { self != .duplicateContacts }
}
