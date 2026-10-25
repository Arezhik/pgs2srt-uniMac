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

    func testLightFillWithDarkOutlineIsDrawnOnBlackSoTheFillSurvives() {
        let prep = ImagePreprocessor(padding: 0, minimumInkHeight: 1, maximumScale: 1)
        // A one-pixel black ring around a light center, which is how these Blu-ray letters are built.
        let prepared = prep.prepare(outlinedBlock(fill: RGBA(r: 240, g: 240, b: 240, a: 255), outline: RGBA(r: 0, g: 0, b: 0, a: 255)))
        XCTAssertEqual(prepared.background, RGBA(r: 0, g: 0, b: 0, a: 255))
        XCTAssertGreaterThan(prepared.color(x: 4, y: 4).r, 200)
        XCTAssertLessThan(prepared.color(x: 0, y: 4).r, 20)
    }

    func testDarkFillWithLightOutlineStaysOnWhite() {
        let prep = ImagePreprocessor(padding: 0, minimumInkHeight: 1, maximumScale: 1)
        let prepared = prep.prepare(outlinedBlock(fill: RGBA(r: 10, g: 10, b: 10, a: 255), outline: RGBA(r: 240, g: 240, b: 240, a: 255)))
        XCTAssertEqual(prepared.background, RGBA(r: 255, g: 255, b: 255, a: 255))
        XCTAssertLessThan(prepared.color(x: 4, y: 4).r, 40)
    }

    func testRealDiscOutlinesCompositeOntoBlackWhenPicturesArePresent() throws {
        let root = ProcessInfo.processInfo.environment["PGS_VALIDATION_DUMP"] ?? "/tmp/pgs-validation/dump"
        let folder = URL(fileURLWithPath: root, isDirectory: true)
        let sample = folder.appendingPathComponent("0001.pam")
        guard FileManager.default.fileExists(atPath: sample.path) else {
            throw XCTSkip("Decoded cue pictures are not on this machine. Set PGS_VALIDATION_DUMP to check a real disc.")
        }
        // Spread across the episode, including cues whose inner fill was closest to the old cutoff.
        let names = [1, 3, 5, 68, 92, 96, 98, 278, 370, 376, 456, 712, 745, 777].map { String(format: "%04d.pam", $0) }
        let prep = ImagePreprocessor(padding: 0, minimumInkHeight: 1, maximumScale: 1)
        var checked = 0
        for name in names {
            let picture = try loadPAM(folder.appendingPathComponent(name))
            let prepared = prep.prepare(picture)
            XCTAssertFalse(prepared.isBlank, name)
            XCTAssertEqual(
                prepared.background,
                RGBA(r: 0, g: 0, b: 0, a: 255),
                "\(name) was drawn on white, so a light fill with a dark outline would disappear"
            )
            XCTAssertGreaterThan(brightPixelCount(prepared), 20, name)
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 1)
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

/// 13 by 13 ink: a one-pixel outline and an 11 by 11 fill, with a transparent margin.
private func outlinedBlock(fill: RGBA, outline: RGBA) -> SubtitleImage {
    image(width: 15, height: 15) { x, y in
        let inside = (1..<14).contains(x) && (1..<14).contains(y)
        let core = (2..<13).contains(x) && (2..<13).contains(y)
        if core { return fill }
        if inside { return outline }
        return RGBA(r: 0, g: 0, b: 0, a: 0)
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

private func brightPixelCount(_ image: PreparedSubtitleImage) -> Int {
    var count = 0
    var index = 0
    while index + 3 < image.rgba.count {
        if image.rgba[index] > 200 && image.rgba[index + 3] == 255 {
            count += 1
        }
        index += 4
    }
    return count
}

/// Reads a P7 RGB_ALPHA PAM written by `pgsdump`. Used only when a local dump is present.
private func loadPAM(_ url: URL) throws -> SubtitleImage {
    let data = try Data(contentsOf: url)
    guard let headerEnd = data.range(of: Data("ENDHDR\n".utf8)) else {
        throw PAMError("\(url.lastPathComponent) has no PAM header")
    }
    let header = String(decoding: data.prefix(headerEnd.lowerBound), as: UTF8.self)
    var width = 0
    var height = 0
    for line in header.split(separator: "\n") {
        let parts = line.split(separator: " ")
        if parts.count == 2, parts[0] == "WIDTH" { width = Int(parts[1]) ?? 0 }
        if parts.count == 2, parts[0] == "HEIGHT" { height = Int(parts[1]) ?? 0 }
    }
    let pixels = data.suffix(from: headerEnd.upperBound)
    guard width > 0, height > 0, pixels.count == width * height * 4 else {
        throw PAMError("\(url.lastPathComponent) is not a \(width)x\(height) RGBA picture")
    }
    return SubtitleImage(
        width: width,
        height: height,
        rgba: [UInt8](pixels),
        originX: 0,
        originY: 0,
        videoWidth: max(width, 1920),
        videoHeight: max(height, 1080)
    )
}

private struct PAMError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
