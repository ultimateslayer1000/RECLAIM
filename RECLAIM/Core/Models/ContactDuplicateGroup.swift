import Foundation

/// A `Sendable` snapshot of the contact fields RECLAIM actually needs.
/// We deliberately fetch a narrow key set — see `ContactService.keysToFetch`.
struct ContactRecord: Identifiable, Hashable, Sendable {
    let id: String          // CNContact.identifier
    let givenName: String
    let familyName: String
    let organizationName: String
    let phoneNumbers: [String]
    let emailAddresses: [String]
    let hasImage: Bool
    /// Number of populated fields — used to pick the richest record to keep.
    var fieldCount: Int {
        var n = 0
        if !givenName.isEmpty { n += 1 }
        if !familyName.isEmpty { n += 1 }
        if !organizationName.isEmpty { n += 1 }
        n += phoneNumbers.count
        n += emailAddresses.count
        if hasImage { n += 1 }
        return n
    }

    var displayName: String {
        let full = [givenName, familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !full.isEmpty { return full }
        if !organizationName.isEmpty { return organizationName }
        if let phone = phoneNumbers.first { return phone }
        if let email = emailAddresses.first { return email }
        return "No Name"
    }

    var initials: String {
        let letters = [givenName, familyName]
            .filter { !$0.isEmpty }
            .compactMap { $0.first }
            .map(String.init)
        if letters.isEmpty {
            return organizationName.first.map { String($0).uppercased() } ?? "?"
        }
        return letters.joined().uppercased()
    }
}

/// Why two contacts were grouped. Ordered by strength.
enum DuplicateSignal: String, Sendable, Comparable {
    case samePhoneNumber
    case sameEmailAddress
    case sameNameAndOrganization
    case sameNameOnly

    var weight: Int {
        switch self {
        case .samePhoneNumber:          return 100
        case .sameEmailAddress:         return 95
        case .sameNameAndOrganization:  return 70
        case .sameNameOnly:             return 40
        }
    }

    var label: String {
        switch self {
        case .samePhoneNumber:         return "Same phone number"
        case .sameEmailAddress:        return "Same email address"
        case .sameNameAndOrganization: return "Same name and company"
        case .sameNameOnly:            return "Same name only"
        }
    }

    static func < (lhs: DuplicateSignal, rhs: DuplicateSignal) -> Bool {
        lhs.weight < rhs.weight
    }
}

enum DuplicateConfidence: String, Sendable {
    case high, medium, low

    var label: String {
        switch self {
        case .high:   return "Very likely duplicate"
        case .medium: return "Likely duplicate"
        case .low:    return "Possible duplicate"
        }
    }

    static func from(score: Int) -> DuplicateConfidence {
        if score >= 95 { return .high }
        if score >= 65 { return .medium }
        return .low
    }
}

/// A set of contacts believed to describe the same person.
struct ContactDuplicateGroup: Identifiable, Hashable, Sendable {
    let id: String
    let members: [ContactRecord]
    /// Every distinct reason these records were linked, strongest first.
    let signals: [DuplicateSignal]
    /// Strongest signal weight in the group.
    let score: Int

    var confidence: DuplicateConfidence { .from(score: score) }

    /// Plain-English justification shown on the card, e.g. "Same phone number".
    var reasonText: String {
        signals.map(\.label).joined(separator: " · ")
    }

    /// The record we suggest keeping: the one carrying the most information.
    /// Ties break toward the record with an image, then the lowest identifier
    /// so the choice is deterministic across launches.
    var suggestedKeepID: String {
        members.max { a, b in
            if a.fieldCount != b.fieldCount { return a.fieldCount < b.fieldCount }
            if a.hasImage != b.hasImage { return !a.hasImage && b.hasImage }
            return a.id > b.id
        }?.id ?? members.first?.id ?? ""
    }

    /// The union of every field across the group — what a merge would retain.
    var mergedPreview: ContactRecord {
        let keeper = members.first { $0.id == suggestedKeepID } ?? members[0]
        var phones: [String] = []
        var emails: [String] = []
        for member in members {
            for phone in member.phoneNumbers
            where !phones.contains(where: { PhoneNormalizer.normalize($0) == PhoneNormalizer.normalize(phone) }) {
                phones.append(phone)
            }
            for email in member.emailAddresses
            where !emails.contains(where: { EmailNormalizer.normalize($0) == EmailNormalizer.normalize(email) }) {
                emails.append(email)
            }
        }
        return ContactRecord(
            id: keeper.id,
            givenName: keeper.givenName.isEmpty
                ? (members.first { !$0.givenName.isEmpty }?.givenName ?? "")
                : keeper.givenName,
            familyName: keeper.familyName.isEmpty
                ? (members.first { !$0.familyName.isEmpty }?.familyName ?? "")
                : keeper.familyName,
            organizationName: keeper.organizationName.isEmpty
                ? (members.first { !$0.organizationName.isEmpty }?.organizationName ?? "")
                : keeper.organizationName,
            phoneNumbers: phones,
            emailAddresses: emails,
            hasImage: members.contains { $0.hasImage }
        )
    }
}
