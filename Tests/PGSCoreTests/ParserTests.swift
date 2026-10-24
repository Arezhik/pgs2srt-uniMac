import XCTest
@testable import PGSCore

final class ParserTests: XCTestCase {
    func testParsesEverySegmentAndBigEndianPTS() throws {
        let object = ObjectSpec(width: 2, height: 1, pixels: [1, 1], x: 10, y: 20, forced: true)
        let file = makeShow(
            pts: 90_000,
            videoWidth: 1920,
            videoHeight: 1080,
            state: 0x80,
            paletteID: 2,
            paletteVersion: 3,
            palette: [.limitedWhite(1)],
            objects: [object],
            frameRate: 0x20,
            compositionNumber: 7
        )
        let sets = try SUPParser.parse(file)
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets[0].pts, 90_000)
        XCTAssertEqual(sets[0].pcs.width, 1920)
        XCTAssertEqual(sets[0].pcs.height, 1080)
        XCTAssertEqual(sets[0].pcs.frameRate, 0x20)
        XCTAssertEqual(sets[0].pcs.compositionNumber, 7)
        XCTAssertEqual(sets[0].pcs.state, .epochStart)
        XCTAssertEqual(sets[0].pcs.paletteID, 2)
        XCTAssertFalse(sets[0].pcs.paletteUpdate)
        XCTAssertEqual(sets[0].pcs.objects.count, 1)
        XCTAssertEqual(sets[0].pcs.objects[0].x, 10)
        XCTAssertEqual(sets[0].pcs.objects[0].y, 20)
        XCTAssertTrue(sets[0].pcs.objects[0].forced)
        XCTAssertFalse(sets[0].pcs.objects[0].cropped)
        XCTAssertEqual(sets[0].windows.first?.width, 1920)
        XCTAssertEqual(sets[0].palettes.first?.version, 3)
        XCTAssertEqual(sets[0].palettes.first?.entries.first?.y, 235)
        XCTAssertEqual(sets[0].palettes.first?.entries.first?.cr, 128)
        XCTAssertEqual(sets[0].palettes.first?.entries.first?.cb, 128)
        XCTAssertEqual(sets[0].objects.first?.indices, [1, 1])
    }

    func testCropFlagDoesNotDesyncTheNextObject() throws {
        let first = ObjectSpec(id: 1, width: 4, height: 1, pixels: [0, 1, 2, 0], x: 5, y: 6, crop: (1, 0, 2, 1))
        let second = ObjectSpec(id: 2, width: 1, height: 1, pixels: [3], x: 9, y: 8)
        let sets = try SUPParser.parse(makeShow(
            pts: 1,
            palette: [
                PaletteSpec(id: 1, y: 235, cr: 128, cb: 128, a: 255),
                PaletteSpec(id: 2, y: 81, cr: 240, cb: 90, a: 255),
                PaletteSpec(id: 3, y: 16, cr: 128, cb: 128, a: 255)
            ],
            objects: [first, second]
        ))
        XCTAssertEqual(sets[0].pcs.objects.count, 2)
        XCTAssertTrue(sets[0].pcs.objects[0].cropped)
        XCTAssertEqual(sets[0].pcs.objects[0].cropX, 1)
        XCTAssertEqual(sets[0].pcs.objects[0].cropWidth, 2)
        XCTAssertEqual(sets[0].pcs.objects[1].objectID, 2)
        XCTAssertEqual(sets[0].pcs.objects[1].x, 9)
        XCTAssertEqual(sets[0].pcs.objects[1].y, 8)
        XCTAssertFalse(sets[0].pcs.objects[1].cropped)
    }

    func testMultiFragmentObjectIsReassembled() throws {
        let pixels: [UInt8] = [1, 1, 1, 2, 2, 2, 3, 3]
        let object = ObjectSpec(width: 8, height: 1, pixels: pixels, splitEvery: 2)
        let sets = try SUPParser.parse(makeShow(pts: 10, palette: [.limitedWhite(1), .limitedBlack(2), PaletteSpec(id: 3, y: 126, cr: 128, cb: 128, a: 255)], objects: [object]))
        XCTAssertEqual(sets[0].objects.count, 1)
        XCTAssertEqual(sets[0].objects[0].indices, pixels)
    }

    func testPresentationTimestampComesFromThePCS() throws {
        let file = makeShow(
            pts: 90_000,
            palette: [.limitedWhite(1)],
            objects: [singlePixelObject()],
            odsPTS: 0
        )
        let sets = try SUPParser.parse(file)
        XCTAssertEqual(sets[0].pts, 90_000)
    }

    func testEmptyFileAndBadMagicAndTruncation() {
        XCTAssertThrowsError(try SUPParser.parse(Data())) { error in
            XCTAssertEqual(error as? PGSError, .emptyInput)
        }
        XCTAssertThrowsError(try SUPParser.parse(Data(repeating: 0, count: 13))) { error in
            guard case let PGSError.invalidMagic(offset, byte0, byte1) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(offset, 0)
            XCTAssertEqual(byte0, 0)
            XCTAssertEqual(byte1, 0)
        }
        XCTAssertThrowsError(try SUPParser.parse(Data([0x50, 0x47, 0x00]))) { error in
            guard case PGSError.truncated = error else {
                return XCTFail("unexpected \(error)")
            }
        }

        var truncated = Data([0x50, 0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0x16, 0x00, 0x0A, 0x00, 0x01])
        XCTAssertEqual(truncated.count, 15)
        XCTAssertThrowsError(try SUPParser.parse(truncated)) { error in
            guard case PGSError.truncated = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        truncated.removeAll()
    }

    func testUnknownSegmentMissingEndAndDirtyEnd() {
        var file = SUPFile()
        file.appendSegment(pts: 0, type: 0x99, payload: [])
        XCTAssertThrowsError(try SUPParser.parse(file.data)) { error in
            guard case let PGSError.unknownSegmentType(_, type) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(type, 0x99)
        }

        let withoutEnd = makeShow(pts: 0, palette: [.limitedWhite(1)], objects: [singlePixelObject()], includeEnd: false)
        XCTAssertThrowsError(try SUPParser.parse(withoutEnd)) { error in
            guard case PGSError.missingEnd = error else {
                return XCTFail("unexpected \(error)")
            }
        }

        var dirtyEnd = SUPFile()
        dirtyEnd.appendSegment(
            pts: 0,
            type: SegmentKind.pcs,
            payload: pcsPayload(
                videoWidth: 32,
                videoHeight: 32,
                frameRate: 0x10,
                compositionNumber: 0,
                state: 0x80,
                paletteUpdate: false,
                paletteID: 0,
                objects: []
            )
        )
        dirtyEnd.appendSegment(pts: 0, type: SegmentKind.end, payload: [0x01])
        XCTAssertThrowsError(try SUPParser.parse(dirtyEnd.data)) { error in
            guard case PGSError.invalidSegment(_, "END", _) = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testInvalidPaletteLengthCompositionStateAndIncompleteObject() {
        var file = SUPFile()
        file.appendSegment(
            pts: 0,
            type: SegmentKind.pcs,
            payload: pcsPayload(
                videoWidth: 16,
                videoHeight: 16,
                frameRate: 0x10,
                compositionNumber: 1,
                state: 0x01,
                paletteUpdate: false,
                paletteID: 0,
                objects: []
            )
        )
        file.appendSegment(pts: 0, type: SegmentKind.end, payload: [])
        XCTAssertThrowsError(try SUPParser.parse(file.data)) { error in
            guard case PGSError.invalidSegment(_, "PCS", _) = error else {
                return XCTFail("unexpected \(error)")
            }
        }

        var palette = SUPFile()
        palette.appendSegment(
            pts: 0,
            type: SegmentKind.pcs,
            payload: pcsPayload(
                videoWidth: 16,
                videoHeight: 16,
                frameRate: 0x10,
                compositionNumber: 1,
                state: 0x80,
                paletteUpdate: false,
                paletteID: 0,
                objects: []
            )
        )
        palette.appendSegment(pts: 0, type: SegmentKind.pds, payload: [0x00, 0x00, 0x01])
        palette.appendSegment(pts: 0, type: SegmentKind.end, payload: [])
        XCTAssertThrowsError(try SUPParser.parse(palette.data)) { error in
            guard case PGSError.invalidSegment(_, "PDS", _) = error else {
                return XCTFail("unexpected \(error)")
            }
        }

        let broken = ObjectSpec(width: 4, height: 1, pixels: [1, 1, 1, 1], splitEvery: 2, declaredLengthDelta: 0)
        // Keep only the first fragment by cutting the file before END and the later fragments.
        let encoded = makeShow(pts: 0, palette: [.limitedWhite(1)], objects: [broken], includeEnd: false)
        let setsStart = encoded
        // Find the second PG header after the first ODS and drop everything from there, then add END.
        var trimmed = dropAfterFirstODS(setsStart)
        var end = SUPFile()
        end.appendSegment(pts: 0, type: SegmentKind.end, payload: [])
        trimmed.append(end.data)
        XCTAssertThrowsError(try SUPParser.parse(trimmed)) { error in
            guard case let PGSError.incompleteObject(objectID, _) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(objectID, 1)
        }
    }

    func testDeclaredLengthMismatch() {
        let object = ObjectSpec(width: 2, height: 1, pixels: [1, 1], declaredLengthDelta: 5)
        let file = makeShow(pts: 0, palette: [.limitedWhite(1)], objects: [object])
        XCTAssertThrowsError(try SUPParser.parse(file)) { error in
            guard case let PGSError.objectLengthMismatch(objectID, expected, actual) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(objectID, 1)
            XCTAssertEqual(expected, actual + 5)
        }
    }

    func testMissingPaletteObjectAndInvalidCrop() {
        var noPalette = SUPFile()
        noPalette.appendSegment(
            pts: 0,
            type: SegmentKind.pcs,
            payload: pcsPayload(
                videoWidth: 16,
                videoHeight: 16,
                frameRate: 0x10,
                compositionNumber: 1,
                state: 0x80,
                paletteUpdate: false,
                paletteID: 5,
                objects: [singlePixelObject()]
            )
        )
        noPalette.appendSegment(pts: 0, type: SegmentKind.pds, payload: pdsPayload(id: 0, version: 0, entries: [.limitedWhite(1)]))
        appendODS(singlePixelObject(), pts: 0, to: &noPalette)
        noPalette.appendSegment(pts: 0, type: SegmentKind.end, payload: [])
        XCTAssertThrowsError(try PGSDecoder().decode(noPalette.data)) { error in
            XCTAssertEqual(error as? PGSError, .missingPalette(paletteID: 5))
        }

        let missingObject = makeShow(pts: 0, palette: [.limitedWhite(1)], objects: [singlePixelObject()], includeODS: false)
        XCTAssertThrowsError(try PGSDecoder().decode(missingObject)) { error in
            XCTAssertEqual(error as? PGSError, .missingObject(objectID: 1))
        }

        let cropped = ObjectSpec(width: 2, height: 2, pixels: [1, 1, 1, 1], crop: (1, 1, 2, 2))
        let badCrop = makeShow(pts: 0, palette: [.limitedWhite(1)], objects: [cropped])
        XCTAssertThrowsError(try PGSDecoder().decode(badCrop)) { error in
            guard case PGSError.invalidCrop(1, _) = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }
}

/// Drops bytes starting at the second ODS header so a multi-fragment object is left unfinished.
private func dropAfterFirstODS(_ data: Data) -> Data {
    var seenODS = 0
    var offset = 0
    let bytes = [UInt8](data)
    while offset + 13 <= bytes.count {
        let size = (Int(bytes[offset + 11]) << 8) | Int(bytes[offset + 12])
        let type = bytes[offset + 10]
        if type == SegmentKind.ods {
            seenODS += 1
            if seenODS == 2 {
                return Data(bytes[0..<offset])
            }
        }
        offset += 13 + size
    }
    return data
}
