import XCTest
@testable import IELTS_Vocab

final class DatabaseJSONParsingTests: XCTestCase {
    func testMixedArrayKeepsValidObjectsAndSkipsInvalidItems() {
        let json = """
        [
          {"pos":"noun","meaning":"名词义"},
          "legacy-bad-item",
          42,
          null,
          {"pos":"verb","meaning":"动词义","year":2026},
          ["nested-array"]
        ]
        """

        let parsed = DatabaseService.parseJSONObjectArray(json)

        XCTAssertEqual(parsed?.count, 2)
        XCTAssertEqual(parsed?[0]["pos"], "noun")
        XCTAssertEqual(parsed?[1]["meaning"], "动词义")
        XCTAssertEqual(parsed?[1]["year"], "2026")
    }

    func testTopLevelObjectRemainsBackwardCompatible() {
        let parsed = DatabaseService.parseJSONObjectArray(
            #"{"sentence":"An IELTS-style sentence.","year":2025}"#
        )

        XCTAssertEqual(parsed?.first?["sentence"], "An IELTS-style sentence.")
        XCTAssertEqual(parsed?.first?["year"], "2025")
    }

    func testArrayWithoutObjectsIsRejected() {
        XCTAssertNil(DatabaseService.parseJSONObjectArray(#"["bad", 1, null]"#))
    }

    func testLegacyIELTSSourceIsShownAsUnverifiedWithoutRewritingStoredJSON() {
        let display = DatabaseService.ieltsDisplayMetadata(
            storedSource: "剑桥雅思14 Test 2",
            storedYear: "2019",
            contentAuthenticity: "legacy_unverified"
        )

        XCTAssertEqual(display.source, "历史数据 · 来源未核验")
        XCTAssertNil(display.year)
    }

    func testGeneratedIELTSSourceUsesStyleLabel() {
        let display = DatabaseService.ieltsDisplayMetadata(
            storedSource: "unexpected model field",
            storedYear: "2026",
            contentAuthenticity: "generated_style"
        )

        XCTAssertEqual(display.source, "AI-generated IELTS-style example")
        XCTAssertNil(display.year)
    }

    func testDatabaseWithoutAuthenticityMetadataKeepsLegacyCompatibility() {
        let display = DatabaseService.ieltsDisplayMetadata(
            storedSource: "IELTS",
            storedYear: "2020",
            contentAuthenticity: nil
        )

        XCTAssertEqual(display.source, "IELTS")
        XCTAssertEqual(display.year, "2020")
    }
}
