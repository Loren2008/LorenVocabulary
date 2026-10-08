import XCTest
@testable import IELTS_Vocab

final class WordNormalizerTests: XCTestCase {
    func testNormalizesCaseWhitespaceAndWrapperPunctuation() {
        XCTAssertEqual(WordNormalizer.normalize("  \u{201C}Athens,\u{201D}\n"), "athens")
        XCTAssertEqual(WordNormalizer.normalize("(state\u{2011}of\u{2011}the\u{2011}art)"), "state-of-the-art")
    }

    func testPreservesInternalApostrophesAndPhraseSpaces() {
        XCTAssertEqual(WordNormalizer.normalize("DON\u{2019}T"), "don't")
        XCTAssertEqual(WordNormalizer.normalize(" comparative\tadvantage "), "comparative advantage")
    }

    func testRejectsPunctuationOnlySelection() {
        XCTAssertEqual(WordNormalizer.normalize("...\u{2014}\u{2014}"), "")
        XCTAssertEqual(WordNormalizer.lookupCandidates("...\u{2014}\u{2014}"), [])
    }

    func testUsesNFKCForFullWidthAndCompatibilityCharacters() {
        XCTAssertEqual(WordNormalizer.normalize("Ｃ＋＋"), "c++")
        XCTAssertEqual(WordNormalizer.normalize("ﬃcient"), "fficient")
        XCTAssertEqual(WordNormalizer.normalize("ＤＯＮ\u{ff07}Ｔ"), "don't")
    }

    func testLookupCandidatesPreserveLegalBoundarySymbolsBeforeFallback() {
        XCTAssertEqual(WordNormalizer.lookupCandidates(".NET"), [".net", "net"])
        XCTAssertEqual(WordNormalizer.lookupCandidates("C++"), ["c++", "c"])
        XCTAssertEqual(WordNormalizer.lookupCandidates("C#"), ["c#", "c"])
        XCTAssertEqual(WordNormalizer.lookupCandidates("#HashTag"), ["#hashtag", "hashtag"])
        XCTAssertEqual(WordNormalizer.lookupCandidates("'Tis"), ["'tis", "tis"])

        XCTAssertEqual(WordNormalizer.lookupCandidates("(C++)"), ["(c++)", "c++", "c"])
        XCTAssertEqual(
            WordNormalizer.lookupCandidates("\u{201C}Athens,\u{201D}"),
            ["\u{201C}athens,\u{201D}", "athens"]
        )
    }
}
