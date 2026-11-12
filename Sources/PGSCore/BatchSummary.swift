import Foundation

/// The second line of the window footer, shared with the finish notification.
public struct BatchLine: Equatable, Sendable {
    public var text: String
    public var failed: Bool
    /// True while the batch is still running. A single output has no running line.
    public var running: Bool

    public init(text: String, failed: Bool, running: Bool) {
        self.text = text
        self.failed = failed
        self.running = running
    }
}

/// Dock badge and bar inputs. `fraction` is the whole batch, from 0 to 1.
public struct BatchMeter: Equatable, Sendable {
    public var active: Bool
    public var remaining: Int
    public var fraction: Double

    public init(active: Bool, remaining: Int, fraction: Double) {
        self.active = active
        self.remaining = remaining
        self.fraction = fraction
    }

    public static let idle = BatchMeter(active: false, remaining: 0, fraction: 0)
}

/// The footer line and the notification body share this wording.
public enum BatchSummaryText {
    public static func running(current: Int, total: Int) -> String {
        "Converting \(current) of \(total)"
    }

    /// `3 done, 1 failed, 1 skipped in 2m 14s`. Zero counts are left out.
    public static func finished(_ outcome: BatchOutcome, elapsed: TimeInterval) -> String {
        var parts: [String] = []
        if outcome.done > 0 { parts.append("\(outcome.done) done") }
        if outcome.failed > 0 { parts.append("\(outcome.failed) failed") }
        if outcome.skipped > 0 { parts.append("\(outcome.skipped) skipped") }
        if outcome.cancelled > 0 { parts.append("\(outcome.cancelled) cancelled") }
        if parts.isEmpty { parts.append("0 done") }
        return parts.joined(separator: ", ") + " in " + duration(elapsed)
    }

    public static func duration(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed.rounded()))
        let minutes = total / 60
        let seconds = total % 60
        if minutes == 0 { return "\(seconds)s" }
        return "\(minutes)m \(String(format: "%02d", seconds))s"
    }
}

/// One piece of a multi-track rollup. A failure is words, so it is not color alone.
public struct RollupPiece: Equatable, Sendable {
    public var text: String
    public var isFailure: Bool

    public init(text: String, isFailure: Bool) {
        self.text = text
        self.isFailure = isFailure
    }
}

public enum TrackRollupText {
    public static func pieces(for statuses: [ConversionStatus]) -> [RollupPiece] {
        let total = statuses.count
        let head = total == 1 ? "1 track" : "\(total) tracks"
        var counts: [(String, Int, Bool)] = []
        func add(_ title: String, _ count: Int, failure: Bool = false) {
            if count > 0 { counts.append((title, count, failure)) }
        }
        add("done", statuses.filter(isDone).count)
        add("failed", statuses.filter { if case .failed = $0 { return true }; return false }.count, failure: true)
        add("converting", statuses.filter { if case .converting = $0 { return true }; return false }.count)
        add("extracting", statuses.filter { if case .extracting = $0 { return true }; return false }.count)
        add("waiting", statuses.filter { if case .waiting = $0 { return true }; return false }.count)
        add("ready to review", statuses.filter { if case .awaitingReview = $0 { return true }; return false }.count)
        add("skipped", statuses.filter { if case .skipped = $0 { return true }; return false }.count)
        add("cancelled", statuses.filter { if case .cancelled = $0 { return true }; return false }.count)
        var pieces = [RollupPiece(text: head, isFailure: false)]
        if counts.isEmpty { return pieces }
        pieces.append(RollupPiece(text: " · ", isFailure: false))
        for (index, count) in counts.enumerated() {
            if index > 0 {
                pieces.append(RollupPiece(text: ", ", isFailure: false))
            }
            let noun = count.1 == 1 ? count.0 : count.0
            pieces.append(RollupPiece(text: "\(count.1) \(noun)", isFailure: count.2))
        }
        return pieces
    }

    private static func isDone(_ status: ConversionStatus) -> Bool {
        if case .done = status { return true }
        return false
    }
}

/// Status line for one selected track.
public enum TrackStatusText {
    public static func line(_ status: ConversionStatus) -> String {
        switch status {
        case .waiting:
            return "Waiting"
        case .extracting:
            return "Extracting…"
        case let .converting(completed, total):
            guard total > 0 else { return "Converting" }
            let percent = Int((Double(completed) / Double(total) * 100).rounded())
            return "Converting · \(percent)%"
        case let .done(cues, unrecognized, path):
            let name = (path as NSString).lastPathComponent
            var text = "Done · \(cueLabel(cues)) · \(name)"
            if unrecognized > 0 {
                let failed = unrecognized == 1 ? "1 [OCR failed]" : "\(unrecognized) [OCR failed]"
                text = "Done · \(cueLabel(cues)) · \(failed) · \(name)"
            }
            return text
        case .awaitingReview:
            return "Ready to review · not saved yet"
        case let .failed(message):
            return "Failed · \(message)"
        case .cancelled:
            return "Cancelled"
        case let .skipped(message):
            return message
        }
    }

    private static func cueLabel(_ cues: Int) -> String {
        cues == 1 ? "1 cue" : "\(cues) cues"
    }
}
