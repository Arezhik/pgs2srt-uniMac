import Foundation
@testable import PGSCore

struct PaletteSpec {
    var id: UInt8
    var y: UInt8
    var cr: UInt8
    var cb: UInt8
    var a: UInt8

    static func limitedWhite(_ id: UInt8, alpha: UInt8 = 255) -> PaletteSpec {
        PaletteSpec(id: id, y: 235, cr: 128, cb: 128, a: alpha)
    }

    static func limitedBlack(_ id: UInt8, alpha: UInt8 = 255) -> PaletteSpec {
        PaletteSpec(id: id, y: 16, cr: 128, cb: 128, a: alpha)
    }
}

struct ObjectSpec {
    var id: UInt16 = 1
    var width: Int
    var height: Int
    var pixels: [UInt8]
    var x: Int = 0
    var y: Int = 0
    var windowID: UInt8 = 0
    var forced: Bool = false
    var crop: (x: Int, y: Int, width: Int, height: Int)? = nil
    var version: UInt8 = 0
    /// Split the RLE payload so the object spans more than one ODS.
    var splitEvery: Int? = nil
    /// Added to the declared object-data length. Zero writes a consistent file.
    var declaredLengthDelta: Int = 0
    var padLines: Bool = true
}

struct WindowSpec {
    var id: UInt8
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

struct SUPFile {
    var data = Data()

    mutating func appendSegment(pts: UInt32, dts: UInt32 = 0, type: UInt8, payload: [UInt8]) {
        data.append(0x50)
        data.append(0x47)
        data.append(contentsOf: be32(pts))
        data.append(contentsOf: be32(dts))
        data.append(type)
        data.append(UInt8((payload.count >> 8) & 0xFF))
        data.append(UInt8(payload.count & 0xFF))
        data.append(contentsOf: payload)
    }
}

func makeShow(
    pts: UInt32,
    videoWidth: Int = 32,
    videoHeight: Int = 32,
    state: UInt8 = 0x80,
    paletteID: UInt8 = 0,
    paletteVersion: UInt8 = 0,
    palette: [PaletteSpec],
    objects: [ObjectSpec],
    windows: [WindowSpec]? = nil,
    paletteUpdate: Bool = false,
    frameRate: UInt8 = 0x10,
    compositionNumber: UInt16 = 1,
    includeODS: Bool = true,
    includeEnd: Bool = true,
    odsPTS: UInt32? = nil
) -> Data {
    var file = SUPFile()
    let resolvedWindows = windows ?? [WindowSpec(id: 0, x: 0, y: 0, width: videoWidth, height: videoHeight)]
    file.appendSegment(
        pts: pts,
        type: SegmentKind.pcs,
        payload: pcsPayload(
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            frameRate: frameRate,
            compositionNumber: compositionNumber,
            state: state,
            paletteUpdate: paletteUpdate,
            paletteID: paletteID,
            objects: objects
        )
    )
    if !resolvedWindows.isEmpty {
        file.appendSegment(pts: pts, type: SegmentKind.wds, payload: wdsPayload(resolvedWindows))
    }
    file.appendSegment(
        pts: pts,
        type: SegmentKind.pds,
        payload: pdsPayload(id: paletteID, version: paletteVersion, entries: palette)
    )
    if includeODS {
        for object in objects {
            appendODS(object, pts: odsPTS ?? pts, to: &file)
        }
    }
    if includeEnd {
        file.appendSegment(pts: pts, type: SegmentKind.end, payload: [])
    }
    return file.data
}

func makeClear(
    pts: UInt32,
    videoWidth: Int = 32,
    videoHeight: Int = 32,
    state: UInt8 = 0x00
) -> Data {
    var file = SUPFile()
    file.appendSegment(
        pts: pts,
        type: SegmentKind.pcs,
        payload: pcsPayload(
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            frameRate: 0x10,
            compositionNumber: 0,
            state: state,
            paletteUpdate: false,
            paletteID: 0,
            objects: []
        )
    )
    file.appendSegment(pts: pts, type: SegmentKind.end, payload: [])
    return file.data
}

func pcsPayload(
    videoWidth: Int,
    videoHeight: Int,
    frameRate: UInt8,
    compositionNumber: UInt16,
    state: UInt8,
    paletteUpdate: Bool,
    paletteID: UInt8,
    objects: [ObjectSpec]
) -> [UInt8] {
    var payload: [UInt8] = []
    payload.append(contentsOf: be16(videoWidth))
    payload.append(contentsOf: be16(videoHeight))
    payload.append(frameRate)
    payload.append(contentsOf: be16(Int(compositionNumber)))
    payload.append(state)
    payload.append(paletteUpdate ? 0x80 : 0x00)
    payload.append(paletteID)
    payload.append(UInt8(objects.count))
    for object in objects {
        payload.append(contentsOf: be16(Int(object.id)))
        payload.append(object.windowID)
        var flags: UInt8 = 0
        if object.crop != nil { flags |= 0x80 }
        if object.forced { flags |= 0x40 }
        payload.append(flags)
        payload.append(contentsOf: be16(object.x))
        payload.append(contentsOf: be16(object.y))
        if let crop = object.crop {
            payload.append(contentsOf: be16(crop.x))
            payload.append(contentsOf: be16(crop.y))
            payload.append(contentsOf: be16(crop.width))
            payload.append(contentsOf: be16(crop.height))
        }
    }
    return payload
}

func wdsPayload(_ windows: [WindowSpec]) -> [UInt8] {
    var payload: [UInt8] = [UInt8(windows.count)]
    for window in windows {
        payload.append(window.id)
        payload.append(contentsOf: be16(window.x))
        payload.append(contentsOf: be16(window.y))
        payload.append(contentsOf: be16(window.width))
        payload.append(contentsOf: be16(window.height))
    }
    return payload
}

func pdsPayload(id: UInt8, version: UInt8, entries: [PaletteSpec]) -> [UInt8] {
    var payload: [UInt8] = [id, version]
    for entry in entries {
        payload.append(entry.id)
        payload.append(entry.y)
        payload.append(entry.cr)
        payload.append(entry.cb)
        payload.append(entry.a)
    }
    return payload
}

func appendODS(_ object: ObjectSpec, pts: UInt32, to file: inout SUPFile) {
    let rle = Array(encodeRLE(pixels: object.pixels, width: object.width, height: object.height, padLines: object.padLines))
    let piece = object.splitEvery ?? max(rle.count, 1)
    var offset = 0
    var isFirst = true
    while isFirst || offset < rle.count {
        let take = min(piece, rle.count - offset)
        let chunk = Array(rle[offset..<(offset + take)])
        let isLast = offset + take >= rle.count
        var payload: [UInt8] = []
        payload.append(contentsOf: be16(Int(object.id)))
        payload.append(object.version)
        let flags: UInt8
        if isFirst && isLast {
            flags = 0xC0
        } else if isFirst {
            flags = 0x80
        } else if isLast {
            flags = 0x40
        } else {
            flags = 0x00
        }
        payload.append(flags)
        if isFirst {
            let declared = rle.count + 4 + object.declaredLengthDelta
            payload.append(contentsOf: be24(declared))
            payload.append(contentsOf: be16(object.width))
            payload.append(contentsOf: be16(object.height))
        }
        payload.append(contentsOf: chunk)
        file.appendSegment(pts: pts, type: SegmentKind.ods, payload: payload)
        offset += take
        isFirst = false
        if rle.isEmpty { break }
    }
}

func encodeRLE(pixels: [UInt8], width: Int, height: Int, padLines: Bool) -> Data {
    var output = Data()
    for y in 0..<height {
        let lineStart = output.count
        var x = 0
        while x < width {
            let color = pixels[y * width + x]
            var length = 1
            while x + length < width && pixels[y * width + x + length] == color && length < 0x3FFF {
                length += 1
            }
            if color != 0 && length <= 2 {
                output.append(color)
                if length == 2 { output.append(color) }
            } else if color == 0 && length < 0x40 {
                output.append(0)
                output.append(UInt8(length))
            } else if color == 0 {
                output.append(0)
                output.append(UInt8(0x40 | (length >> 8)))
                output.append(UInt8(length & 0xFF))
            } else if length < 0x40 {
                output.append(0)
                output.append(UInt8(0x80 | length))
                output.append(color)
            } else {
                output.append(0)
                output.append(UInt8(0xC0 | (length >> 8)))
                output.append(UInt8(length & 0xFF))
                output.append(color)
            }
            x += length
        }
        output.append(0)
        output.append(0)
        if padLines && ((output.count - lineStart) % 2 == 1) {
            output.append(0)
        }
    }
    return output
}

func be16(_ value: Int) -> [UInt8] {
    let unsigned = UInt16(value)
    return [UInt8(unsigned >> 8), UInt8(unsigned & 0xFF)]
}

func be24(_ value: Int) -> [UInt8] {
    let unsigned = UInt32(value)
    return [UInt8((unsigned >> 16) & 0xFF), UInt8((unsigned >> 8) & 0xFF), UInt8(unsigned & 0xFF)]
}

func be32(_ value: UInt32) -> [UInt8] {
    [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF)
    ]
}

func singlePixelObject(
    _ index: UInt8 = 1,
    id: UInt16 = 1,
    x: Int = 0,
    y: Int = 0,
    forced: Bool = false
) -> ObjectSpec {
    ObjectSpec(id: id, width: 1, height: 1, pixels: [index], x: x, y: y, forced: forced)
}
