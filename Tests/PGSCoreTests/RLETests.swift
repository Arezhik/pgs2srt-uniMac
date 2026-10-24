import XCTest
@testable import PGSCore

final class RLETests: XCTestCase {
    func testSinglePixelsAndEndOfLine() throws {
        let pixels = try RLEDecoder.decode(data: Data([0x01, 0x02, 0x00, 0x00]), width: 2, height: 1, objectID: 1)
        XCTAssertEqual(pixels, [1, 2])
    }

    func testShortAndLongZeroRuns() throws {
        let short = try RLEDecoder.decode(data: Data([0x00, 0x04, 0x00, 0x00]), width: 4, height: 1, objectID: 1)
        XCTAssertEqual(short, [0, 0, 0, 0])

        // 70 zeros: 00 40 46, then end of line. Line length is odd, so a pad byte follows.
        let long = try RLEDecoder.decode(
            data: Data([0x00, 0x40, 0x46, 0x00, 0x00, 0x00]),
            width: 70,
            height: 1,
            objectID: 2
        )
        XCTAssertEqual(long, [UInt8](repeating: 0, count: 70))
    }

    func testShortAndLongColorRuns() throws {
        let short = try RLEDecoder.decode(data: Data([0x00, 0x83, 0x07, 0x00, 0x00]), width: 3, height: 1, objectID: 1)
        XCTAssertEqual(short, [7, 7, 7])

        var longBytes: [UInt8] = [0x00, 0xC0, 0x46, 0x09, 0x00, 0x00]
        if longBytes.count % 2 == 1 { longBytes.append(0) }
        let long = try RLEDecoder.decode(data: Data(longBytes), width: 70, height: 1, objectID: 3)
        XCTAssertEqual(long, [UInt8](repeating: 9, count: 70))
    }

    func testEndOfLineFillsTheRestWithZeros() throws {
        let pixels = try RLEDecoder.decode(data: Data([0x05, 0x00, 0x00, 0x00]), width: 4, height: 1, objectID: 1)
        XCTAssertEqual(pixels, [5, 0, 0, 0])
    }

    func testPaddedAndUnpaddedLines() throws {
        // A 5-pixel line encodes to an odd length, so the spec inserts a 0x00 pad.
        let line: [UInt8] = [1, 0, 2, 0, 3]
        let padded = encodeRLE(pixels: line, width: 5, height: 1, padLines: true)
        let plain = encodeRLE(pixels: line, width: 5, height: 1, padLines: false)
        XCTAssertEqual(padded.count, plain.count + 1)
        XCTAssertEqual(try RLEDecoder.decode(data: padded, width: 5, height: 1, objectID: 1), line)
        XCTAssertEqual(try RLEDecoder.decode(data: plain, width: 5, height: 1, objectID: 1), line)

        // The second line starts with a non-zero code, so that byte cannot be a pad.
        let twoLines = line + [4, 0, 0, 0, 0]
        let decoded = try RLEDecoder.decode(
            data: encodeRLE(pixels: twoLines, width: 5, height: 2, padLines: false),
            width: 5,
            height: 2,
            objectID: 1
        )
        XCTAssertEqual(decoded, twoLines)
    }

    func testRoundTripRandomImage() throws {
        var state: UInt32 = 0x12345678
        func next() -> UInt8 {
            state = state &* 1664525 &+ 1013904223
            return UInt8(state % 17)
        }
        let width = 17
        let height = 9
        let pixels = (0..<(width * height)).map { _ in next() }
        let encoded = encodeRLE(pixels: pixels, width: width, height: height, padLines: true)
        let decoded = try RLEDecoder.decode(data: encoded, width: width, height: height, objectID: 9)
        XCTAssertEqual(decoded, pixels)
    }

    func testRunPastTheEndOfTheLineFails() {
        XCTAssertThrowsError(try RLEDecoder.decode(data: Data([0x00, 0x05, 0x00, 0x00]), width: 3, height: 1, objectID: 4)) { error in
            guard case let PGSError.rleDecodingFailed(objectID, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(objectID, 4)
        }
    }

    func testTruncatedRunFails() {
        XCTAssertThrowsError(try RLEDecoder.decode(data: Data([0x01]), width: 4, height: 2, objectID: 8)) { error in
            guard case PGSError.rleDecodingFailed = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testZeroDimensionsFail() {
        XCTAssertThrowsError(try RLEDecoder.decode(data: Data(), width: 0, height: 1, objectID: 1))
    }
}
