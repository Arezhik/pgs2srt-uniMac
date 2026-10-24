import Foundation

/// One SRT cue. Times are 90 kHz presentation timestamps, the same clock as `SubtitleCue`.
public struct SRTCue: Equatable, Sendable {
    public var startPTS: UInt32
    public var endPTS: UInt32
    public var text: String

    public init(startPTS: UInt32, endPTS: UInt32, text: String) {
        self.startPTS = startPTS
        self.endPTS = endPTS
        self.text = text
    }
}

/// Line ending used between SRT fields. `.crlf` is the usual SRT form.
public enum SRTLineEnding: String, Equatable, Sendable {
    case crlf = "\r\n"
    case lf = "\n"
}

/// Writes numbered SRT cues. Text newlines are normalized to `lineEnding`.
public struct SRTWriter: Sendable {
    public var lineEnding: SRTLineEnding

    public init(lineEnding: SRTLineEnding = .crlf) {
        self.lineEnding = lineEnding
    }

    public func write(_ cues: [SRTCue]) throws -> String {
        let newline = lineEnding.rawValue
        var blocks: [String] = []
        blocks.reserveCapacity(cues.count)
        for (offset, cue) in cues.enumerated() {
            if cue.endPTS < cue.startPTS {
                throw SRTError.endBeforeStart(startPTS: cue.startPTS, endPTS: cue.endPTS)
            }
            let text = Self.normalize(cue.text, newline: newline)
            let block = "\(offset + 1)\(newline)\(Self.timestamp(pts: cue.startPTS)) --> \(Self.timestamp(pts: cue.endPTS))\(newline)\(text)\(newline)"
            blocks.append(block)
        }
        return blocks.joined(separator: newline)
    }

    /// `HH:MM:SS,mmm`, rounded to the nearest millisecond. Hours may grow past 99.
    public static func timestamp(pts: UInt32) -> String {
        let totalMillis = (UInt64(pts) * 1000 + 45_000) / 90_000
        let millis = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60
        return "\(pad(hours, 2)):\(pad(minutes, 2)):\(pad(seconds, 2)),\(pad(millis, 3))"
    }

    private static func normalize(_ text: String, newline: String) -> String {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasSuffix("\n") {
            normalized.removeLast()
        }
        return normalized.replacingOccurrences(of: "\n", with: newline)
    }

    private static func pad(_ value: UInt64, _ width: Int) -> String {
        let text = String(value)
        if text.count >= width { return text }
        return String(repeating: "0", count: width - text.count) + text
    }
}
