import XCTest
@testable import PGSCore

final class ComposerTests: XCTestCase {
    func testShowUntilClearingDisplaySet() throws {
        let file = makeShow(
            pts: 90_000,
            palette: [.limitedWhite(1)],
            objects: [ObjectSpec(width: 2, height: 1, pixels: [1, 1], x: 4, y: 6)]
        ) + makeClear(pts: 270_000)
        let cues = try PGSDecoder().decode(file)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].startPTS, 90_000)
        XCTAssertEqual(cues[0].endPTS, 270_000)
        XCTAssertEqual(cues[0].endReason, .clearingDisplaySet)
        XCTAssertEqual(cues[0].image.width, 2)
        XCTAssertEqual(cues[0].image.height, 1)
        XCTAssertEqual(cues[0].image.originX, 4)
        XCTAssertEqual(cues[0].image.originY, 6)
        XCTAssertEqual(cues[0].image.videoWidth, 32)
        XCTAssertEqual(cues[0].image.color(x: 0, y: 0), RGBA(r: 255, g: 255, b: 255, a: 255))
        XCTAssertFalse(cues[0].forced)
    }

    func testTwoSubtitlesAndForcedFlag() throws {
        var file = makeShow(
            pts: 90_000,
            palette: [.limitedWhite(1)],
            objects: [singlePixelObject(forced: true)]
        )
        file.append(makeClear(pts: 180_000))
        file.append(makeShow(
            pts: 360_000,
            state: 0x80,
            palette: [.limitedBlack(1)],
            objects: [singlePixelObject()]
        ))
        file.append(makeClear(pts: 450_000))
        let cues = try PGSDecoder().decode(file)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].startPTS, 90_000)
        XCTAssertEqual(cues[0].endPTS, 180_000)
        XCTAssertTrue(cues[0].forced)
        XCTAssertEqual(cues[0].image.color(x: 0, y: 0).r, 255)
        XCTAssertEqual(cues[1].startPTS, 360_000)
        XCTAssertEqual(cues[1].endPTS, 450_000)
        XCTAssertFalse(cues[1].forced)
        XCTAssertEqual(cues[1].image.color(x: 0, y: 0), RGBA(r: 0, g: 0, b: 0, a: 255))
    }

    func testEpochStartClosesThePreviousCue() throws {
        let first = makeShow(pts: 1_000, palette: [.limitedWhite(1)], objects: [singlePixelObject()])
        let second = makeShow(pts: 5_000, state: 0x80, palette: [.limitedWhite(1)], objects: [singlePixelObject(2)])
        let file = first + second + makeClear(pts: 9_000)
        let cues = try PGSDecoder(colorMatrix: .bt709).decode(file)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].endPTS, 5_000)
        XCTAssertEqual(cues[0].endReason, .epochStart)
        XCTAssertEqual(cues[1].startPTS, 5_000)
        XCTAssertEqual(cues[1].endPTS, 9_000)
        XCTAssertEqual(cues[1].endReason, .clearingDisplaySet)
    }

    func testPaletteFadeKeepsOneCueAndTheMostOpaqueFrame() throws {
        let object = singlePixelObject()
        let faded = makeShow(
            pts: 10_000,
            palette: [.limitedWhite(1, alpha: 100)],
            objects: [object]
        )
        let solid = makeShow(
            pts: 20_000,
            state: 0x00,
            paletteVersion: 1,
            palette: [.limitedWhite(1, alpha: 255)],
            objects: [object],
            paletteUpdate: true,
            includeODS: false
        )
        let dimmed = makeShow(
            pts: 30_000,
            state: 0x00,
            paletteVersion: 2,
            palette: [.limitedWhite(1, alpha: 40)],
            objects: [object],
            paletteUpdate: true,
            includeODS: false
        )
        let cues = try PGSDecoder().decode(faded + solid + dimmed + makeClear(pts: 40_000))
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].startPTS, 10_000)
        XCTAssertEqual(cues[0].endPTS, 40_000)
        XCTAssertEqual(cues[0].image.color(x: 0, y: 0).a, 255)
    }

    func testAcquisitionPointDoesNotSplitAnIdenticalSubtitle() throws {
        let object = ObjectSpec(width: 3, height: 1, pixels: [1, 1, 0], x: 2, y: 2)
        let start = makeShow(pts: 100, palette: [.limitedWhite(1)], objects: [object])
        let acquisition = makeShow(
            pts: 200,
            state: 0x40,
            palette: [.limitedWhite(1)],
            objects: [object]
        )
        let cues = try PGSDecoder().decode(start + acquisition + makeClear(pts: 500))
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].startPTS, 100)
        XCTAssertEqual(cues[0].endPTS, 500)
        XCTAssertEqual(cues[0].image.width, 3)
        XCTAssertEqual(cues[0].image.originX, 2)
    }

    func testADifferentImageReplacesTheOpenCue() throws {
        let first = makeShow(
            pts: 1_000,
            palette: [.limitedWhite(1)],
            objects: [ObjectSpec(width: 1, height: 1, pixels: [1])]
        )
        let second = makeShow(
            pts: 2_000,
            state: 0x00,
            palette: [.limitedWhite(1)],
            objects: [ObjectSpec(width: 2, height: 1, pixels: [1, 1])]
        )
        let cues = try PGSDecoder().decode(first + second + makeClear(pts: 3_000))
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].endReason, .replaced)
        XCTAssertEqual(cues[0].endPTS, 2_000)
        XCTAssertEqual(cues[0].image.width, 1)
        XCTAssertEqual(cues[1].startPTS, 2_000)
        XCTAssertEqual(cues[1].image.width, 2)
        XCTAssertEqual(cues[1].endReason, .clearingDisplaySet)
    }

    func testUnclosedCueEndsAtItsStart() throws {
        let cues = try PGSDecoder().decode(makeShow(pts: 50, palette: [.limitedWhite(1)], objects: [singlePixelObject()]))
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].startPTS, 50)
        XCTAssertEqual(cues[0].endPTS, 50)
        XCTAssertEqual(cues[0].endReason, .endOfFile)
    }

    func testClearingDisplaySetAloneProducesNoCue() throws {
        XCTAssertEqual(try PGSDecoder().decode(makeClear(pts: 10)), [])
    }

    func testCropWindowAndSideBySideObjects() throws {
        let cropped = ObjectSpec(
            id: 1,
            width: 4,
            height: 1,
            pixels: [0, 1, 2, 0],
            x: 3,
            y: 4,
            crop: (1, 0, 2, 1)
        )
        let croppedCues = try PGSDecoder().decode(makeShow(
            pts: 0,
            palette: [.limitedWhite(1), .limitedBlack(2)],
            objects: [cropped]
        ) + makeClear(pts: 10))
        XCTAssertEqual(croppedCues[0].image.width, 2)
        XCTAssertEqual(croppedCues[0].image.originX, 3)
        XCTAssertEqual(croppedCues[0].image.originY, 4)
        XCTAssertEqual(croppedCues[0].image.color(x: 0, y: 0).r, 255)
        XCTAssertEqual(croppedCues[0].image.color(x: 1, y: 0), RGBA(r: 0, g: 0, b: 0, a: 255))

        let windowed = ObjectSpec(width: 3, height: 1, pixels: [1, 2, 3], windowID: 1)
        let windowCues = try PGSDecoder().decode(makeShow(
            pts: 0,
            palette: [.limitedBlack(1), .limitedWhite(2), PaletteSpec(id: 3, y: 126, cr: 128, cb: 128, a: 255)],
            objects: [windowed],
            windows: [WindowSpec(id: 1, x: 1, y: 0, width: 1, height: 1)]
        ) + makeClear(pts: 10))
        XCTAssertEqual(windowCues[0].image.width, 1)
        XCTAssertEqual(windowCues[0].image.height, 1)
        XCTAssertEqual(windowCues[0].image.originX, 1)
        XCTAssertEqual(windowCues[0].image.color(x: 0, y: 0), RGBA(r: 255, g: 255, b: 255, a: 255))

        let left = ObjectSpec(id: 1, width: 1, height: 1, pixels: [1], x: 2, y: 3)
        let right = ObjectSpec(id: 2, width: 1, height: 1, pixels: [1], x: 5, y: 3)
        let pair = try PGSDecoder().decode(makeShow(
            pts: 0,
            palette: [.limitedWhite(1)],
            objects: [left, right]
        ) + makeClear(pts: 10))
        XCTAssertEqual(pair[0].image.originX, 2)
        XCTAssertEqual(pair[0].image.originY, 3)
        XCTAssertEqual(pair[0].image.width, 4)
        XCTAssertEqual(pair[0].image.height, 1)
        XCTAssertEqual(pair[0].image.color(x: 0, y: 0).a, 255)
        XCTAssertEqual(pair[0].image.color(x: 1, y: 0).a, 0)
        XCTAssertEqual(pair[0].image.color(x: 3, y: 0).a, 255)
    }

    func testSourceOverBlend() throws {
        let bottom = ObjectSpec(id: 1, width: 1, height: 1, pixels: [1])
        let top = ObjectSpec(id: 2, width: 1, height: 1, pixels: [2])
        let cues = try PGSDecoder().decode(makeShow(
            pts: 0,
            palette: [.limitedBlack(1), .limitedWhite(2, alpha: 128)],
            objects: [bottom, top]
        ) + makeClear(pts: 10))
        XCTAssertEqual(cues[0].image.color(x: 0, y: 0), RGBA(r: 128, g: 128, b: 128, a: 255))
    }

    func testMatrixFollowsVideoHeightAndCanBeOverridden() throws {
        let entry = PaletteSpec(id: 1, y: 81, cr: 240, cb: 90, a: 255)
        let sd = makeShow(
            pts: 0,
            videoWidth: 720,
            videoHeight: 576,
            palette: [entry],
            objects: [singlePixelObject()]
        ) + makeClear(pts: 10, videoWidth: 720, videoHeight: 576)
        let hd = makeShow(
            pts: 0,
            videoWidth: 1920,
            videoHeight: 1080,
            palette: [entry],
            objects: [singlePixelObject()]
        ) + makeClear(pts: 10, videoWidth: 1920, videoHeight: 1080)

        let sdCue = try PGSDecoder().decode(sd)
        let hdCue = try PGSDecoder().decode(hd)
        XCTAssertEqual(sdCue[0].image.color(x: 0, y: 0), RGBA(r: 255, g: 0, b: 0, a: 255))
        XCTAssertEqual(hdCue[0].image.color(x: 0, y: 0), RGBA(r: 255, g: 24, b: 0, a: 255))

        let overridden = try PGSDecoder(colorMatrix: .bt601).decode(hd)
        XCTAssertEqual(overridden[0].image.color(x: 0, y: 0), RGBA(r: 255, g: 0, b: 0, a: 255))
    }

    func testBackwardsTimestampsFail() {
        let file = makeShow(pts: 5_000, palette: [.limitedWhite(1)], objects: [singlePixelObject()])
            + makeClear(pts: 1_000)
        XCTAssertThrowsError(try PGSDecoder().decode(file)) { error in
            XCTAssertEqual(error as? PGSError, .nonMonotonicPTS(previous: 5_000, next: 1_000))
        }
    }

    func testObjectFullyOutsideTheFrameIsAnEmptyImage() throws {
        let object = ObjectSpec(width: 2, height: 2, pixels: [1, 1, 1, 1], x: 100, y: 0)
        let cues = try PGSDecoder().decode(makeShow(
            pts: 0,
            videoWidth: 16,
            videoHeight: 16,
            palette: [.limitedWhite(1)],
            objects: [object]
        ) + makeClear(pts: 10, videoWidth: 16, videoHeight: 16))
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].image.width, 0)
        XCTAssertEqual(cues[0].image.height, 0)
    }

    func testMissingWindowWhenOtherWindowsExist() {
        let file = makeShow(
            pts: 0,
            palette: [.limitedWhite(1)],
            objects: [ObjectSpec(width: 1, height: 1, pixels: [1], windowID: 3)],
            windows: [WindowSpec(id: 1, x: 0, y: 0, width: 8, height: 8)]
        )
        XCTAssertThrowsError(try PGSDecoder().decode(file)) { error in
            XCTAssertEqual(error as? PGSError, .missingWindow(windowID: 3))
        }
    }

    func testPAMRoundTripHeaderAndPixel() throws {
        let cues = try PGSDecoder().decode(
            makeShow(pts: 0, palette: [.limitedWhite(1)], objects: [singlePixelObject()]) + makeClear(pts: 90)
        )
        let pam = cues[0].image.pamData()
        let header = "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n"
        let headerData = Data(header.utf8)
        XCTAssertTrue(pam.starts(with: headerData))
        XCTAssertEqual(pam[headerData.endIndex], 255)
        XCTAssertEqual(Array(pam.suffix(4)), [255, 255, 255, 255])
    }
}
