import Foundation

/// Groups contacts that probably describe the same person.
///
/// Pure and synchronous by design — no `CNContactStore` dependency — so the
/// whole algorithm is unit-testable without touching the user's address book.
///
/// ## Matching rules
///
/// Records are linked through shared *normalised* identifiers, then merged
/// transitively with union-find. Signals, strongest first:
///
/// | Signal                    | Weight | Grouped by default |
/// |---------------------------|--------|--------------------|
/// | Same phone number         | 100    | yes                |
/// | Same email address        | 95     | yes                |
/// | Same name + organisation  | 70     | yes                |
/// | Same name only            | 40     | **no**             |
///
/// Name-only matches are excluded by default. Real address books are full of
/// genuinely distinct people who share a name, and the brief is explicit that
/// same-name alone must not be treated as a duplicate. The option exists so the
/// behaviour is a deliberate choice rather than a hidden assumption.
struct ContactDuplicateEngine {

    var includeNameOnlyMatches: Bool = false

    func findDuplicates(in contacts: [ContactRecord]) -> [ContactDuplicateGroup] {
        guard contacts.count > 1 else { return [] }

        var union = UnionFind(count: contacts.count)

        var phoneIndex: [String: Int] = [:]
        var emailIndex: [String: Int] = [:]
        var nameOrgIndex: [String: Int] = [:]
        var nameIndex: [String: Int] = [:]

        for (position, contact) in contacts.enumerated() {
            for phone in contact.phoneNumbers {
                let key = PhoneNormalizer.normalize(phone)
                // Very short fragments ("12", an extension) are not identifying.
                guard key.count >= 5 else { continue }
                if let existing = phoneIndex[key] {
                    union.union(existing, position)
                } else {
                    phoneIndex[key] = position
                }
            }

            for email in contact.emailAddresses {
                let key = EmailNormalizer.normalize(email)
                guard key.contains("@") else { continue }
                if let existing = emailIndex[key] {
                    union.union(existing, position)
                } else {
                    emailIndex[key] = position
                }
            }

            let nameKey = NameNormalizer.sortedKey(
                given: contact.givenName, family: contact.familyName
            )
            guard !nameKey.isEmpty else { continue }

            let org = NameNormalizer.normalize(contact.organizationName)
            if !org.isEmpty {
                let key = "\(nameKey)|\(org)"
                if let existing = nameOrgIndex[key] {
                    union.union(existing, position)
                } else {
                    nameOrgIndex[key] = position
                }
            }

            if includeNameOnlyMatches {
                if let existing = nameIndex[nameKey] {
                    union.union(existing, position)
                } else {
                    nameIndex[nameKey] = position
                }
            }
        }

        // Collect components.
        var components: [Int: [Int]] = [:]
        for position in contacts.indices {
            components[union.find(position), default: []].append(position)
        }

        var groups: [ContactDuplicateGroup] = []
        for (_, positions) in components where positions.count > 1 {
            let members = positions.map { contacts[$0] }
            let signals = Self.signals(among: members, includeNameOnly: includeNameOnlyMatches)
            guard let strongest = signals.map(\.weight).max() else { continue }
            groups.append(
                ContactDuplicateGroup(
                    id: members.map(\.id).sorted().joined(separator: "|"),
                    members: members.sorted { $0.fieldCount > $1.fieldCount },
                    signals: signals.sorted { $0.weight > $1.weight },
                    score: strongest
                )
            )
        }

        // Strongest and largest first.
        return groups.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.members.count > $1.members.count
        }
    }

    /// Every distinct reason the records in a group are related.
    static func signals(
        among members: [ContactRecord],
        includeNameOnly: Bool
    ) -> [DuplicateSignal] {
        var found = Set<DuplicateSignal>()
        guard members.count > 1 else { return [] }

        for i in 0..<(members.count - 1) {
            for j in (i + 1)..<members.count {
                let a = members[i], b = members[j]

                let aPhones = Set(a.phoneNumbers.map(PhoneNormalizer.normalize).filter { $0.count >= 5 })
                let bPhones = Set(b.phoneNumbers.map(PhoneNormalizer.normalize).filter { $0.count >= 5 })
                if !aPhones.isDisjoint(with: bPhones) { found.insert(.samePhoneNumber) }

                let aEmails = Set(a.emailAddresses.map(EmailNormalizer.normalize).filter { $0.contains("@") })
                let bEmails = Set(b.emailAddresses.map(EmailNormalizer.normalize).filter { $0.contains("@") })
                if !aEmails.isDisjoint(with: bEmails) { found.insert(.sameEmailAddress) }

                let aName = NameNormalizer.sortedKey(given: a.givenName, family: a.familyName)
                let bName = NameNormalizer.sortedKey(given: b.givenName, family: b.familyName)
                if !aName.isEmpty && aName == bName {
                    let aOrg = NameNormalizer.normalize(a.organizationName)
                    let bOrg = NameNormalizer.normalize(b.organizationName)
                    if !aOrg.isEmpty && aOrg == bOrg {
                        found.insert(.sameNameAndOrganization)
                    } else if includeNameOnly {
                        found.insert(.sameNameOnly)
                    }
                }
            }
        }
        return Array(found)
    }
}

/// Disjoint-set with path compression and union by size.
///
/// Needed because duplicates are transitive: if A shares a phone with B and B
/// shares an email with C, all three are one person and must land in a single
/// group rather than two overlapping pairs.
struct UnionFind {
    private var parent: [Int]
    private var size: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        size = Array(repeating: 1, count: count)
    }

    mutating func find(_ element: Int) -> Int {
        var root = element
        while parent[root] != root { root = parent[root] }
        var current = element
        while parent[current] != root {
            let next = parent[current]
            parent[current] = root
            current = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let rootA = find(a), rootB = find(b)
        guard rootA != rootB else { return }
        if size[rootA] < size[rootB] {
            parent[rootA] = rootB
            size[rootB] += size[rootA]
        } else {
            parent[rootB] = rootA
            size[rootA] += size[rootB]
        }
    }
}
