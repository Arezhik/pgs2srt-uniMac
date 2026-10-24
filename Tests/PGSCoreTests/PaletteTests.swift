import XCTest
@testable import PGSCore

final class PaletteTests: XCTestCase {
    func testLimitedRangeBlackWhiteAndGray() {
        let black = ColorConversion.rgba(YCbCrColor(y: 16, cr: 128, cb: 128, a: 255), matrix: .bt709)
        let white = ColorConversion.rgba(YCbCrColor(y: 235, cr: 128, cb: 128, a: 200), matrix: .bt601)
        let gray = ColorConversion.rgba(YCbCrColor(y: 126, cr: 128, cb: 128, a: 255), matrix: .bt709)
        XCTAssertEqual(black, RGBA(r: 0, g: 0, b: 0, a: 255))
        XCTAssertEqual(white, RGBA(r: 255, g: 255, b: 255, a: 200))
        XCTAssertEqual(gray, RGBA(r: 128, g: 128, b: 128, a: 255))
    }

    func testBT601AndBT709DifferForChroma() {
        // Stored in the palette as Y, Cr, Cb. Cr is 240 and Cb is 90.
        let color = YCbCrColor(y: 81, cr: 240, cb: 90, a: 255)
        XCTAssertEqual(
            ColorConversion.rgba(color, matrix: .bt601),
            RGBA(r: 255, g: 0, b: 0, a: 255)
        )
        XCTAssertEqual(
            ColorConversion.rgba(color, matrix: .bt709),
            RGBA(r: 255, g: 24, b: 0, a: 255)
        )
    }

    func testAutomaticMatrixUsesSDAndHDHeights() {
        XCTAssertEqual(ColorMatrix.automatic(videoHeight: 480), .bt601)
        XCTAssertEqual(ColorMatrix.automatic(videoHeight: 576), .bt601)
        XCTAssertEqual(ColorMatrix.automatic(videoHeight: 577), .bt709)
        XCTAssertEqual(ColorMatrix.automatic(videoHeight: 1080), .bt709)
    }

    func testUndefinedPaletteEntryIsTransparent() throws {
        let file = makeShow(
            pts: 0,
            palette: [.limitedWhite(1)],
            objects: [ObjectSpec(width: 2, height: 1, pixels: [1, 0])]
        ) + makeClear(pts: 90_000)
        let cues = try PGSDecoder().decode(file)
        XCTAssertEqual(cues[0].image.color(x: 0, y: 0), RGBA(r: 255, g: 255, b: 255, a: 255))
        XCTAssertEqual(cues[0].image.color(x: 1, y: 0), RGBA(r: 0, g: 0, b: 0, a: 0))
    }
}
