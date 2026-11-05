import Foundation

/// Session pictures for one converted file.
///
/// Bitmaps stay in a temporary folder and are not written next to the source.
/// The folder name is checked before deletion so a bad path cannot remove the
/// `.sup`. Cue text is not written into these files and is not logged.
public enum CuePictureFiles {
    private static let magic = Data("PGSIMG01".utf8)
    private static let prefix = "PGS2SRT-review-"
    /// A subtitle crop larger than this is refused instead of being loaded.
    private static let maximumPixels = 8_000_000

    public static func write(_ images: [UUID: SubtitleImage]) throws -> String? {
        if images.isEmpty { return nil }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            for (id, image) in images {
                let url = root.appendingPathComponent(id.uuidString)
                try Data(encode(image)).write(to: url, options: .atomic)
            }
        } catch {
            remove(root.path)
            throw error
        }
        return root.path
    }

    public static func read(id: UUID, from directory: String) -> SubtitleImage? {
        let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(id.uuidString)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    public static func remove(_ directory: String?) {
        guard let directory, !directory.isEmpty else { return }
        let name = URL(fileURLWithPath: directory).lastPathComponent
        guard name.hasPrefix(prefix) else { return }
        try? FileManager.default.removeItem(atPath: directory)
    }

    static func encode(_ image: SubtitleImage) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(magic.count + 24 + image.rgba.count)
        bytes.append(contentsOf: magic)
        for value in [image.width, image.height, image.originX, image.originY, image.videoWidth, image.videoHeight] {
            var little = Int32(value).littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        bytes.append(contentsOf: image.rgba)
        return bytes
    }

    static func decode(_ data: Data) -> SubtitleImage? {
        guard data.count >= magic.count + 24 else { return nil }
        guard data.prefix(magic.count) == magic else { return nil }
        let fields: [Int] = (0..<6).map { index in
            Int(readInt32(data, at: magic.count + index * 4))
        }
        let width = fields[0]
        let height = fields[1]
        guard width > 0, height > 0, width <= 10_000, height <= 10_000 else { return nil }
        let pixels = width * height
        guard pixels <= maximumPixels else { return nil }
        let rgbaStart = magic.count + 24
        guard data.count == rgbaStart + pixels * 4 else { return nil }
        let rgba = [UInt8](data[rgbaStart...])
        return SubtitleImage(
            width: width,
            height: height,
            rgba: rgba,
            originX: fields[2],
            originY: fields[3],
            videoWidth: fields[4],
            videoHeight: fields[5]
        )
    }

    private static func readInt32(_ data: Data, at offset: Int) -> Int32 {
        let start = data.index(data.startIndex, offsetBy: offset)
        let b0 = Int32(data[start])
        let b1 = Int32(data[data.index(start, offsetBy: 1)])
        let b2 = Int32(data[data.index(start, offsetBy: 2)])
        let b3 = Int32(data[data.index(start, offsetBy: 3)])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}

/// Tracks picture folders so they are removed when the queue drops the file,
/// and also if the queue itself is released.
public final class CuePictureSession: @unchecked Sendable {
    private let lock = NSLock()
    private var directories: [UUID: String] = [:]

    public init() {}

    public func store(_ directory: String?, for id: UUID) {
        lock.lock()
        let previous = directories.removeValue(forKey: id)
        if let directory {
            directories[id] = directory
        }
        lock.unlock()
        if let previous, previous != directory {
            CuePictureFiles.remove(previous)
        }
    }

    public func directory(for id: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return directories[id]
    }

    public func discard(_ id: UUID) {
        lock.lock()
        let directory = directories.removeValue(forKey: id)
        lock.unlock()
        CuePictureFiles.remove(directory)
    }

    public func discard(_ ids: [UUID]) {
        for id in ids {
            discard(id)
        }
    }

    deinit {
        lock.lock()
        let leftover = Array(directories.values)
        directories.removeAll()
        lock.unlock()
        for directory in leftover {
            CuePictureFiles.remove(directory)
        }
    }
}

/// A transcription plus its review document. Picture bytes are already on disk.
public struct PackedReview: Equatable, Sendable {
    public var document: CueDocument
    public var pictureDirectory: String?
    public var srt: String
    public var cueCount: Int
    public var unrecognizedCount: Int

    public init(
        document: CueDocument,
        pictureDirectory: String?,
        srt: String,
        cueCount: Int,
        unrecognizedCount: Int
    ) {
        self.document = document
        self.pictureDirectory = pictureDirectory
        self.srt = srt
        self.cueCount = cueCount
        self.unrecognizedCount = unrecognizedCount
    }
}

public enum ReviewArchive {
    /// Spills cue pictures into a temp folder and builds the editable document.
    /// The returned document does not keep the bitmaps. Cue text is not logged.
    public static func pack(_ result: TranscriptionResult) -> PackedReview {
        var pictureIDs: [Int: UUID] = [:]
        var images: [UUID: SubtitleImage] = [:]
        if !result.captured.isEmpty {
            for (index, item) in result.captured.enumerated() {
                guard let image = item.image else { continue }
                let id = UUID()
                images[id] = image
                pictureIDs[index] = id
            }
        }
        var directory: String?
        if !images.isEmpty {
            directory = try? CuePictureFiles.write(images)
            if directory == nil {
                pictureIDs.removeAll()
            }
        }
        let document: CueDocument
        if !result.captured.isEmpty {
            let cues = result.captured.enumerated().map { index, item in
                ReviewCue(
                    startPTS: item.startPTS,
                    endPTS: item.endPTS,
                    text: item.text,
                    failureMessage: item.failureMessage,
                    confidence: item.confidence,
                    alternatives: item.alternatives,
                    pictureID: pictureIDs[index]
                )
            }
            document = CueDocument.recognized(cues)
        } else {
            document = CueDocument.fromTranscription(result)
        }
        return PackedReview(
            document: document,
            pictureDirectory: directory,
            srt: result.srt,
            cueCount: result.cues.count,
            unrecognizedCount: result.failures.count
        )
    }
}
