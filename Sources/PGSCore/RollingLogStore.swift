import Foundation

/// A plain-text log split across a few files so the folder stays under a size cap.
///
/// The active file is `PGS2SRT.log`. Older files are `PGS2SRT.log.1`, then `.2`,
/// and so on. When the next line would push the active file past its share of
/// the cap, the files rotate and the oldest one is deleted.
public final class RollingLogStore: @unchecked Sendable {
    public static let defaultMaxTotalBytes = 5 * 1024 * 1024
    public static let defaultFileCount = 3
    public static let activeFileName = "PGS2SRT.log"

    public let directory: URL
    public let maxTotalBytes: Int
    public let fileCount: Int

    private let lock = NSLock()

    public init(
        directory: URL,
        maxTotalBytes: Int = defaultMaxTotalBytes,
        fileCount: Int = defaultFileCount
    ) {
        self.directory = directory
        self.maxTotalBytes = max(1, maxTotalBytes)
        self.fileCount = max(1, fileCount)
    }

    /// Each file's share of `maxTotalBytes`. A single line longer than this is still written.
    public var maxFileBytes: Int {
        max(1, maxTotalBytes / fileCount)
    }

    public func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let text = line.hasSuffix("\n") ? line : line + "\n"
        let data = Data(text.utf8)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return
        }
        rotateIfNeeded(incomingBytes: data.count)
        let url = activeURL
        if FileManager.default.fileExists(atPath: url.path),
           let handle = FileHandle(forWritingAtPath: url.path) {
            do {
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
            }
            return
        }
        try? data.write(to: url)
    }

    /// Oldest archived lines first, then the active file.
    public func combinedText() -> String {
        lock.lock()
        defer { lock.unlock() }
        var parts: [String] = []
        if fileCount > 1 {
            for generation in stride(from: fileCount - 1, through: 1, by: -1) {
                parts.append(read(archiveURL(generation)))
            }
        }
        parts.append(read(activeURL))
        return parts.joined()
    }

    private var activeURL: URL {
        directory.appendingPathComponent(Self.activeFileName)
    }

    private func archiveURL(_ generation: Int) -> URL {
        directory.appendingPathComponent("\(Self.activeFileName).\(generation)")
    }

    private func rotateIfNeeded(incomingBytes: Int) {
        let url = activeURL
        let size = fileSize(url)
        guard size > 0, size + incomingBytes > maxFileBytes else { return }
        let generations = fileCount - 1
        guard generations >= 1 else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.removeItem(at: archiveURL(generations))
        if generations >= 2 {
            for generation in stride(from: generations - 1, through: 1, by: -1) {
                move(archiveURL(generation), to: archiveURL(generation + 1))
            }
        }
        move(url, to: archiveURL(1))
    }

    private func move(_ source: URL, to destination: URL) {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: source, to: destination)
    }

    private func fileSize(_ url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else {
            return 0
        }
        return number.intValue
    }

    private func read(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
