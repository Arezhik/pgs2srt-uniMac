import XCTest
import PGSCore

final class ImagePreprocessorTests: XCTestCase {
    func testBlankAndFullyTransparentImages() {
        let empty = SubtitleImage(width: 0, height: 0, rgba: [], originX: 0, originY: 0, videoWidth: 10, videoHeight: 10)
        XCTAssertTrue(ImagePreprocessor().prepare(empty).isBlank)

        let clear = image(width: 3, height: 2) { _, _ in RGBA(r: 0, g: 0, b: 0, a: 0) }
        let prepared = ImagePreprocessor().prepare(clear)
        XCTAssertTrue(prepared.isBlank)
        XCTAssertEqual(prepared.lines.count, 0)
        XCTAssertEqual(prepared.rgba.count, 0)
    }

    func testLightInkIsCompositedOntoBlackAndHalfAlphaBlends() {
        let prep = ImagePreprocessor(padding: 0, minimumInkHeight: 1, maximumScale: 1)
        let solid = prep.prepare(image(width: 1, height: 1) { _, _ in RGBA(r: 255, g: 255, b: 255, a: 255) })
        XCTAssertEqual(solid.background, RGBA(r: 0, g: 0, b: 0, a: 255))
        XCTAssertEqual(solid.color(x: 0, y: 0), RGBA(r: 255, g: 255, b: 255, a: 255))

        let half = prep.prepare(image(width: 1, height: 1) { _, _ in RGBA(r: 255, g: 255, b: 255, a: 128) })
        XCTAssertEqual(half.background, RGBA(r: 0, g: 0, b: 0, a: 255))
        XCTAssertEqual(half.color(x: 0, y: 0), RGBA(r: 128, g: 128, b: 128, a: 255))
    }

    func testDarkInkIsCompositedOntoWhiteAndPaddingFillsTheBorder() {
        let prep = ImagePreprocessor(padding: 1, minimumInkHeight: 1, maximumScale: 1)
        let prepared = prep.prepare(image(width: 1, height: 1) { _, _ in RGBA(r: 0, g: 0, b: 0, a: 255) })
        XCTAssertEqual(prepared.background, RGBA(r: 255, g: 255, b: 255, a: 255))
        XCTAssertEqual(prepared.width, 3)
        XCTAssertEqual(prepared.height, 3)
        XCTAssertEqual(prepared.color(x: 1, y: 1), RGBA(r: 0, g: 0, b: 0, a: 255))
        XCTAssertEqual(prepared.color(x: 0, y: 0), RGBA(r: 255, g: 255, b: 255, a: 255))
        XCTAssertEqual(prepared.color(x: 2, y: 2).a, 255)
    }

    func testTransparentMarginIsCroppedBeforePadding() {
        let prep = ImagePreprocessor(padding: 0, minimumInkHeight: 1, maximumScale: 1)
        let prepared = prep.prepare(image(width: 3, height: 1) { x, _ in
            x == 1 ? RGBA(r: 255, g: 255, b: 255, a: 255) : RGBA(r: 0, g: 0, b: 0, a: 0)
        })
        XCTAssertEqual(prepared.width, 1)
        XCTAssertEqual(prepared.height, 1)
        XCTAssertEqual(prepared.color(x: 0, y: 0).r, 255)
    }

    func testSmallInkIsUpscaledByAnIntegerFactorAndSolidColorStaysSolid() {
        let prep = ImagePreprocessor(padding: 0, minimumInkHeight: 4, maximumScale: 4)
        let prepared = prep.prepare(image(width: 1, height: 1) { _, _ in RGBA(r: 255, g: 255, b: 255, a: 255) })
        XCTAssertEqual(prepared.scale, 4)
        XCTAssertEqual(prepared.width, 4)
        XCTAssertEqual(prepared.height, 4)
        for y in 0..<4 {
            for x in 0..<4 {
                XCTAssertEqual(prepared.color(x: x, y: y), RGBA(r: 255, g: 255, b: 255, a: 255))
            }
        }
    }

    func testTallInkIsNotUpscaledAndWidthCapStopsTheScale() {
        let tall = ImagePreprocessor(padding: 0, minimumInkHeight: 64, maximumScale: 4)
        let prepared = tall.prepare(image(width: 2, height: 80) { _, _ in RGBA(r: 255, g: 255, b: 255, a: 255) })
        XCTAssertEqual(prepared.scale, 1)
        XCTAssertEqual(prepared.height, 80)

        let capped = ImagePreprocessor(padding: 0, minimumInkHeight: 64, maximumScale: 8, maximumPixelWidth: 25)
        XCTAssertEqual(capped.resolvedScale(inkWidth: 10, inkHeight: 10), 2)
        XCTAssertEqual(
            ImagePreprocessor(padding: 0, minimumInkHeight: 64, maximumScale: 4).resolvedScale(inkWidth: 4, inkHeight: 40),
            2
        )
        XCTAssertEqual(
            ImagePreprocessor(padding: 0, minimumInkHeight: 64, maximumScale: 4).resolvedScale(inkWidth: 4, inkHeight: 10),
            4
        )
    }

    func testARealGapSplitsLinesAndADotGapDoesNot() {
        let prep = ImagePreprocessor(padding: 2, minimumInkHeight: 20, maximumScale: 4, lineGap: 3)
        let split = prep.prepare(image(width: 4, height: 12) { _, y in
            let ink = (0..<3).contains(y) || (7..<10).contains(y)
            return ink ? RGBA(r: 255, g: 255, b: 255, a: 255) : RGBA(r: 0, g: 0, b: 0, a: 0)
        })
        XCTAssertEqual(split.lines.count, 2)
        XCTAssertEqual(split.scale, 2)
        XCTAssertEqual(split.lines[0].top, 4)
        XCTAssertEqual(split.lines[0].bottom, 10)
        XCTAssertEqual(split.lines[0].left, 4)
        XCTAssertEqual(split.lines[0].right, 12)
        XCTAssertEqual(split.lines[1].top, 18)
        XCTAssertEqual(split.lines[1].bottom, 24)
        XCTAssertFalse(split.lines[0].isItalic)

        let dotted = prep.prepare(image(width: 4, height: 10) { x, y in
            let dot = y == 0 && x == 1
            let body = (2..<9).contains(y)
            return (dot || body) ? RGBA(r: 255, g: 255, b: 255, a: 255) : RGBA(r: 0, g: 0, b: 0, a: 0)
        })
        XCTAssertEqual(dotted.lines.count, 1)
    }

    func testRightLeaningInkIsItalicAndAnUprightBlockIsNot() {
        let prep = ImagePreprocessor(padding: 0, minimumInkHeight: 1, maximumScale: 1)
        let leaning = prep.prepare(image(width: 50, height: 40) { x, y in
            let start = 4 + (39 - y)
            let ink = x >= start && x < start + 2
            return ink ? RGBA(r: 255, g: 255, b: 255, a: 255) : RGBA(r: 0, g: 0, b: 0, a: 0)
        })
        XCTAssertEqual(leaning.lines.count, 1)
        XCTAssertTrue(leaning.lines[0].isItalic)

        let upright = prep.prepare(image(width: 20, height: 40) { x, _ in
            (x >= 8 && x < 12) ? RGBA(r: 255, g: 255, b: 255, a: 255) : RGBA(r: 0, g: 0, b: 0, a: 0)
        })
        XCTAssertEqual(upright.lines.count, 1)
        XCTAssertFalse(upright.lines[0].isItalic)
    }
}

private func image(width: Int, height: Int, _ pixel: (Int, Int) -> RGBA) -> SubtitleImage {
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let color = pixel(x, y)
            let index = (y * width + x) * 4
            rgba[index] = color.r
            rgba[index + 1] = color.g
            rgba[index + 2] = color.b
            rgba[index + 3] = color.a
        }
    }
    return SubtitleImage(
        width: width,
        height: height,
        rgba: rgba,
        originX: 0,
        originY: 0,
        videoWidth: 100,
        videoHeight: 100
    )
}
