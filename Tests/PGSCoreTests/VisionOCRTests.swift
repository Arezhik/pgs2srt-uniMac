import XCTest
import PGSCore

#if os(macOS)
import CoreGraphics
import CoreText
import Vision
@testable import VisionOCR

final class VisionOCRTests: XCTestCase {
    func testRequestUsesAccurateRecognitionAndEnglishByDefault() {
        let request = VisionOCR.makeRequest(languages: [])
        XCTAssertEqual(request.recognitionLevel, .accurate)
        XCTAssertTrue(request.usesLanguageCorrection)
        XCTAssertFalse(request.automaticallyDetectsLanguage)
        XCTAssertEqual(request.recognitionLanguages, ["en-US"])

        let custom = VisionOCR.makeRequest(languages: [" fr-FR ", "", "de-DE"])
        XCTAssertEqual(custom.recognitionLanguages, ["fr-FR", "de-DE"])
        XCTAssertEqual(custom.recognitionLevel, .accurate)
    }

    func testBlankImageDoesNotInventText() async throws {
        let blank = SubtitleImage(
            width: 4,
            height: 4,
            rgba: [UInt8](repeating: 0, count: 64),
            originX: 0,
            originY: 0,
            videoWidth: 100,
            videoHeight: 100
        )
        let result = try await VisionOCR().recognize(image: blank, languages: ["en-US"])
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.lines.isEmpty)
    }

    func testGeneratedHelloIsRecognized() async throws {
        let image = try renderedSubtitle("Hello")
        XCTAssertGreaterThan(inkCount(image), 100, "The fixture image did not draw any letters")
        let result = try await VisionOCR().recognize(image: image, languages: ["en-US"])
        XCTAssertTrue(
            result.text.range(of: "hello", options: [.caseInsensitive]) != nil,
            "Vision read \(result.text.debugDescription) from the generated Hello image"
        )
        XCTAssertGreaterThan(result.confidence ?? 0, 0)
    }

    func testTwoGeneratedLinesStayInReadingOrder() async throws {
        let image = try renderedSubtitle("Hello\nWorld")
        let result = try await VisionOCR().recognize(image: image, languages: ["en-US"])
        let text = result.text.lowercased()
        guard let hello = text.range(of: "hello"), let world = text.range(of: "world") else {
            return XCTFail("Vision read \(result.text.debugDescription)")
        }
        XCTAssertLessThan(hello.lowerBound, world.lowerBound)

        let cue = SubtitleCue(
            startPTS: 90_000,
            endPTS: 180_000,
            image: image,
            forced: false,
            endReason: .clearingDisplaySet
        )
        let transcribed = try await TranscriptionPipeline(maxConcurrent: 1).transcribe(
            cues: [cue],
            recognizer: VisionOCR()
        )
        let written = transcribed.cues[0].text.lowercased()
        guard let helloLine = written.range(of: "hello"), let worldLine = written.range(of: "world") else {
            return XCTFail("The SRT cue was \(transcribed.cues[0].text.debugDescription)")
        }
        XCTAssertLessThan(helloLine.lowerBound, worldLine.lowerBound)
        XCTAssertTrue(transcribed.failures.isEmpty)
        XCTAssertTrue(transcribed.srt.contains("00:00:01,000"))
    }
}

/// Draws white Helvetica on a transparent bitmap with Core Text, which does not
/// need a window. The flip matches Apple's Core Text sample so row 0 is the top.
private func renderedSubtitle(_ string: String) throws -> SubtitleImage {
    let font = CTFontCreateWithName("Helvetica" as CFString, 72, nil)
    let color = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    let attributes = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: color
    ] as CFDictionary
    let attributed = CFAttributedStringCreate(nil, string as CFString, attributes)!
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let length = CFAttributedStringGetLength(attributed)
    var fit = CFRange(location: 0, length: 0)
    let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter,
        CFRange(location: 0, length: length),
        nil,
        CGSize(width: 1600, height: 1600),
        &fit
    )
    let pad: CGFloat = 32
    let width = max(8, Int((suggested.width + pad * 2).rounded(.up)))
    let height = max(8, Int((suggested.height + pad * 2).rounded(.up)))
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
    ) else {
        throw FixtureError("Could not create a bitmap for \(string).")
    }
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.textMatrix = .identity
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    let path = CGPath(
        rect: CGRect(x: pad, y: pad, width: suggested.width + 8, height: suggested.height + 8),
        transform: nil
    )
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    CTFrameDraw(frame, context)
    guard let image = context.makeImage(),
          let data = image.dataProvider?.data,
          let pointer = CFDataGetBytePtr(data) else {
        throw FixtureError("Could not read the bitmap for \(string).")
    }
    let pixelWidth = image.width
    let pixelHeight = image.height
    let rowBytes = image.bytesPerRow
    guard pixelWidth > 0, pixelHeight > 0, rowBytes >= pixelWidth * 4,
          CFDataGetLength(data) >= rowBytes * pixelHeight else {
        throw FixtureError("The bitmap for \(string) had an unexpected size.")
    }
    var rgba = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
    for row in 0..<pixelHeight {
        let source = pointer.advanced(by: row * rowBytes)
        let destination = row * pixelWidth * 4
        for column in 0..<(pixelWidth * 4) {
            rgba[destination + column] = source[column]
        }
    }
    unpremultiply(&rgba)
    return SubtitleImage(
        width: pixelWidth,
        height: pixelHeight,
        rgba: rgba,
        originX: 0,
        originY: 0,
        videoWidth: max(width, 1920),
        videoHeight: max(height, 1080)
    )
}

private func unpremultiply(_ rgba: inout [UInt8]) {
    var index = 0
    while index + 3 < rgba.count {
        let alpha = Int(rgba[index + 3])
        if alpha == 0 {
            rgba[index] = 0
            rgba[index + 1] = 0
            rgba[index + 2] = 0
        } else if alpha < 255 {
            rgba[index] = UInt8(min(255, Int(rgba[index]) * 255 / alpha))
            rgba[index + 1] = UInt8(min(255, Int(rgba[index + 1]) * 255 / alpha))
            rgba[index + 2] = UInt8(min(255, Int(rgba[index + 2]) * 255 / alpha))
        }
        index += 4
    }
}

private func inkCount(_ image: SubtitleImage) -> Int {
    var count = 0
    var index = 3
    while index < image.rgba.count {
        if image.rgba[index] >= 16 { count += 1 }
        index += 4
    }
    return count
}

private struct FixtureError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
#endif
