import XCTest
import PGSCore

final class OCRCleanupTests: XCTestCase {
    private let cleaner = OCRTextCleaner()

    func testCollapsesSpacesAndTrimsEachLine() {
        XCTAssertEqual(cleaner.clean("  Hello   there  \n\n  next   line  "), "Hello there\nnext line")
        XCTAssertEqual(cleaner.cleanLine("\u{00A0}Hello\u{200B} "), "Hello")
    }

    func testRemovesSpaceBeforePunctuationAndInsideContractions() {
        XCTAssertEqual(cleaner.cleanLine("Hello , world !"), "Hello, world!")
        XCTAssertEqual(cleaner.cleanLine("Wait ..."), "Wait...")
        XCTAssertEqual(cleaner.cleanLine("don 't"), "don't")
        XCTAssertEqual(cleaner.cleanLine("don ' t"), "don't")
        XCTAssertEqual(cleaner.cleanLine("I 'm"), "I'm")
        XCTAssertEqual(cleaner.cleanLine("I ' m"), "I'm")
        XCTAssertEqual(cleaner.cleanLine("we 're home"), "we're home")
        XCTAssertEqual(cleaner.cleanLine("l\u{2019}m"), "I'm")
        XCTAssertEqual(cleaner.cleanLine("( Hello )"), "(Hello)")
    }

    func testApostropheThatStartsAWordKeepsItsSpace() {
        XCTAssertEqual(cleaner.cleanLine("it 'cause I know you"), "it 'cause I know you")
        XCTAssertEqual(cleaner.cleanLine("see 'em"), "see 'em")
        XCTAssertEqual(cleaner.cleanLine("'em"), "'em")
        XCTAssertEqual(cleaner.cleanLine("'til later"), "'til later")
        XCTAssertEqual(cleaner.cleanLine("wait 'til dawn"), "wait 'til dawn")
        XCTAssertEqual(cleaner.cleanLine("rock 'n' roll"), "rock 'n' roll")
    }

    func testEnglishPronounFixesLeaveRealWordsAlone() {
        XCTAssertEqual(cleaner.cleanLine("l think l'll go"), "I think I'll go")
        XCTAssertEqual(cleaner.cleanLine("l'm l've l'd lm"), "I'm I've I'd I'm")
        XCTAssertEqual(cleaner.cleanLine("lt is fine lf so"), "It is fine If so")
        XCTAssertEqual(cleaner.cleanLine("| am"), "I am")
        XCTAssertEqual(cleaner.cleanLine("dollar Illinois feel hello I'll"), "dollar Illinois feel hello I'll")
        XCTAssertEqual(cleaner.cleanLine("l'amour"), "l'amour")
    }

    func testStrayPunctuation() {
        XCTAssertEqual(cleaner.cleanLine("• Hello*"), "Hello")
        XCTAssertEqual(cleaner.cleanLine(".Hello"), "Hello")
        XCTAssertEqual(cleaner.cleanLine("..."), "...")
        XCTAssertEqual(cleaner.cleanLine("...Hello"), "...Hello")
        XCTAssertEqual(cleaner.cleanLine("?"), "?")
        XCTAssertEqual(cleaner.cleanLine("!"), "!")
        XCTAssertEqual(cleaner.cleanLine("."), "")
        XCTAssertEqual(cleaner.cleanLine("*"), "")
        XCTAssertEqual(cleaner.clean("Hello\n.\nthere"), "Hello\nthere")
    }

    func testOtherLanguagesDoNotRewriteL() {
        let french = OCRTextCleaner(fixEnglishPronounI: false)
        XCTAssertEqual(french.cleanLine("l pense"), "l pense")
        XCTAssertEqual(french.cleanLine("| pense"), "pense")
        XCTAssertFalse(OCRTextCleaner.usesEnglish(["fr-FR"]))
        XCTAssertTrue(OCRTextCleaner.usesEnglish(["en-US"]))
        XCTAssertTrue(OCRTextCleaner.usesEnglish(["fr-FR", "en"]))
        XCTAssertTrue(OCRTextCleaner.usesEnglish([]))
    }
}
