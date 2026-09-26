import XCTest
@testable import RECLAIM

final class NormalizationTests: XCTestCase {

    // MARK: - Phone

    func testPhoneNormalizationIgnoresFormatting() {
        let variants = ["+91 98765 43210", "098765-43210", "(98765) 43210", "91 98765 43210"]
        let keys = Set(variants.map(PhoneNormalizer.normalize))
        XCTAssertEqual(keys.count, 1, "All formats of the same number must reduce to one key")
    }

    func testPhoneNormalizationIsCountryCodeTolerant() {
        XCTAssertEqual(
            PhoneNormalizer.normalize("+1 415 555 2671"),
            PhoneNormalizer.normalize("4155552671")
        )
    }

    func testDistinctNumbersDoNotCollide() {
        XCTAssertNotEqual(
            PhoneNormalizer.normalize("+91 98765 43210"),
            PhoneNormalizer.normalize("+91 98765 43211")
        )
    }

    func testShortCodesComparedWhole() {
        XCTAssertEqual(PhoneNormalizer.normalize("1234"), "1234")
    }

    func testEmptyPhoneYieldsEmptyKey() {
        XCTAssertEqual(PhoneNormalizer.normalize("no digits here"), "")
    }

    // MARK: - Email

    func testEmailNormalizationLowercasesAndTrims() {
        XCTAssertEqual(EmailNormalizer.normalize("  Ronit@Example.COM "), "ronit@example.com")
    }

    func testGmailDotsAndPlusTagsAreEquivalent() {
        XCTAssertEqual(
            EmailNormalizer.normalize("ronit.ladkat+receipts@gmail.com"),
            EmailNormalizer.normalize("ronitladkat@gmail.com")
        )
    }

    func testNonGmailDotsArePreserved() {
        // Most providers treat dots as significant, so we must not strip them.
        XCTAssertNotEqual(
            EmailNormalizer.normalize("ronit.ladkat@outlook.com"),
            EmailNormalizer.normalize("ronitladkat@outlook.com")
        )
    }

    func testMalformedEmailDoesNotCrash() {
        XCTAssertEqual(EmailNormalizer.normalize("not-an-email"), "not-an-email")
        XCTAssertEqual(EmailNormalizer.normalize("@"), "@")
    }

    // MARK: - Name

    func testNameNormalizationStripsDiacriticsAndPunctuation() {
        XCTAssertEqual(NameNormalizer.normalize("José  O'Brien-Smith"), "jose obrien smith")
    }

    func testSortedKeyMakesNameOrderIrrelevant() {
        XCTAssertEqual(
            NameNormalizer.sortedKey(given: "Ronit", family: "Ladkat"),
            NameNormalizer.sortedKey(given: "Ladkat", family: "Ronit")
        )
    }

    func testEmptyNameYieldsEmptyKey() {
        XCTAssertEqual(NameNormalizer.sortedKey(given: "", family: ""), "")
    }
}
