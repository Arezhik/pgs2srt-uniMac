import XCTest
@testable import PGSCore

final class MKVReaderTests: XCTestCase {
    func testOnePGSTrackBecomesASupPacket() throws {
        let segment = Data([0x80, 0x00, 0x00])
        let file = try MKVFixture.build(tracks: [.pgs(number: 1, language: "eng", ietf: "en")], blocks: [
            .init(track: 1, timestamp: 1_000, frames: [segment])
        ])
        let url = try write(file)
        let tracks = try MKVReader.listTracks(at: url.path)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].id, 0)
        XCTAssertEqual(tracks[0].number, 1)
        XCTAssertEqual(tracks[0].language, "eng")
        XCTAssertEqual(tracks[0].languageIETF, "en")
        XCTAssertTrue(tracks[0].isEnglish)
        let extracted = try MKVReader.extract(at: url.path, trackIDs: [0])
        let sup = try XCTUnwrap(extracted[0])
        XCTAssertEqual(sup, expectedSUP(segment, pts: 90_000))
    }

    func testSeveralTracksAndADisplaySetInOneBlock() throws {
        let pcs = Data([0x16, 0x00, 0x02, 0xAA, 0xBB])
        let end = Data([0x80, 0x00, 0x00])
        let file = try MKVFixture.build(
            tracks: [
                .video(number: 1),
                .pgs(number: 2, language: "eng", ietf: "en", name: "English", forced: false, isDefault: true),
                .pgs(number: 3, language: "spa", ietf: "es", name: "Spanish", forced: true, isDefault: false)
            ],
            blocks: [
                .init(track: 1, timestamp: 0, frames: [Data([0x00, 0x01, 0x02, 0x03])]),
                .init(track: 2, timestamp: 2_000, frames: [pcs + end]),
                .init(track: 3, timestamp: 2_000, frames: [end])
            ]
        )
        let url = try write(file)
        let tracks = try MKVReader.listTracks(at: url.path)
        XCTAssertEqual(tracks.map(\.id), [1, 2])
        XCTAssertEqual(tracks.map(\.number), [2, 3])
        XCTAssertEqual(tracks[0].displayLanguage, "English")
        XCTAssertEqual(tracks[1].displayLanguage, "es")
        XCTAssertTrue(tracks[1].forced)
        XCTAssertFalse(tracks[1].isDefault)
        XCTAssertEqual(tracks[1].pickerDetail, "Track 3 · Forced · Spanish")
        let extracted = try MKVReader.extract(at: url.path, trackIDs: [1, 2])
        XCTAssertEqual(extracted[1], expectedSUP(pcs, pts: 180_000) + expectedSUP(end, pts: 180_000))
        XCTAssertEqual(extracted[2], expectedSUP(end, pts: 180_000))
        let onlyEnglish = try MKVReader.extract(at: url.path, trackIDs: [1])
        XCTAssertNil(onlyEnglish[2])
        XCTAssertEqual(onlyEnglish[1]?.count, (expectedSUP(pcs, pts: 180_000) + expectedSUP(end, pts: 180_000)).count)
    }

    func testZlibAndHeaderStripping() throws {
        let segment = Data([0x80, 0x00, 0x00])
        let compressed = try Zlib.deflate(segment)
        XCTAssertNotEqual(compressed, segment)
        let stripped = Data(segment.dropFirst())
        let file = try MKVFixture.build(
            tracks: [
                .pgs(number: 1, language: "eng", ietf: "en", compression: .zlib),
                .pgs(number: 2, language: "fra", ietf: "fr", compression: .headerStrip(Data([segment[0]])))
            ],
            blocks: [
                .init(track: 1, timestamp: 0, frames: [compressed]),
                .init(track: 2, timestamp: 40, frames: [stripped])
            ]
        )
        let url = try write(file)
        let extracted = try MKVReader.extract(at: url.path, trackIDs: [0, 1])
        XCTAssertEqual(extracted[0], expectedSUP(segment, pts: 0))
        XCTAssertEqual(extracted[1], expectedSUP(segment, pts: 3_600))
    }

    func testNoPGSTrack() throws {
        let file = try MKVFixture.build(tracks: [.video(number: 1)], blocks: [
            .init(track: 1, timestamp: 0, frames: [Data([0x01])])
        ])
        let url = try write(file)
        let tracks = try MKVReader.listTracks(at: url.path)
        XCTAssertTrue(tracks.isEmpty)
        let extracted = try MKVReader.extract(at: url.path, trackIDs: [])
        XCTAssertTrue(extracted.isEmpty)
    }

    func testXiphLacingAndUnknownSizeCluster() throws {
        let first = Data([0x14, 0x00, 0x01, 0x11])
        let second = Data([0x80, 0x00, 0x00])
        let file = try MKVFixture.build(
            tracks: [.pgs(number: 4, language: "jpn", ietf: "ja", name: "Japanese", forced: true, isDefault: true)],
            blocks: [
                .init(track: 4, timestamp: 500, frames: [first, second], lacing: .xiph)
            ],
            unknownClusterSize: true
        )
        let url = try write(file)
        let tracks = try MKVReader.listTracks(at: url.path)
        XCTAssertEqual(tracks.map(\.id), [0])
        XCTAssertEqual(tracks[0].number, 4)
        XCTAssertEqual(tracks[0].language, "jpn")
        XCTAssertTrue(tracks[0].forced)
        XCTAssertEqual(tracks[0].pickerDetail, "Track 4 · Forced · Default · Japanese")
        let extracted = try MKVReader.extract(at: url.path, trackIDs: [0])
        let expected = expectedSUP(first, pts: 45_000) + expectedSUP(second, pts: 45_000)
        XCTAssertEqual(extracted[0], expected)
    }

    func testFixedAndEBMLLacing() throws {
        let a = Data([0x17, 0x00, 0x01, 0x01])
        let b = Data([0x17, 0x00, 0x01, 0x02])
        let c = Data([0x80, 0x00, 0x00])
        let fixed = try MKVFixture.build(tracks: [.pgs(number: 1, language: "eng", ietf: "en")], blocks: [
            .init(track: 1, timestamp: 0, frames: [a, b], lacing: .fixed)
        ])
        let fixedURL = try write(fixed)
        let fixedOut = try MKVReader.extract(at: fixedURL.path, trackIDs: [0])
        XCTAssertEqual(fixedOut[0], expectedSUP(a, pts: 0) + expectedSUP(b, pts: 0))

        let ebml = try MKVFixture.build(tracks: [.pgs(number: 1, language: "eng", ietf: "en")], blocks: [
            .init(track: 1, timestamp: 10, frames: [a, b, c], lacing: .ebml)
        ])
        let ebmlURL = try write(ebml)
        let ebmlOut = try MKVReader.extract(at: ebmlURL.path, trackIDs: [0])
        let pts = MKVReader.pts90kHz(timestamp: 10, scale: 1_000_000)
        XCTAssertEqual(ebmlOut[0], expectedSUP(a, pts: pts) + expectedSUP(b, pts: pts) + expectedSUP(c, pts: pts))
    }

    func testStoredSUPPacketIsRestamped() throws {
        var stored = Data([0x50, 0x47])
        stored.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        stored.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        stored.append(contentsOf: [0x80, 0x00, 0x00])
        let file = try MKVFixture.build(tracks: [.pgs(number: 1, language: "eng", ietf: "en")], blocks: [
            .init(track: 1, timestamp: 1_000, frames: [stored])
        ])
        let url = try write(file)
        let extracted = try MKVReader.extract(at: url.path, trackIDs: [0])
        XCTAssertEqual(extracted[0], expectedSUP(Data([0x80, 0x00, 0x00]), pts: 90_000))
    }

    func testUnreadableAndNonMatroska() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).mkv")
        XCTAssertThrowsError(try MKVReader.listTracks(at: missing.path)) { error in
            XCTAssertEqual(error as? MKVReadError, .unreadable)
        }
        let text = try write(Data("not an mkv".utf8))
        XCTAssertThrowsError(try MKVReader.listTracks(at: text.path)) { error in
            XCTAssertEqual(error as? MKVReadError, .notMatroska)
        }
    }

    func testNativeListMatchesTheMkvmergeFixtureShape() throws {
        let jsonURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mkv/english-later.json")
        let json = try Data(contentsOf: jsonURL)
        let identified = try MKVIdentify.tracks(in: json)
        let file = try MKVFixture.build(
            tracks: [
                .video(number: 1, language: "eng", ietf: "en"),
                .audio(number: 2, language: "eng", ietf: "en"),
                .pgs(number: 3, language: "jpn", ietf: "ja", name: "Japanese", forced: true, isDefault: true),
                .text(number: 4, language: "eng", ietf: "en", name: "English text"),
                .pgs(number: 5, language: "und", ietf: "en", name: "English", forced: false, isDefault: false),
                .pgs(number: 7, language: "eng", ietf: "en-US", name: "English SDH", forced: false, isDefault: false)
            ],
            blocks: []
        )
        let url = try write(file)
        let native = try MKVReader.listTracks(at: url.path)
        XCTAssertEqual(native.map(\.number), identified.map(\.number))
        XCTAssertEqual(native.map(\.language), identified.map(\.language))
        XCTAssertEqual(native.map(\.languageIETF), identified.map(\.languageIETF))
        XCTAssertEqual(native.map(\.name), identified.map(\.name))
        XCTAssertEqual(native.map(\.forced), identified.map(\.forced))
        XCTAssertEqual(native.map(\.isDefault), identified.map(\.isDefault))
        XCTAssertEqual(native.map(\.isEnglish), identified.map(\.isEnglish))
        // The fixture's mkvmerge ids skip 5. TrackEntry order is dense, which is what the reader records.
        XCTAssertEqual(native.map(\.id), [2, 4, 5])
        XCTAssertEqual(identified.map(\.id), [2, 4, 6])
    }

    func testMkvmergeOutputMatchesWhenTheToolIsInstalled() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/mkvmerge"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/mkvextract") else {
            throw XCTSkip("MKVToolNix is not installed")
        }
        let segment = Data([0x80, 0x00, 0x00])
        let sup = expectedSUP(segment, pts: 90_000) + expectedSUP(segment, pts: 180_000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pgs-mux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("one.sup")
        try sup.write(to: source)
        for compression in ["none", "zlib"] {
            let mkv = directory.appendingPathComponent("\(compression).mkv")
            let extracted = directory.appendingPathComponent("\(compression).sup")
            let merge = try runTool("/usr/bin/mkvmerge", [
                "-o", mkv.path, "--language", "0:eng", "--compression", "0:\(compression)", source.path
            ])
            XCTAssertEqual(merge, 0, compression)
            let tool = try MKVReader.extract(at: mkv.path, trackIDs: [0])
            let pull = try runTool("/usr/bin/mkvextract", [mkv.path, "tracks", "0:\(extracted.path)"])
            XCTAssertEqual(pull, 0, compression)
            let reference = try Data(contentsOf: extracted)
            XCTAssertEqual(tool[0], reference, compression)
        }
    }

    func testProgressAndCancellation() throws {
        let segment = Data([0x80, 0x00, 0x00])
        let file = try MKVFixture.build(tracks: [.pgs(number: 1, language: "eng", ietf: "en")], blocks: [
            .init(track: 1, timestamp: 0, frames: [segment])
        ])
        let url = try write(file)
        let box = ProgressBox()
        _ = try MKVReader.extract(at: url.path, trackIDs: [0]) { bytes, total in
            box.note(bytes, total)
        }
        XCTAssertGreaterThan(box.total, 0)
        XCTAssertLessThanOrEqual(box.bytes, box.total)
    }

    private func expectedSUP(_ segment: Data, pts: UInt32) -> Data {
        var data = Data([0x50, 0x47])
        data.append(contentsOf: [
            UInt8((pts >> 24) & 0xFF),
            UInt8((pts >> 16) & 0xFF),
            UInt8((pts >> 8) & 0xFF),
            UInt8(pts & 0xFF),
            0, 0, 0, 0
        ])
        data.append(segment)
        return data
    }

    private func runTool(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pgs-mkv-\(UUID().uuidString).mkv")
        try data.write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var seenBytes: Int64 = 0
    private var seenTotal: Int64 = 0

    func note(_ bytes: Int64, _ total: Int64) {
        lock.lock()
        seenBytes = bytes
        seenTotal = total
        lock.unlock()
    }

    var bytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return seenBytes
    }

    var total: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return seenTotal
    }
}

private enum MKVFixture {
    struct Track {
        enum Kind { case video, audio, pgs, text }
        enum Compression {
            case none
            case zlib
            case headerStrip(Data)
        }

        var kind: Kind
        var number: Int
        var language: String
        var ietf: String
        var name: String
        var forced: Bool
        var isDefault: Bool
        var compression: Compression

        static func video(number: Int, language: String = "und", ietf: String = "") -> Track {
            Track(kind: .video, number: number, language: language, ietf: ietf, name: "", forced: false, isDefault: true, compression: .none)
        }

        static func audio(number: Int, language: String, ietf: String) -> Track {
            Track(kind: .audio, number: number, language: language, ietf: ietf, name: "", forced: false, isDefault: true, compression: .none)
        }

        static func text(number: Int, language: String, ietf: String, name: String) -> Track {
            Track(kind: .text, number: number, language: language, ietf: ietf, name: name, forced: false, isDefault: false, compression: .none)
        }

        static func pgs(
            number: Int,
            language: String,
            ietf: String,
            name: String = "",
            forced: Bool = false,
            isDefault: Bool = true,
            compression: Compression = .none
        ) -> Track {
            Track(kind: .pgs, number: number, language: language, ietf: ietf, name: name, forced: forced, isDefault: isDefault, compression: compression)
        }

        var codec: String {
            switch kind {
            case .video: return "V_MPEG4/ISO/AVC"
            case .audio: return "A_AC3"
            case .pgs: return "S_HDMV/PGS"
            case .text: return "S_TEXT/UTF8"
            }
        }

        var type: UInt64 {
            switch kind {
            case .video: return 1
            case .audio: return 2
            case .pgs, .text: return 0x11
            }
        }
    }

    struct Block {
        enum Lacing { case none, xiph, fixed, ebml }
        var track: Int
        var timestamp: Int64
        var frames: [Data]
        var lacing: Lacing = .none
    }

    static func build(tracks: [Track], blocks: [Block], unknownClusterSize: Bool = false) throws -> Data {
        var info = Data()
        info.append(EBML.uint(0x2AD7B1, 1_000_000))
        info.append(EBML.string(0x4D80, "pgs2srt"))
        info.append(EBML.string(0x5741, "pgs2srt"))

        var trackBytes = Data()
        for (index, track) in tracks.enumerated() {
            var entry = Data()
            entry.append(EBML.uint(0xD7, UInt64(track.number)))
            entry.append(EBML.uint(0x73C5, UInt64(index + 1)))
            entry.append(EBML.uint(0x83, track.type))
            entry.append(EBML.uint(0x88, track.isDefault ? 1 : 0))
            entry.append(EBML.uint(0x55AA, track.forced ? 1 : 0))
            if !track.language.isEmpty {
                entry.append(EBML.string(0x22B59C, track.language))
            }
            if !track.ietf.isEmpty {
                entry.append(EBML.string(0x22B59D, track.ietf))
            }
            if !track.name.isEmpty {
                entry.append(EBML.string(0x536E, track.name))
            }
            entry.append(EBML.string(0x86, track.codec))
            switch track.compression {
            case .none:
                break
            case .zlib:
                entry.append(compression(algo: 0, settings: nil))
            case let .headerStrip(bytes):
                entry.append(compression(algo: 3, settings: bytes))
            }
            trackBytes.append(EBML.element(0xAE, entry))
        }

        var cluster = Data()
        cluster.append(EBML.uint(0xE7, 0))
        for block in blocks {
            cluster.append(simpleBlock(block))
        }

        var segment = Data()
        segment.append(EBML.element(0x1549A966, info))
        segment.append(EBML.element(0x1654AE6B, trackBytes))
        if unknownClusterSize {
            segment.append(EBML.unknown(0x1F43B675, cluster))
            segment.append(EBML.element(0x1C53BB6B, Data()))
        } else {
            segment.append(EBML.element(0x1F43B675, cluster))
        }
        return EBML.header() + EBML.element(0x18538067, segment)
    }

    private static func compression(algo: UInt64, settings: Data?) -> Data {
        var comp = Data()
        comp.append(EBML.uint(0x4254, algo))
        if let settings {
            comp.append(EBML.element(0x4255, settings))
        }
        var encoding = Data()
        encoding.append(EBML.uint(0x5031, 0))
        encoding.append(EBML.uint(0x5032, 1))
        encoding.append(EBML.uint(0x5033, 0))
        encoding.append(EBML.element(0x5034, comp))
        return EBML.element(0x6D80, EBML.element(0x6240, encoding))
    }

    private static func simpleBlock(_ block: Block) -> Data {
        var payload = Data()
        payload.append(contentsOf: EBML.size(block.track))
        let relative = Int16(block.timestamp)
        payload.append(UInt8((UInt16(bitPattern: relative) >> 8) & 0xFF))
        payload.append(UInt8(UInt16(bitPattern: relative) & 0xFF))
        let lace: Int
        switch block.lacing {
        case .none: lace = 0
        case .xiph: lace = 1
        case .fixed: lace = 2
        case .ebml: lace = 3
        }
        payload.append(0x80 | UInt8(lace << 1))
        if block.lacing == .none {
            payload.append(block.frames[0])
        } else {
            payload.append(UInt8(block.frames.count - 1))
            switch block.lacing {
            case .xiph:
                for frame in block.frames.dropLast() {
                    var left = frame.count
                    while left >= 255 {
                        payload.append(255)
                        left -= 255
                    }
                    payload.append(UInt8(left))
                }
            case .fixed:
                break
            case .ebml:
                payload.append(contentsOf: EBML.size(block.frames[0].count))
                var previous = block.frames[0].count
                if block.frames.count > 2 {
                    for frame in block.frames.dropFirst().dropLast() {
                        let delta = frame.count - previous
                        payload.append(contentsOf: EBML.signedSize(delta))
                        previous = frame.count
                    }
                }
            case .none:
                break
            }
            for frame in block.frames {
                payload.append(frame)
            }
        }
        return EBML.element(0xA3, payload)
    }
}

private enum EBML {
    static func header() -> Data {
        var payload = Data()
        payload.append(uint(0x4286, 1))
        payload.append(uint(0x42F7, 1))
        payload.append(uint(0x42F2, 4))
        payload.append(uint(0x42F3, 8))
        payload.append(string(0x4282, "matroska"))
        payload.append(uint(0x4287, 4))
        payload.append(uint(0x4285, 2))
        return element(0x1A45DFA3, payload)
    }

    static func element(_ id: UInt64, _ payload: Data) -> Data {
        var out = Data()
        out.append(contentsOf: idBytes(id))
        out.append(contentsOf: size(payload.count))
        out.append(payload)
        return out
    }

    static func unknown(_ id: UInt64, _ payload: Data) -> Data {
        var out = Data()
        out.append(contentsOf: idBytes(id))
        out.append(0xFF)
        out.append(payload)
        return out
    }

    static func uint(_ id: UInt64, _ value: UInt64) -> Data {
        var bytes: [UInt8] = []
        var remaining = value
        if remaining == 0 {
            bytes = [0]
        } else {
            while remaining > 0 {
                bytes.insert(UInt8(remaining & 0xFF), at: 0)
                remaining >>= 8
            }
        }
        return element(id, Data(bytes))
    }

    static func string(_ id: UInt64, _ value: String) -> Data {
        element(id, Data(value.utf8))
    }

    static func size(_ value: Int) -> [UInt8] {
        var width = 1
        while width < 8 {
            let limit = (1 << (7 * width)) - 2
            if value <= limit { break }
            width += 1
        }
        var stored = UInt64(value) | (UInt64(1) << (7 * width))
        var bytes = [UInt8](repeating: 0, count: width)
        for index in stride(from: width - 1, through: 0, by: -1) {
            bytes[index] = UInt8(stored & 0xFF)
            stored >>= 8
        }
        return bytes
    }

    static func signedSize(_ delta: Int) -> [UInt8] {
        let width = 1
        let bias = (1 << (7 * width - 1)) - 1
        let stored = delta + bias
        return size(stored)
    }

    private static func idBytes(_ id: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var value = id
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return bytes
    }
}
