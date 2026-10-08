import XCTest
@testable import IELTS_Vocab

final class DeepSeekResponseDecodingTests: XCTestCase {
    func testIELTSOnlyResponseRequiresOnlySentence() throws {
        let data = #"{"ielts_examples":[{"sentence":"Cities need resilient infrastructure."}]}"#
            .data(using: .utf8)!

        let response = try JSONDecoder().decode(IELTSOnlyResponse.self, from: data)

        XCTAssertEqual(response.ielts_examples?.first?.sentence,
                       "Cities need resilient infrastructure.")
    }

    func testEnhancedResponseAcceptsOmittedSourceAndYear() throws {
        let data = #"{"ielts_examples":[{"sentence":"The policy may reduce inequality."}]}"#
            .data(using: .utf8)!

        let response = try JSONDecoder().decode(EnhancedEntry.self, from: data)

        XCTAssertEqual(response.ielts_examples?.first?.sentence,
                       "The policy may reduce inequality.")
    }

    func testExtraSourceAndNumericYearAreIgnored() throws {
        let data = #"{"ielts_examples":[{"sentence":"Demand remained stable.","source":"model","year":2026}]}"#
            .data(using: .utf8)!

        let response = try JSONDecoder().decode(IELTSOnlyResponse.self, from: data)

        XCTAssertEqual(response.ielts_examples?.first?.sentence, "Demand remained stable.")
    }

    func testMissingSentenceStillFails() {
        let data = #"{"ielts_examples":[{"source":"model"}]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(IELTSOnlyResponse.self, from: data))
    }
}
