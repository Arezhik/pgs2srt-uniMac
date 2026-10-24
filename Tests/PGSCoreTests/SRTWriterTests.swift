import XCTest
import PGSCore

final class SRTWriterTests: XCTestCase {
    func testTimestampRounding() {
        XCTAssertEqual(SRTWriter.timestamp(pts: 0), "00:00:00,000")
        XCTAssertEqual(SRTWriter.timestamp(pts: 44), "00:00:00,000")
        XCTAssertEqual(SRTWriter.timestamp(pts: 45), "00:00:00,001")
        XCTAssertEqual(SRTWriter.timestamp(pts: 90), "00:00:00,001")
        XCTAssertEqual(SRTWriter.timestamp(pts: 90_000), "00:00:01,000")
        XCTAssertEqual(SRTWriter.timestamp(pts: 5_400_000), "00:01:00,000")
        XCTAssertEqual(SRTWriter.timestamp(pts: 324_000_000), "01:00:00,000")
    }

    func testNumberingCRLFAndMultilineText() throws {
        let cues = [
            SRTCue(startPTS: 90_000, endPTS: 180_000, text: "Hello"),
            SRTCue(startPTS: 270_000, endPTS: 360_000, text: "Line one\nLine two")
        ]
        let text = try SRTWriter().write(cues)
        let expected = "1\r\n00:00:01,000 --> 00:00:02,000\r\nHello\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nLine one\r\nLine two\r\n"
        XCTAssertEqual(text, expected)
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    func testLFModeAndCarriageReturnNormalization() throws {
        let text = try SRTWriter(lineEnding: .lf).write([
            SRTCue(startPTS: 0, endPTS: 90_000, text: "A\r\nB\rC\n")
        ])
        XCTAssertEqual(text, "1\n00:00:00,000 --> 00:00:01,000\nA\nB\nC\n")
        XCTAssertFalse(text.contains("\r"))
    }

    func testEmptyListAndZeroDurationAndEndBeforeStart() throws {
        XCTAssertEqual(try SRTWriter().write([]), "")
        let zero = try SRTWriter().write([SRTCue(startPTS: 10, endPTS: 10, text: "")])
        XCTAssertEqual(zero, "1\r\n00:00:00,000 --> 00:00:00,000\r\n\r\n")
        XCTAssertThrowsError(try SRTWriter().write([SRTCue(startPTS: 20, endPTS: 10, text: "nope")])) { error in
            XCTAssertEqual(error as? SRTError, .endBeforeStart(startPTS: 20, endPTS: 10))
        }
    }

    func testDecodedCuesCanBeWrittenAsSRT() throws {
        let file = makeShow(pts: 90_000, palette: [.limitedWhite(1)], objects: [singlePixelObject()])
            + makeClear(pts: 270_000)
        let decoded = try PGSDecoder().decode(file)
        let written = try SRTWriter().write(decoded.map { SRTCue(startPTS: $0.startPTS, endPTS: $0.endPTS, text: "Hi") })
        XCTAssertEqual(written, "1\r\n00:00:01,000 --> 00:00:03,000\r\nHi\r\n")
    }
}
