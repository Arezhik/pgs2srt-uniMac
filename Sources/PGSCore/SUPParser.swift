import Foundation

enum SegmentKind {
    static let pds: UInt8 = 0x14
    static let ods: UInt8 = 0x15
    static let pcs: UInt8 = 0x16
    static let wds: UInt8 = 0x17
    static let end: UInt8 = 0x80
    static let headerLength = 13
}

enum CompositionState: Equatable {
    case normal
    case acquisitionPoint
    case epochStart
    case epochContinue
}

struct PaletteEntry {
    var id: UInt8
    var y: UInt8
    var cr: UInt8
    var cb: UInt8
    var a: UInt8
}

struct PaletteSegment {
    var id: UInt8
    var version: UInt8
    var entries: [PaletteEntry]
}

struct WindowSegment {
    var id: UInt8
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

struct ObjectBitmap {
    var id: UInt16
    var version: UInt8
    var width: Int
    var height: Int
    var indices: [UInt8]
}

struct CompositionObject {
    var objectID: UInt16
    var windowID: UInt8
    var forced: Bool
    var cropped: Bool
    var x: Int
    var y: Int
    var cropX: Int
    var cropY: Int
    var cropWidth: Int
    var cropHeight: Int
}

struct PresentationComposition {
    var width: Int
    var height: Int
    var frameRate: UInt8
    var compositionNumber: UInt16
    var state: CompositionState
    var paletteUpdate: Bool
    var paletteID: UInt8
    var objects: [CompositionObject]
}

struct DisplaySet {
    var pts: UInt32
    var dts: UInt32
    var startOffset: Int
    var pcs: PresentationComposition
    var windows: [WindowSegment]
    var palettes: [PaletteSegment]
    var objects: [ObjectBitmap]
}

enum SUPParser {
    static func parse(_ data: Data) throws -> [DisplaySet] {
        if data.isEmpty {
            throw PGSError.emptyInput
        }

        var cursor = ByteCursor(data: data)
        var sets: [DisplaySet] = []
        var current: PartialDisplaySet?

        while !cursor.isEmpty {
            let headerOffset = cursor.fileOffset
            if cursor.remaining < SegmentKind.headerLength {
                throw PGSError.truncated(offset: headerOffset, context: "a PG segment header")
            }
            let magic0 = try cursor.readUInt8("the PG marker")
            let magic1 = try cursor.readUInt8("the PG marker")
            if magic0 != 0x50 || magic1 != 0x47 {
                throw PGSError.invalidMagic(offset: headerOffset, byte0: magic0, byte1: magic1)
            }
            let pts = try cursor.readUInt32("the presentation timestamp")
            let dts = try cursor.readUInt32("the decoding timestamp")
            let type = try cursor.readUInt8("the segment type")
            let size = Int(try cursor.readUInt16("the segment length"))
            let payloadOffset = cursor.fileOffset
            let payload = try cursor.readData(size, "a \(size)-byte \(segmentName(type)) segment")

            if current == nil {
                current = PartialDisplaySet(startOffset: headerOffset)
            }
            guard var partial = current else {
                throw PGSError.missingEnd(offset: headerOffset)
            }
            try partial.consume(
                type: type,
                payload: payload,
                payloadOffset: payloadOffset,
                pts: pts,
                dts: dts
            )
            if type == SegmentKind.end {
                sets.append(try partial.finish())
                current = nil
            } else {
                current = partial
            }
        }

        if let current {
            throw PGSError.missingEnd(offset: current.startOffset)
        }
        return sets
    }

    private static func segmentName(_ type: UInt8) -> String {
        switch type {
        case SegmentKind.pds: return "PDS"
        case SegmentKind.ods: return "ODS"
        case SegmentKind.pcs: return "PCS"
        case SegmentKind.wds: return "WDS"
        case SegmentKind.end: return "END"
        default: return "segment"
        }
    }
}

private struct PartialObject {
    var id: UInt16
    var version: UInt8
    var width: Int
    var height: Int
    var expectedRLE: Int
    var rle = Data()
}

private struct PartialDisplaySet {
    var startOffset: Int
    var pts: UInt32?
    var dts: UInt32?
    var pcs: PresentationComposition?
    var windows: [WindowSegment] = []
    var palettes: [PaletteSegment] = []
    var objects: [ObjectBitmap] = []
    var partials: [UInt16: PartialObject] = [:]

    mutating func consume(
        type: UInt8,
        payload: Data,
        payloadOffset: Int,
        pts: UInt32,
        dts: UInt32
    ) throws {
        switch type {
        case SegmentKind.pcs:
            if pcs != nil {
                throw PGSError.duplicatePresentationComposition(offset: startOffset)
            }
            pcs = try parsePCS(payload, fileOffset: payloadOffset)
            self.pts = pts
            self.dts = dts
        case SegmentKind.wds:
            windows.append(contentsOf: try parseWDS(payload, fileOffset: payloadOffset))
        case SegmentKind.pds:
            palettes.append(try parsePDS(payload, fileOffset: payloadOffset))
        case SegmentKind.ods:
            try consumeODS(payload, fileOffset: payloadOffset)
        case SegmentKind.end:
            if !payload.isEmpty {
                throw PGSError.invalidSegment(
                    offset: payloadOffset,
                    kind: "END",
                    message: "it must be empty, but it contains \(payload.count) bytes."
                )
            }
        default:
            throw PGSError.unknownSegmentType(offset: payloadOffset - SegmentKind.headerLength, type: type)
        }
    }

    func finish() throws -> DisplaySet {
        guard let pcs, let pts, let dts else {
            throw PGSError.missingPresentationComposition(offset: startOffset)
        }
        if let unfinished = partials.keys.sorted().first {
            throw PGSError.incompleteObject(objectID: unfinished, offset: startOffset)
        }
        return DisplaySet(
            pts: pts,
            dts: dts,
            startOffset: startOffset,
            pcs: pcs,
            windows: windows,
            palettes: palettes,
            objects: objects
        )
    }

    mutating func consumeODS(_ payload: Data, fileOffset: Int) throws {
        var cursor = ByteCursor(data: payload, baseOffset: fileOffset)
        guard payload.count >= 4 else {
            throw PGSError.invalidSegment(
                offset: fileOffset,
                kind: "ODS",
                message: "it needs at least 4 header bytes and has \(payload.count)."
            )
        }
        let objectID = try cursor.readUInt16("the object id")
        let version = try cursor.readUInt8("the object version")
        let flags = try cursor.readUInt8("the object sequence flags")
        let isFirst = flags & 0x80 != 0
        let isLast = flags & 0x40 != 0

        if isFirst {
            if partials[objectID] != nil {
                throw PGSError.invalidSegment(
                    offset: fileOffset,
                    kind: "ODS",
                    message: "object \(objectID) starts again before the previous part finished."
                )
            }
            guard payload.count >= 11 else {
                throw PGSError.invalidSegment(
                    offset: fileOffset,
                    kind: "ODS",
                    message: "the first part of object \(objectID) needs 11 header bytes and has \(payload.count)."
                )
            }
            let declared = try cursor.readUInt24("the object data length")
            let width = Int(try cursor.readUInt16("the object width"))
            let height = Int(try cursor.readUInt16("the object height"))
            guard declared >= 4 else {
                throw PGSError.invalidSegment(
                    offset: fileOffset,
                    kind: "ODS",
                    message: "object \(objectID) declares a data length of \(declared), which is shorter than its width and height."
                )
            }
            guard width > 0, height > 0, width <= 8192, height <= 8192 else {
                throw PGSError.invalidSegment(
                    offset: fileOffset,
                    kind: "ODS",
                    message: "object \(objectID) has dimensions \(width)x\(height)."
                )
            }
            let rle = try cursor.readData(cursor.remaining, "the object image data")
            var partial = PartialObject(
                id: objectID,
                version: version,
                width: width,
                height: height,
                expectedRLE: declared - 4
            )
            partial.rle = rle
            if isLast {
                objects.append(try complete(partial, fileOffset: fileOffset))
            } else {
                try guardLength(partial, final: false)
                partials[objectID] = partial
            }
            return
        }

        guard var partial = partials[objectID] else {
            throw PGSError.invalidSegment(
                offset: fileOffset,
                kind: "ODS",
                message: "object \(objectID) continues, but no first part was seen."
            )
        }
        let rle = try cursor.readData(cursor.remaining, "the continued object image data")
        partial.rle.append(rle)
        if isLast {
            objects.append(try complete(partial, fileOffset: fileOffset))
            partials[objectID] = nil
        } else {
            try guardLength(partial, final: false)
            partials[objectID] = partial
        }
    }

    func complete(_ partial: PartialObject, fileOffset: Int) throws -> ObjectBitmap {
        try guardLength(partial, final: true)
        let indices = try RLEDecoder.decode(
            data: partial.rle,
            width: partial.width,
            height: partial.height,
            objectID: partial.id
        )
        return ObjectBitmap(
            id: partial.id,
            version: partial.version,
            width: partial.width,
            height: partial.height,
            indices: indices
        )
    }

    func guardLength(_ partial: PartialObject, final: Bool) throws {
        if partial.rle.count > partial.expectedRLE || (final && partial.rle.count != partial.expectedRLE) {
            throw PGSError.objectLengthMismatch(
                objectID: partial.id,
                expected: partial.expectedRLE,
                actual: partial.rle.count
            )
        }
    }
}

private func parsePCS(_ payload: Data, fileOffset: Int) throws -> PresentationComposition {
    var cursor = ByteCursor(data: payload, baseOffset: fileOffset)
    guard payload.count >= 11 else {
        throw PGSError.invalidSegment(
            offset: fileOffset,
            kind: "PCS",
            message: "it needs 11 header bytes and has \(payload.count)."
        )
    }
    let width = Int(try cursor.readUInt16("the video width"))
    let height = Int(try cursor.readUInt16("the video height"))
    let frameRate = try cursor.readUInt8("the frame rate")
    let compositionNumber = try cursor.readUInt16("the composition number")
    let stateByte = try cursor.readUInt8("the composition state")
    let paletteUpdateByte = try cursor.readUInt8("the palette update flag")
    let paletteID = try cursor.readUInt8("the palette id")
    let objectCount = Int(try cursor.readUInt8("the composition object count"))

    guard width > 0, height > 0, width <= 8192, height <= 8192 else {
        throw PGSError.invalidSegment(
            offset: fileOffset,
            kind: "PCS",
            message: "video size \(width)x\(height) is not usable."
        )
    }
    let state: CompositionState
    switch stateByte {
    case 0x00: state = .normal
    case 0x40: state = .acquisitionPoint
    case 0x80: state = .epochStart
    case 0xC0: state = .epochContinue
    default:
        throw PGSError.invalidSegment(
            offset: fileOffset,
            kind: "PCS",
            message: "composition state \(hexByte(stateByte)) is not normal (0x00), acquisition (0x40), epoch start (0x80), or epoch continue (0xC0)."
        )
    }
    guard objectCount <= 64 else {
        throw PGSError.invalidSegment(
            offset: fileOffset,
            kind: "PCS",
            message: "it declares \(objectCount) composition objects; at most 64 are supported."
        )
    }

    var objects: [CompositionObject] = []
    objects.reserveCapacity(objectCount)
    for _ in 0..<objectCount {
        guard cursor.remaining >= 8 else {
            throw PGSError.invalidSegment(
                offset: cursor.fileOffset,
                kind: "PCS",
                message: "a composition object is cut off."
            )
        }
        let objectID = try cursor.readUInt16("the composition object id")
        let windowID = try cursor.readUInt8("the window id")
        let flags = try cursor.readUInt8("the composition flags")
        let x = Int(try cursor.readUInt16("the object x position"))
        let y = Int(try cursor.readUInt16("the object y position"))
        let cropped = flags & 0x80 != 0
        var cropX = 0
        var cropY = 0
        var cropWidth = 0
        var cropHeight = 0
        if cropped {
            guard cursor.remaining >= 8 else {
                throw PGSError.invalidSegment(
                    offset: cursor.fileOffset,
                    kind: "PCS",
                    message: "a cropped composition object is cut off."
                )
            }
            cropX = Int(try cursor.readUInt16("the crop x position"))
            cropY = Int(try cursor.readUInt16("the crop y position"))
            cropWidth = Int(try cursor.readUInt16("the crop width"))
            cropHeight = Int(try cursor.readUInt16("the crop height"))
        }
        objects.append(CompositionObject(
            objectID: objectID,
            windowID: windowID,
            forced: flags & 0x40 != 0,
            cropped: cropped,
            x: x,
            y: y,
            cropX: cropX,
            cropY: cropY,
            cropWidth: cropWidth,
            cropHeight: cropHeight
        ))
    }
    if cursor.remaining != 0 {
        throw PGSError.invalidSegment(
            offset: cursor.fileOffset,
            kind: "PCS",
            message: "\(cursor.remaining) unused bytes remain after \(objectCount) composition objects."
        )
    }
    return PresentationComposition(
        width: width,
        height: height,
        frameRate: frameRate,
        compositionNumber: compositionNumber,
        state: state,
        paletteUpdate: paletteUpdateByte & 0x80 != 0,
        paletteID: paletteID,
        objects: objects
    )
}

private func parseWDS(_ payload: Data, fileOffset: Int) throws -> [WindowSegment] {
    var cursor = ByteCursor(data: payload, baseOffset: fileOffset)
    guard !payload.isEmpty else {
        throw PGSError.invalidSegment(offset: fileOffset, kind: "WDS", message: "it is empty.")
    }
    let count = Int(try cursor.readUInt8("the window count"))
    let expected = count * 9
    guard cursor.remaining == expected else {
        throw PGSError.invalidSegment(
            offset: fileOffset,
            kind: "WDS",
            message: "it declares \(count) windows (\(expected) bytes) but \(cursor.remaining) bytes remain."
        )
    }
    var windows: [WindowSegment] = []
    windows.reserveCapacity(count)
    for _ in 0..<count {
        let id = try cursor.readUInt8("the window id")
        let x = Int(try cursor.readUInt16("the window x position"))
        let y = Int(try cursor.readUInt16("the window y position"))
        let width = Int(try cursor.readUInt16("the window width"))
        let height = Int(try cursor.readUInt16("the window height"))
        guard width > 0, height > 0 else {
            throw PGSError.invalidSegment(
                offset: fileOffset,
                kind: "WDS",
                message: "window \(id) has dimensions \(width)x\(height)."
            )
        }
        windows.append(WindowSegment(id: id, x: x, y: y, width: width, height: height))
    }
    return windows
}

private func parsePDS(_ payload: Data, fileOffset: Int) throws -> PaletteSegment {
    var cursor = ByteCursor(data: payload, baseOffset: fileOffset)
    guard payload.count >= 2 else {
        throw PGSError.invalidSegment(
            offset: fileOffset,
            kind: "PDS",
            message: "it needs a palette id and version."
        )
    }
    let id = try cursor.readUInt8("the palette id")
    let version = try cursor.readUInt8("the palette version")
    guard cursor.remaining % 5 == 0 else {
        throw PGSError.invalidSegment(
            offset: fileOffset,
            kind: "PDS",
            message: "palette entries must be 5 bytes each, but \(cursor.remaining) bytes remain."
        )
    }
    var entries: [PaletteEntry] = []
    while !cursor.isEmpty {
        let entryID = try cursor.readUInt8("a palette entry id")
        let y = try cursor.readUInt8("palette Y")
        let cr = try cursor.readUInt8("palette Cr")
        let cb = try cursor.readUInt8("palette Cb")
        let a = try cursor.readUInt8("palette alpha")
        entries.append(PaletteEntry(id: entryID, y: y, cr: cr, cb: cb, a: a))
    }
    return PaletteSegment(id: id, version: version, entries: entries)
}
