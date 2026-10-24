import XCTest
import PGSCore

final class OCRTests: XCTestCase {
    func testRecognizerCanBePluggedInWithoutAnImplementationInCore() async throws {
        let file = makeShow(pts: 90_000, palette: [.limitedWhite(1)], objects: [singlePixelObject()])
            + makeClear(pts: 180_000)
        let cues = try PGSDecoder().decode(file)
        let recognizer = StubRecognizer()
        let transcribed = try await recognizer.transcribe(cues, languages: ["en-US"])
        XCTAssertEqual(transcribed.count, 1)
        XCTAssertEqual(transcribed[0].text, "Hello")
        XCTAssertEqual(transcribed[0].startPTS, 90_000)
        XCTAssertEqual(transcribed[0].endPTS, 180_000)
        XCTAssertEqual(recognizer.seenLanguages, ["en-US"])
        XCTAssertEqual(recognizer.seenWidth, 1)
        XCTAssertEqual(PGSCoreInfo.version, "0.1.0")
    }
}

private final class StubRecognizer: SubtitleRecognizing, @unchecked Sendable {
    var seenLanguages: [String] = []
    var seenWidth = 0

    func recognize(image: SubtitleImage, languages: [String]) async throws -> OCRResult {
        seenLanguages = languages
        seenWidth = image.width
        return OCRResult(text: "Hello", confidence: 0.9)
    }
}
