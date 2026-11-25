import Foundation

/// Why the native MKV reader stopped. The queue shows this when MKVToolNix is not installed.
public enum MKVReadError: Error, Equatable, LocalizedError {
    case unreadable
    case notMatroska
    case truncated
    case compressed
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            return "Could not read this MKV."
        case .notMatroska:
            return "This file is not a Matroska (MKV) file."
        case .truncated:
            return "This MKV is cut off and could not be read."
        case .compressed:
            return "The compressed subtitles in this MKV could not be read."
        case let .unsupported(message):
            return message
        }
    }
}

/// Reads PGS subtitle tracks out of a Matroska file without loading the whole file.
///
/// Video and audio blocks are skipped. Each selected track comes back as the bytes of a `.sup` file.
public enum MKVReader {
    /// PGS tracks in TrackEntry order. `id` is that order, starting at 0. `number` is the Matroska track number.
    public static func listTracks(at path: String) throws -> [PGSSubtitleTrack] {
        try Parser(path: path).listTracks()
    }

    /// One pass over the clusters. Keys are the track `id` values from `listTracks`.
    public static func extract(
        at path: String,
        trackIDs: Set<Int>,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) throws -> [Int: Data] {
        try Parser(path: path).extract(trackIDs: trackIDs, onProgress: onProgress)
    }

    /// 90 kHz presentation timestamp for a Matroska timestamp in TimestampScale units.
    static func pts90kHz(timestamp: Int64, scale: UInt64) -> UInt32 {
        if timestamp <= 0 || scale == 0 { return 0 }
        let ticks = UInt64(timestamp)
        let value: UInt64
        if scale == 1_000_000 {
            let product = ticks.multipliedReportingOverflow(by: 90)
            value = product.overflow ? UInt64(UInt32.max) : product.partialValue
        } else {
            value = scaledTicks(ticks, scale: scale)
        }
        if value > UInt64(UInt32.max) { return UInt32.max }
        return UInt32(value)
    }

    private static func scaledTicks(_ ticks: UInt64, scale: UInt64) -> UInt64 {
        let divisor: UInt64 = 1_000_000_000
        let g1 = gcd(scale, divisor)
        let scaleReduced = scale / g1
        var denominator = divisor / g1
        let g2 = gcd(90_000, denominator)
        let factor = UInt64(90_000) / g2
        denominator /= g2
        let first = ticks.multipliedReportingOverflow(by: scaleReduced)
        if first.overflow { return UInt64(UInt32.max) }
        let second = first.partialValue.multipliedReportingOverflow(by: factor)
        if second.overflow { return UInt64(UInt32.max) }
        return second.partialValue / denominator
    }

    private static func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var x = a
        var y = b
        while y != 0 {
            let next = x % y
            x = y
            y = next
        }
        return x == 0 ? 1 : x
    }
}

private final class Parser {
    private let stream: MKVStream
    private var scale: UInt64 = 1_000_000
    private var tracks: [RawTrack] = []
    private var sawTracks = false

    init(path: String) throws {
        stream = try MKVStream(path: path)
    }

    func listTracks() throws -> [PGSSubtitleTrack] {
        try walk(collecting: nil)
        return tracks.filter(\.isPGS).map(\.publicTrack)
    }

    func extract(
        trackIDs: Set<Int>,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) throws -> [Int: Data] {
        let selected = trackIDs
        var output: [Int: Data] = [:]
        for id in selected { output[id] = Data() }
        try walk(collecting: selected, output: &output, onProgress: onProgress)
        let known = Set(tracks.filter(\.isPGS).map(\.index))
        for id in selected where !known.contains(id) {
            throw MKVReadError.unsupported("A selected subtitle track is not in this MKV.")
        }
        return output
    }

    private func walk(
        collecting trackIDs: Set<Int>?,
        output: inout [Int: Data],
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) throws {
        let segmentEnd = try readHeader()
        var deferred: [ClusterSpan] = []
        var lastProgress = Date.distantPast
        while stream.offset + 1 < segmentEnd {
            if segmentEnd - stream.offset < 2 { break }
            let mark = stream.offset
            let element = try stream.readElement()
            if element.id == ID.cluster {
                if let size = element.size {
                    let span = ClusterSpan(start: element.dataOffset, end: element.dataOffset + size)
                    if sawTracks, trackIDs != nil {
                        try decode(span, trackIDs: trackIDs, output: &output)
                    } else {
                        try stream.skip(size)
                        if !sawTracks { deferred.append(span) }
                    }
                } else {
                    let span = try ClusterSpan.capture(element, stream: stream)
                    if sawTracks, trackIDs != nil {
                        try decode(span, trackIDs: trackIDs, output: &output)
                    } else if !sawTracks {
                        deferred.append(span)
                    }
                }
                try noteProgress(onProgress, last: &lastProgress, force: false)
            } else if element.id == ID.info {
                try readInfo(element)
            } else if element.id == ID.tracks {
                try readTracks(element)
                sawTracks = true
            } else if element.id == ID.void || element.id == ID.crc {
                try stream.skipPayload(of: element)
            } else if element.id == ID.ebml || element.id == ID.segment {
                throw MKVReadError.notMatroska
            } else {
                try stream.skipPayload(of: element)
            }
            if stream.offset <= mark {
                throw MKVReadError.truncated
            }
            if stream.offset > segmentEnd {
                throw MKVReadError.truncated
            }
        }
        for span in deferred {
            try decode(span, trackIDs: trackIDs, output: &output)
            try noteProgress(onProgress, last: &lastProgress, force: false)
        }
        try noteProgress(onProgress, last: &lastProgress, force: true)
    }

    private func walk(collecting trackIDs: Set<Int>?) throws {
        var output: [Int: Data] = [:]
        try walk(collecting: trackIDs, output: &output, onProgress: nil)
    }

    private func noteProgress(
        _ onProgress: (@Sendable (Int64, Int64) -> Void)?,
        last: inout Date,
        force: Bool
    ) throws {
        try Task.checkCancellation()
        guard let onProgress else { return }
        let now = Date()
        if force || now.timeIntervalSince(last) >= 0.2 {
            last = now
            onProgress(stream.offset, stream.length)
        }
    }

    private func readHeader() throws -> Int64 {
        let ebml = try stream.readElement()
        guard ebml.id == ID.ebml else { throw MKVReadError.notMatroska }
        var docType = ""
        try stream.readMaster(ebml) { child in
            if child.id == ID.docType {
                docType = try stream.readString(child)
            } else {
                try stream.skipPayload(of: child)
            }
        }
        let type = docType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard type == "matroska" || type == "webm" else { throw MKVReadError.notMatroska }
        while stream.offset < stream.length {
            let mark = stream.offset
            let next = try stream.readElement()
            if next.id == ID.segment {
                if let size = next.size {
                    return next.dataOffset + size
                }
                return stream.length
            }
            if next.id == ID.void || next.id == ID.crc {
                try stream.skipPayload(of: next)
            } else {
                throw MKVReadError.notMatroska
            }
            if stream.offset <= mark { throw MKVReadError.truncated }
        }
        throw MKVReadError.notMatroska
    }

    private func readInfo(_ element: Element) throws {
        try stream.readMaster(element) { child in
            if child.id == ID.timestampScale {
                let value = try stream.readUInt(child)
                if value > 0 { scale = value }
            } else {
                try stream.skipPayload(of: child)
            }
        }
    }

    private func readTracks(_ element: Element) throws {
        try stream.readMaster(element) { child in
            if child.id == ID.trackEntry {
                let index = tracks.count
                var track = RawTrack(index: index)
                try stream.readMaster(child) { field in
                    try readTrackField(field, track: &track)
                }
                if track.number == nil {
                    track.number = index
                }
                tracks.append(track)
            } else {
                try stream.skipPayload(of: child)
            }
        }
    }

    private func readTrackField(_ field: Element, track: inout RawTrack) throws {
        switch field.id {
        case ID.trackNumber:
            track.number = Int(try stream.readUInt(field))
        case ID.flagDefault:
            track.isDefault = try stream.readUInt(field) != 0
        case ID.flagForced:
            track.forced = try stream.readUInt(field) != 0
        case ID.language:
            track.language = try stream.readString(field)
        case ID.languageIETF:
            track.languageIETF = try stream.readString(field)
        case ID.name:
            track.name = try stream.readString(field)
        case ID.codecID:
            track.codecID = try stream.readString(field)
        case ID.contentEncodings:
            try readEncodings(field, track: &track)
        default:
            try stream.skipPayload(of: field)
        }
    }

    private func readEncodings(_ element: Element, track: inout RawTrack) throws {
        try stream.readMaster(element) { child in
            guard child.id == ID.contentEncoding else {
                try stream.skipPayload(of: child)
                return
            }
            var encoding = ContentEncoding()
            try stream.readMaster(child) { field in
                switch field.id {
                case ID.contentEncodingOrder:
                    encoding.order = Int(try stream.readUInt(field))
                case ID.contentEncodingType:
                    encoding.type = Int(try stream.readUInt(field))
                case ID.contentCompression:
                    try stream.readMaster(field) { comp in
                        switch comp.id {
                        case ID.contentCompAlgo:
                            encoding.algo = Int(try stream.readUInt(comp))
                        case ID.contentCompSettings:
                            encoding.settings = try stream.readData(comp)
                        default:
                            try stream.skipPayload(of: comp)
                        }
                    }
                default:
                    try stream.skipPayload(of: field)
                }
            }
            track.encodings.append(encoding)
        }
    }

    private func decode(
        _ span: ClusterSpan,
        trackIDs: Set<Int>?,
        output: inout [Int: Data]
    ) throws {
        guard trackIDs != nil else { return }
        try stream.seek(span.start)
        let end = span.end
        var clusterTimestamp: Int64 = 0
        while stream.offset < end {
            if end - stream.offset < 2 { break }
            let child = try stream.readElement()
            if let size = child.size, child.dataOffset + size > end {
                throw MKVReadError.truncated
            }
            switch child.id {
            case ID.timestamp:
                clusterTimestamp = Int64(try stream.readUInt(child))
            case ID.simpleBlock, ID.block:
                try consumeBlock(child, clusterTimestamp: clusterTimestamp, trackIDs: trackIDs, output: &output)
            case ID.blockGroup:
                try consumeBlockGroup(child, clusterTimestamp: clusterTimestamp, trackIDs: trackIDs, output: &output)
            default:
                try stream.skipPayload(of: child)
            }
        }
        if stream.offset < end {
            try stream.skip(end - stream.offset)
        }
    }

    private func consumeBlockGroup(
        _ element: Element,
        clusterTimestamp: Int64,
        trackIDs: Set<Int>?,
        output: inout [Int: Data]
    ) throws {
        try stream.readMaster(element) { child in
            if child.id == ID.block {
                try consumeBlock(child, clusterTimestamp: clusterTimestamp, trackIDs: trackIDs, output: &output)
            } else {
                try stream.skipPayload(of: child)
            }
        }
    }

    private func consumeBlock(
        _ element: Element,
        clusterTimestamp: Int64,
        trackIDs: Set<Int>?,
        output: inout [Int: Data]
    ) throws {
        guard let size = element.size else {
            throw MKVReadError.unsupported("This MKV has a subtitle block with an unknown size.")
        }
        let end = element.dataOffset + size
        let trackNumber = try stream.readSizeVInt().value
        let relative = try stream.readInt16()
        let flags = try stream.readByte()
        let lacing = (Int(flags) >> 1) & 0x03
        let sizes = try frameSizes(lacing: lacing, end: end)
        let timestamp = clusterTimestamp + Int64(relative)
        let match = tracks.first { $0.number == Int(trackNumber) && $0.isPGS }
        let wanted = match.map { trackIDs?.contains($0.index) == true } ?? false
        for frameSize in sizes {
            if frameSize < 0 || stream.offset + Int64(frameSize) > end {
                throw MKVReadError.truncated
            }
            if wanted, let match {
                let bytes = try stream.read(frameSize)
                let frame = try decodeFrame(bytes, encodings: match.encodings)
                let pts = MKVReader.pts90kHz(timestamp: timestamp, scale: scale)
                let packet = try SUPAssembly.packet(frame: frame, pts: pts)
                output[match.index, default: Data()].append(packet)
            } else {
                try stream.skip(Int64(frameSize))
            }
        }
        if stream.offset < end {
            try stream.skip(end - stream.offset)
        }
    }

    private func frameSizes(lacing: Int, end: Int64) throws -> [Int] {
        if lacing == 0 {
            let remaining = end - stream.offset
            if remaining < 0 || remaining > Int64(Int.max) { throw MKVReadError.truncated }
            return [Int(remaining)]
        }
        let count = Int(try stream.readByte()) + 1
        if count <= 0 || count > 256 {
            throw MKVReadError.unsupported("This MKV laces a subtitle block in a way this app cannot read.")
        }
        switch lacing {
        case 1:
            return try xiphSizes(count: count, end: end)
        case 2:
            return try fixedSizes(count: count, end: end)
        case 3:
            return try ebmlSizes(count: count, end: end)
        default:
            throw MKVReadError.unsupported("This MKV laces a subtitle block in a way this app cannot read.")
        }
    }

    private func xiphSizes(count: Int, end: Int64) throws -> [Int] {
        var sizes: [Int] = []
        if count > 1 {
            for _ in 0..<(count - 1) {
                var size = 0
                while true {
                    let byte = Int(try stream.readByte())
                    size += byte
                    if size > Self.maxFrame { throw MKVReadError.unsupported("A subtitle frame is too large.") }
                    if byte != 255 { break }
                }
                sizes.append(size)
            }
        }
        return try sizes + [lastSize(known: sizes, end: end)]
    }

    private func fixedSizes(count: Int, end: Int64) throws -> [Int] {
        let remaining = end - stream.offset
        if remaining < 0 || remaining % Int64(count) != 0 { throw MKVReadError.truncated }
        let size = Int(remaining / Int64(count))
        return Array(repeating: size, count: count)
    }

    private func ebmlSizes(count: Int, end: Int64) throws -> [Int] {
        let first = try stream.readSizeVInt()
        if first.unknown { throw MKVReadError.unsupported("This MKV laces a subtitle block in a way this app cannot read.") }
        var previous = try bounded(first.value)
        var sizes = [previous]
        if count > 2 {
            for _ in 0..<(count - 2) {
                let delta = try stream.readSignedVInt()
                let next = Int64(previous) + delta
                if next < 0 || next > Int64(Self.maxFrame) {
                    throw MKVReadError.unsupported("A subtitle frame is too large.")
                }
                previous = Int(next)
                sizes.append(previous)
            }
        }
        if count == 1 { return sizes }
        return try sizes + [lastSize(known: sizes, end: end)]
    }

    private func lastSize(known: [Int], end: Int64) throws -> Int {
        let used = known.reduce(0, +)
        let remaining = end - stream.offset
        if remaining < Int64(used) { throw MKVReadError.truncated }
        let last = remaining - Int64(used)
        if last > Int64(Self.maxFrame) { throw MKVReadError.unsupported("A subtitle frame is too large.") }
        return Int(last)
    }

    private func bounded(_ value: UInt64) throws -> Int {
        if value > UInt64(Self.maxFrame) { throw MKVReadError.unsupported("A subtitle frame is too large.") }
        return Int(value)
    }

    private func decodeFrame(_ data: Data, encodings: [ContentEncoding]) throws -> Data {
        var current = data
        for encoding in encodings.sorted(by: { $0.order > $1.order }) {
            if encoding.type != 0 {
                throw MKVReadError.unsupported("This MKV encrypts a subtitle track.")
            }
            switch encoding.algo {
            case 0:
                current = try Zlib.inflate(current)
            case 3:
                current = encoding.settings + current
            default:
                throw MKVReadError.unsupported("This MKV compresses a subtitle track in a way this app cannot read.")
            }
        }
        return current
    }

    private static let maxFrame = 32 * 1024 * 1024
}

private struct RawTrack {
    var index: Int
    var number: Int?
    var codecID = ""
    var language = ""
    var languageIETF = ""
    var name = ""
        var forced = false
        var isDefault = true
        var encodings: [ContentEncoding] = []

    var isPGS: Bool { codecID == MKVIdentify.pgsCodecID }

    var publicTrack: PGSSubtitleTrack {
        let resolvedNumber = number ?? index
        return PGSSubtitleTrack(
            id: index,
            number: resolvedNumber,
            language: language,
            languageIETF: languageIETF,
            name: name,
            forced: forced,
            isDefault: isDefault
        )
    }
}

private struct ContentEncoding {
    var order = 0
    var type = 0
    var algo = 0
    var settings = Data()
}

private enum SUPAssembly {
    static func packet(frame: Data, pts: UInt32) throws -> Data {
        let segments = try segments(in: frame)
        var out = Data()
        out.reserveCapacity(segments.reduce(0) { $0 + $1.count + 10 })
        for segment in segments {
            out.append(0x50)
            out.append(0x47)
            out.append(contentsOf: be32(pts))
            out.append(contentsOf: be32(0))
            out.append(segment)
        }
        return out
    }

    /// One PGS segment, or a display set of them. A stored `.sup` packet is accepted too.
    private static func segments(in frame: Data) throws -> [Data] {
        if let split = splitSegments(frame), !split.isEmpty { return split }
        if let stripped = splitSUP(frame), !stripped.isEmpty { return stripped }
        throw MKVReadError.unsupported("A subtitle frame is not a PGS segment.")
    }

    private static func splitSegments(_ data: Data) -> [Data]? {
        let bytes = [UInt8](data)
        guard let first = bytes.first, isSegmentType(first) else { return nil }
        var offset = 0
        var parts: [Data] = []
        while offset < bytes.count {
            if offset + 3 > bytes.count { return nil }
            let type = bytes[offset]
            guard isSegmentType(type) else { return nil }
            let size = (Int(bytes[offset + 1]) << 8) | Int(bytes[offset + 2])
            let total = 3 + size
            if size < 0 || offset + total > bytes.count { return nil }
            parts.append(Data(bytes[offset..<(offset + total)]))
            offset += total
        }
        return parts
    }

    private static func splitSUP(_ data: Data) -> [Data]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 13, bytes[0] == 0x50, bytes[1] == 0x47 else { return nil }
        var offset = 0
        var parts: [Data] = []
        while offset < bytes.count {
            if offset + 13 > bytes.count { return nil }
            guard bytes[offset] == 0x50, bytes[offset + 1] == 0x47 else { return nil }
            let size = (Int(bytes[offset + 11]) << 8) | Int(bytes[offset + 12])
            let total = 13 + size
            if offset + total > bytes.count { return nil }
            parts.append(Data(bytes[(offset + 10)..<(offset + total)]))
            offset += total
        }
        return parts
    }

    private static func isSegmentType(_ type: UInt8) -> Bool {
        type == 0x14 || type == 0x15 || type == 0x16 || type == 0x17 || type == 0x80
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }
}

private enum ID {
    static let ebml: UInt64 = 0x1A45DFA3
    static let docType: UInt64 = 0x4282
    static let segment: UInt64 = 0x18538067
    static let seekHead: UInt64 = 0x114D9B74
    static let info: UInt64 = 0x1549A966
    static let timestampScale: UInt64 = 0x2AD7B1
    static let tracks: UInt64 = 0x1654AE6B
    static let trackEntry: UInt64 = 0xAE
    static let trackNumber: UInt64 = 0xD7
    static let trackType: UInt64 = 0x83
    static let flagDefault: UInt64 = 0x88
    static let flagForced: UInt64 = 0x55AA
    static let name: UInt64 = 0x536E
    static let language: UInt64 = 0x22B59C
    static let languageIETF: UInt64 = 0x22B59D
    static let codecID: UInt64 = 0x86
    static let contentEncodings: UInt64 = 0x6D80
    static let contentEncoding: UInt64 = 0x6240
    static let contentEncodingOrder: UInt64 = 0x5031
    static let contentEncodingType: UInt64 = 0x5033
    static let contentCompression: UInt64 = 0x5034
    static let contentCompAlgo: UInt64 = 0x4254
    static let contentCompSettings: UInt64 = 0x4255
    static let cluster: UInt64 = 0x1F43B675
    static let timestamp: UInt64 = 0xE7
    static let simpleBlock: UInt64 = 0xA3
    static let blockGroup: UInt64 = 0xA0
    static let block: UInt64 = 0xA1
    static let crc: UInt64 = 0xBF
    static let void: UInt64 = 0xEC
    static let cues: UInt64 = 0x1C53BB6B
    static let attachments: UInt64 = 0x1941A469
    static let chapters: UInt64 = 0x1043A770
    static let tags: UInt64 = 0x1254C367

    static let segmentLevel: Set<UInt64> = [
        seekHead, info, tracks, cluster, cues, attachments, chapters, tags
    ]
}

private struct Element {
    var id: UInt64
    var size: Int64?
    var dataOffset: Int64
}

private struct ClusterSpan {
    var start: Int64
    var end: Int64

    static func capture(_ element: Element, stream: MKVStream) throws -> ClusterSpan {
        let start = element.dataOffset
        if let size = element.size {
            let end = start + size
            try stream.skip(size)
            return ClusterSpan(start: start, end: end)
        }
        while stream.offset < stream.length {
            let mark = stream.offset
            if stream.remaining < 2 { break }
            let id = try stream.peekID()
            if ID.segmentLevel.contains(id) { break }
            let child = try stream.readElement()
            try stream.skipPayload(of: child)
            if stream.offset <= mark { throw MKVReadError.truncated }
        }
        return ClusterSpan(start: start, end: stream.offset)
    }
}

private final class MKVStream {
    let length: Int64
    private let handle: FileHandle
    private(set) var offset: Int64 = 0
    private var buffer = Data()
    private var bufferStart: Int64 = 0

    var remaining: Int64 { length - offset }

    init(path: String) throws {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw MKVReadError.unreadable
        }
        self.handle = handle
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        if size < 0 {
            throw MKVReadError.unreadable
        }
        length = size
    }

    deinit {
        try? handle.close()
    }

    func seek(_ position: Int64) throws {
        if position < 0 || position > length { throw MKVReadError.truncated }
        offset = position
    }

    func readElement() throws -> Element {
        let id = try readID()
        let size = try readSizeVInt()
        if size.unknown { return Element(id: id, size: nil, dataOffset: offset) }
        if size.value > UInt64(Int64.max) { throw MKVReadError.truncated }
        return Element(id: id, size: Int64(size.value), dataOffset: offset)
    }

    func peekID() throws -> UInt64 {
        let mark = offset
        let id = try readID()
        offset = mark
        return id
    }

    func readMaster(_ element: Element, body: (Element) throws -> Void) throws {
        if let size = element.size {
            let end = element.dataOffset + size
            while offset < end {
                if end - offset < 2 { break }
                let mark = offset
                let child = try readElement()
                if let childSize = child.size, child.dataOffset + childSize > end {
                    throw MKVReadError.truncated
                }
                try body(child)
                if let childSize = child.size {
                    let childEnd = child.dataOffset + childSize
                    if offset < childEnd { try skip(childEnd - offset) }
                    if offset > childEnd { throw MKVReadError.truncated }
                }
                if offset <= mark { throw MKVReadError.truncated }
            }
            if offset > end { throw MKVReadError.truncated }
            if offset < end { try skip(end - offset) }
            return
        }
        if ID.segmentLevel.contains(element.id) || element.id == ID.segment {
            while offset < length {
                if remaining < 2 { break }
                let id = try peekID()
                if element.id == ID.segment && ID.segmentLevel.contains(id) == false && id != ID.void && id != ID.crc && id != ID.cluster {
                    // Keep reading the segment until the file ends. Children are the level check below.
                }
                if element.id != ID.segment && ID.segmentLevel.contains(id) { return }
                let mark = offset
                let child = try readElement()
                try body(child)
                if let childSize = child.size {
                    let childEnd = child.dataOffset + childSize
                    if offset < childEnd { try skip(childEnd - offset) }
                    if offset > childEnd { throw MKVReadError.truncated }
                }
                if offset <= mark { throw MKVReadError.truncated }
            }
            return
        }
        throw MKVReadError.unsupported("This MKV uses an unknown-size element this app cannot read.")
    }

    func skipPayload(of element: Element) throws {
        if let size = element.size {
            try skip(size)
            return
        }
        if element.id == ID.cluster {
            _ = try ClusterSpan.capture(element, stream: self)
            return
        }
        throw MKVReadError.unsupported("This MKV uses an unknown-size element this app cannot read.")
    }

    func readUInt(_ element: Element) throws -> UInt64 {
        let data = try readData(element)
        var value: UInt64 = 0
        for byte in data.prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    func readString(_ element: Element) throws -> String {
        let data = try readData(element)
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.replacingOccurrences(of: "\0", with: "")
    }

    func readData(_ element: Element) throws -> Data {
        guard let size = element.size else {
            throw MKVReadError.unsupported("This MKV uses an unknown-size element this app cannot read.")
        }
        if size > Int64(ParserMax.element) { throw MKVReadError.unsupported("An element in this MKV is too large.") }
        return try read(Int(size))
    }

    func read(_ count: Int) throws -> Data {
        if count == 0 { return Data() }
        if count < 0 { throw MKVReadError.truncated }
        if offset + Int64(count) > length { throw MKVReadError.truncated }
        var result = Data()
        result.reserveCapacity(count)
        var need = count
        while need > 0 {
            if offset < bufferStart || offset >= bufferStart + Int64(buffer.count) {
                try fill()
                if buffer.isEmpty { throw MKVReadError.truncated }
            }
            let local = Int(offset - bufferStart)
            let take = min(need, buffer.count - local)
            if take <= 0 { throw MKVReadError.truncated }
            result.append(buffer[buffer.startIndex + local ..< buffer.startIndex + local + take])
            offset += Int64(take)
            need -= take
        }
        return result
    }

    func skip(_ count: Int64) throws {
        if count < 0 { throw MKVReadError.truncated }
        if offset + count > length { throw MKVReadError.truncated }
        offset += count
    }

    func readByte() throws -> UInt8 {
        let data = try read(1)
        return data[data.startIndex]
    }

    func readInt16() throws -> Int16 {
        let data = try read(2)
        let value = (UInt16(data[data.startIndex]) << 8) | UInt16(data[data.startIndex + 1])
        return Int16(bitPattern: value)
    }

    func readID() throws -> UInt64 {
        let (value, _, _) = try readVInt(stripMarker: false)
        return value
    }

    func readSizeVInt() throws -> (value: UInt64, width: Int, unknown: Bool) {
        let (raw, width, _) = try readVInt(stripMarker: false)
        let value = raw & ((UInt64(1) << (7 * width)) - 1)
        let unknown = value == ((UInt64(1) << (7 * width)) - 1)
        return (value, width, unknown)
    }

    func readSignedVInt() throws -> Int64 {
        let (raw, width, _) = try readVInt(stripMarker: false)
        let value = raw & ((UInt64(1) << (7 * width)) - 1)
        let bias = (Int64(1) << (7 * width - 1)) - 1
        return Int64(value) - bias
    }

    private func readVInt(stripMarker: Bool) throws -> (UInt64, Int, UInt64) {
        let first = try readByte()
        let width = try vintWidth(first)
        var value = UInt64(first)
        for _ in 1..<width {
            value = (value << 8) | UInt64(try readByte())
        }
        let marker = UInt64(1) << (8 * width - width)
        if stripMarker {
            value &= ~marker
        }
        return (value, width, marker)
    }

    private func vintWidth(_ first: UInt8) throws -> Int {
        if first == 0 { throw MKVReadError.truncated }
        var width = 1
        var probe = first
        while probe & 0x80 == 0 {
            probe <<= 1
            width += 1
            if width > 8 { throw MKVReadError.truncated }
        }
        return width
    }

    private func fill() throws {
        try handle.seek(toOffset: UInt64(offset))
        let chunk = 256 * 1024
        let data = try handle.read(upToCount: chunk) ?? Data()
        buffer = data
        bufferStart = offset
    }
}

private enum ParserMax {
    static let element = 8 * 1024 * 1024
}

