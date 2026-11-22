import Foundation
import XCTest

/// Temporary folders and tiny media files for XCUITest. Each test gets its own
/// root under the system temp directory, with `video/`, `audio/`, `input/`, and
/// `output/` already created. Call `cleanup()` from `tearDown`.
final class UITestFixtureBuilder {
    let root: URL
    let video: URL
    let audio: URL
    let input: URL
    let output: URL

    private let fileManager = FileManager.default

    init() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        video = root.appendingPathComponent("video", isDirectory: true)
        audio = root.appendingPathComponent("audio", isDirectory: true)
        input = root.appendingPathComponent("input", isDirectory: true)
        output = root.appendingPathComponent("output", isDirectory: true)
        for folder in [video, audio, input, output] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    func cleanup() {
        try? fileManager.removeItem(at: root)
    }

    /// A 0-byte placeholder (`.mkv`, `.mka`, `.mp4`, `.sup`, `.srt`) for queue and matching tests.
    @discardableResult
    func createDummyFile(in directory: URL, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    /// A UTF-8 `.srt` with sequential `00:00:00,000 --> 00:00:01,000`-style timecodes.
    @discardableResult
    func createValidSRTFile(in directory: URL, named name: String, lines: [String] = ["Hello", "World"]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var body = ""
        for (index, line) in lines.enumerated() {
            let start = Self.srtTimestamp(seconds: index)
            let end = Self.srtTimestamp(seconds: index + 1)
            body += "\(index + 1)\n\(start) --> \(end)\n\(line)\n\n"
        }
        try body.data(using: .utf8)!.write(to: url)
        return url
    }

    /// A minimal binary PGS (`.sup`) that header and track scanners accept: `PG` magic,
    /// PTS/DTS, an epoch-start Presentation Composition Segment (`0x16`) with no
    /// composition objects, and an End of Display Set (`0x80`).
    @discardableResult
    func createValidPGSFile(in directory: URL, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        // 1920x1080, frame rate 0x10, composition 0, epoch start, no palette update, palette 0, 0 objects.
        let pcsPayload: [UInt8] = [
            0x07, 0x80,
            0x04, 0x38,
            0x10,
            0x00, 0x00,
            0x80,
            0x00,
            0x00,
            0x00,
        ]
        var data = Data()
        Self.appendPGSSegment(to: &data, pts: 90_000, dts: 0, type: 0x16, payload: pcsPayload)
        Self.appendPGSSegment(to: &data, pts: 90_000, dts: 0, type: 0x80, payload: [])
        try data.write(to: url)
        return url
    }

    /// A 1-second synthetic container written with `ffmpeg`. Throws `XCTSkip` if
    /// ffmpeg is not at `/opt/homebrew/bin/ffmpeg` or `/usr/local/bin/ffmpeg`.
    /// `.mka` is audio-only. Video uses `libx264`, then `mpeg4` if that fails.
    @discardableResult
    func createValidMediaFile(
        in directory: URL,
        named name: String,
        includeAudio: Bool = true,
        includeSubtitles: Bool = false
    ) throws -> URL {
        let ffmpeg = try Self.ffmpegURL()
        let ext = (name as NSString).pathExtension.lowercased()
        let destination = directory.appendingPathComponent(name)
        let audioOnly = ext == "mka"
        let wantsAudio = includeAudio || audioOnly
        let wantsSubtitles = includeSubtitles && !audioOnly

        var subtitleURL: URL?
        if wantsSubtitles {
            subtitleURL = try createValidSRTFile(
                in: root,
                named: "\(UUID().uuidString).srt",
                lines: ["Hello", "World"]
            )
        }
        defer {
            if let subtitleURL = subtitleURL {
                try? fileManager.removeItem(at: subtitleURL)
            }
        }

        var inputs: [String] = ["-y", "-hide_banner", "-loglevel", "error"]
        if !audioOnly {
            inputs += ["-f", "lavfi", "-i", "color=c=black:s=64x64:d=1"]
        }
        if wantsAudio {
            inputs += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"]
        }
        if let subtitleURL = subtitleURL {
            inputs += ["-i", subtitleURL.path]
        }

        func codecArguments(videoCodec: String) -> [String] {
            var arguments: [String] = []
            if !audioOnly {
                arguments += ["-c:v", videoCodec, "-pix_fmt", "yuv420p"]
            }
            if wantsAudio {
                arguments += ["-c:a", "aac"]
            }
            if wantsSubtitles {
                arguments += ["-c:s", ext == "mp4" ? "mov_text" : "srt"]
            }
            arguments += ["-t", "1", "-shortest", destination.path]
            return arguments
        }

        do {
            try Self.run(ffmpeg, arguments: inputs + codecArguments(videoCodec: "libx264"))
        } catch {
            if audioOnly {
                throw error
            }
            try Self.run(ffmpeg, arguments: inputs + codecArguments(videoCodec: "mpeg4"))
        }
        return destination
    }

    private static func ffmpegURL() throws -> URL {
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
        ]
        for url in candidates {
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        throw XCTSkip("ffmpeg was not found at /opt/homebrew/bin/ffmpeg or /usr/local/bin/ffmpeg")
    }

    private static func run(_ executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let standardError = Pipe()
        process.standardOutput = Pipe()
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            return
        }
        let data = (try? standardError.fileHandleForReading.readToEnd()) ?? Data()
        let stderr = String(data: data, encoding: .utf8) ?? ""
        throw UITestFixtureBuilderError(
            message: "ffmpeg exited with status \(process.terminationStatus): \(stderr)"
        )
    }

    private static func appendPGSSegment(to data: inout Data, pts: UInt32, dts: UInt32, type: UInt8, payload: [UInt8]) {
        data.append(0x50)
        data.append(0x47)
        data.append(contentsOf: be32(pts))
        data.append(contentsOf: be32(dts))
        data.append(type)
        data.append(UInt8((payload.count >> 8) & 0xFF))
        data.append(UInt8(payload.count & 0xFF))
        data.append(contentsOf: payload)
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    private static func srtTimestamp(seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d:%02d,000", hours, minutes, secs)
    }
}

private struct UITestFixtureBuilderError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
