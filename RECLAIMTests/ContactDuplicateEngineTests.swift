import XCTest
@testable import RECLAIM

final class ContactDuplicateEngineTests: XCTestCase {

    private func contact(
        _ id: String,
        given: String = "",
        family: String = "",
        org: String = "",
        phones: [String] = [],
        emails: [String] = [],
        hasImage: Bool = false
    ) -> ContactRecord {
        ContactRecord(id: id, givenName: given, familyName: family,
                      organizationName: org, phoneNumbers: phones,
                      emailAddresses: emails, hasImage: hasImage)
    }

    // MARK: - Strong signals

    func testSamePhoneNumberGroupsContacts() {
        let engine = ContactDuplicateEngine()
        let groups = engine.findDuplicates(in: [
            contact("a", given: "Ronit", phones: ["+91 98765 43210"]),
            contact("b", given: "R", family: "Ladkat", phones: ["09876543210"])
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].signals.contains(.samePhoneNumber))
        XCTAssertEqual(groups[0].confidence, .high)
    }

    func testSameEmailGroupsContacts() {
        let engine = ContactDuplicateEngine()
        let groups = engine.findDuplicates(in: [
            contact("a", given: "Anita", emails: ["anita@example.com"]),
            contact("b", given: "Anita", family: "K", emails: ["ANITA@example.com"])
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].signals.contains(.sameEmailAddress))
    }

    // MARK: - Weak signals

    func testSameNameOnlyIsNotGroupedByDefault() {
        // Explicitly required: same name alone must not mark a duplicate.
        let engine = ContactDuplicateEngine()
        let groups = engine.findDuplicates(in: [
            contact("a", given: "Amit", family: "Sharma"),
            contact("b", given: "Amit", family: "Sharma")
        ])
        XCTAssertTrue(groups.isEmpty)
    }

    func testSameNameOnlyIsGroupedWhenExplicitlyEnabled() {
        var engine = ContactDuplicateEngine()
        engine.includeNameOnlyMatches = true
        let groups = engine.findDuplicates(in: [
            contact("a", given: "Amit", family: "Sharma"),
            contact("b", given: "Amit", family: "Sharma")
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].confidence, .low)
    }

    func testSameNameAndOrganizationIsAModerateSignal() {
        let engine = ContactDuplicateEngine()
        let groups = engine.findDuplicates(in: [
            contact("a", given: "Amit", family: "Sharma", org: "Panama Group"),
            contact("b", given: "Amit", family: "Sharma", org: "panama group")
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].confidence, .medium)
        XCTAssertTrue(groups[0].signals.contains(.sameNameAndOrganization))
    }

    // MARK: - Transitivity

    func testTransitiveMatchesFormOneGroupNotTwo() {
        // A shares a phone with B; B shares an email with C. All three are one
        // person and must land in a single group.
        let engine = ContactDuplicateEngine()
        let groups = engine.findDuplicates(in: [
            contact("a", given: "Ronit", phones: ["9876543210"]),
            contact("b", given: "Ronit", phones: ["9876543210"], emails: ["r@example.com"]),
            contact("c", given: "R", emails: ["r@example.com"])
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].members.count, 3)
    }

    // MARK: - Non-duplicates

    func testUnrelatedContactsAreNotGrouped() {
        let engine = ContactDuplicateEngine()
        let groups = engine.findDuplicates(in: [
            contact("a", given: "Ronit", phones: ["1111111111"]),
            contact("b", given: "Anita", phones: ["2222222222"]),
            contact("c", given: "Vikram", emails: ["v@example.com"])
        ])
        XCTAssertTrue(groups.isEmpty)
    }

    func testEmptyAndSingleInputProduceNoGroups() {
        let engine = ContactDuplicateEngine()
        XCTAssertTrue(engine.findDuplicates(in: []).isEmpty)
        XCTAssertTrue(engine.findDuplicates(in: [contact("a", given: "Solo")]).isEmpty)
    }

    func testVeryShortPhoneFragmentsDoNotLinkContacts() {
        // A 4-digit extension shared by two records is not identifying.
        let engine = ContactDuplicateEngine()
        let groups = engine.findDuplicates(in: [
            contact("a", given: "Front Desk", phones: ["1234"]),
            contact("b", given: "Reception", phones: ["1234"])
        ])
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - Merge preview

    func testMergedPreviewUnionsFieldsWithoutDuplicates() {
        let engine = ContactDuplicateEngine()
        let groups = engine.findDuplicates(in: [
            contact("a", given: "Ronit", family: "Ladkat",
                    phones: ["+91 98765 43210"], emails: ["ronit@example.com"]),
            contact("b", given: "Ronit", org: "Panama Group",
                    phones: ["098765-43210", "+91 99999 11111"],
                    emails: ["ronit@example.com", "work@example.com"])
        ])
        XCTAssertEqual(groups.count, 1)
        let merged = groups[0].mergedPreview

        // The same number in two formats must collapse to one entry.
        XCTAssertEqual(merged.phoneNumbers.count, 2)
        XCTAssertEqual(merged.emailAddresses.count, 2)
        XCTAssertEqual(merged.familyName, "Ladkat", "Non-empty fields survive the merge")
        XCTAssertEqual(merged.organizationName, "Panama Group")
    }

    func testSuggestedKeepPrefersRicherRecord() {
        let engine = ContactDuplicateEngine()
        let groups = engine.findDuplicates(in: [
            contact("sparse", given: "Ronit", phones: ["9876543210"]),
            contact("rich", given: "Ronit", family: "Ladkat", org: "Panama",
                    phones: ["9876543210"], emails: ["r@example.com"], hasImage: true)
        ])
        XCTAssertEqual(groups[0].suggestedKeepID, "rich")
    }

    func testSuggestedKeepIsDeterministic() {
        let engine = ContactDuplicateEngine()
        let input = [
            contact("b", given: "Sam", phones: ["5555555555"]),
            contact("a", given: "Sam", phones: ["5555555555"])
        ]
        let first = engine.findDuplicates(in: input)[0].suggestedKeepID
        let second = engine.findDuplicates(in: input)[0].suggestedKeepID
        XCTAssertEqual(first, second)
    }

    // MARK: - Union-find

    func testUnionFindMergesComponents() {
        var uf = UnionFind(count: 5)
        uf.union(0, 1)
        uf.union(1, 2)
        uf.union(3, 4)
        XCTAssertEqual(uf.find(0), uf.find(2))
        XCTAssertEqual(uf.find(3), uf.find(4))
        XCTAssertNotEqual(uf.find(0), uf.find(3))
    }
}
