import Contacts
import Foundation

/// Reads and writes the address book.
///
/// Fetches a deliberately narrow key set — names, organisation, phones, emails
/// and a "has image" flag. Notes, birthdays, postal addresses, social profiles
/// and relations are never requested, because RECLAIM has no use for them and
/// requesting less is the privacy-correct default.
struct ContactService: Sendable {

    /// The only keys RECLAIM ever asks for.
    static var keysToFetch: [CNKeyDescriptor] {
        [
            CNContactIdentifierKey,
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
            CNContactImageDataAvailableKey
        ].map { $0 as CNKeyDescriptor }
    }

    /// Keys required to *mutate* a contact. `CNContactVCardSerialization` keys
    /// are needed so an existing record can be turned into a mutable copy
    /// without dropping data we never read.
    static var keysForMutation: [CNKeyDescriptor] {
        keysToFetch + [CNContactVCardSerialization.descriptorForRequiredKeys()]
    }

    func fetchContacts() throws -> [ContactRecord] {
        let store = CNContactStore()
        let request = CNContactFetchRequest(keysToFetch: Self.keysToFetch)
        request.unifyResults = true
        request.sortOrder = .givenName

        var records: [ContactRecord] = []
        try store.enumerateContacts(with: request) { contact, _ in
            records.append(Self.record(from: contact))
        }
        return records
    }

    static func record(from contact: CNContact) -> ContactRecord {
        ContactRecord(
            id: contact.identifier,
            givenName: contact.givenName,
            familyName: contact.familyName,
            organizationName: contact.organizationName,
            phoneNumbers: contact.phoneNumbers.map { $0.value.stringValue },
            emailAddresses: contact.emailAddresses.map { $0.value as String },
            hasImage: contact.imageDataAvailable
        )
    }

    /// Re-reads specific contacts. Used after a write to verify the change
    /// actually landed rather than trusting the save request.
    func existingIdentifiers(from ids: [String]) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let store = CNContactStore()
        let predicate = CNContact.predicateForContacts(withIdentifiers: ids)
        do {
            let found = try store.unifiedContacts(
                matching: predicate, keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
            )
            return Set(found.map(\.identifier))
        } catch {
            return []
        }
    }

    /// Fetches one mutable contact by identifier.
    func mutableContact(id: String) throws -> CNMutableContact? {
        let store = CNContactStore()
        let predicate = CNContact.predicateForContacts(withIdentifiers: [id])
        let matches = try store.unifiedContacts(matching: predicate, keysToFetch: Self.keysForMutation)
        // `unifyResults` can return a unified record whose identifier differs
        // from the backing one; guard so we only ever mutate an exact match.
        guard let contact = matches.first(where: { $0.identifier == id }) ?? matches.first else {
            return nil
        }
        return contact.mutableCopy() as? CNMutableContact
    }
}
