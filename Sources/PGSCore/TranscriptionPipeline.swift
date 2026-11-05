import Foundation

/// How far a batch conversion has got. `completed` counts every finished cue,
/// including ones that produced no text. Calls arrive one at a time, in the
/// order cues finish, which is not always cue order when several run at once.
public struct TranscriptionProgress: Equatable, Sendable {
    public var completed: Int
    public var total: Int
    public var cueIndex: Int

    public init(completed: Int, total: Int, cueIndex: Int) {
        self.completed = completed
        self.total = total
        self.cueIndex = cueIndex
    }
}

/// A cue whose picture produced no usable text, or whose recognizer failed.
/// The cue is still written into the SRT file, with `placeholder` as its text,
/// so a missed line is visible instead of disappearing.
public struct CueRecognitionFailure: Equatable, Sendable, CustomStringConvertible {
    /// Zero-based index in the decoded cue list.
    public var cueIndex: Int
    public var startPTS: UInt32
    public var endPTS: UInt32
    public var message: String

    public init(cueIndex: Int, startPTS: UInt32, endPTS: UInt32, message: String) {
        self.cueIndex = cueIndex
        self.startPTS = startPTS
        self.endPTS = endPTS
        self.message = message
    }

    public var description: String {
        "Cue \(cueIndex + 1) at \(SRTWriter.timestamp(pts: startPTS)): \(message)"
    }

    public var placeholder: String {
        Self.placeholder(for: message)
    }

    public static func placeholder(for message: String) -> String {
        "[OCR failed: \(message)]"
    }
}

/// The SRT cues, the same text as a file, and any pictures that could not be read.
public struct TranscriptionResult: Equatable, Sendable {
    public var cues: [SRTCue]
    public var failures: [CueRecognitionFailure]
    public var srt: String
    /// One entry per cue. Text is empty when recognition failed, never the placeholder.
    /// `image` is set only when the pipeline was asked to keep pictures.
    public var captured: [CapturedReviewCue]

    public init(
        cues: [SRTCue],
        failures: [CueRecognitionFailure],
        srt: String,
        captured: [CapturedReviewCue] = []
    ) {
        self.cues = cues
        self.failures = failures
        self.srt = srt
        self.captured = captured
    }
}

/// Decoded subtitle pictures go in, SRT cues come out.
///
/// Several cues run at once, up to `maxConcurrent`. Progress is reported as
/// each one finishes. Cancelling the task stops the batch and throws
/// `CancellationError` instead of returning a partial file. A picture that
/// comes back empty, or a recognizer error on one cue, does not drop that cue
/// and does not stop the others.
public struct TranscriptionPipeline: Sendable {
    public var languages: [String]
    public var maxConcurrent: Int
    public var cleaner: OCRTextCleaner
    public var lineEnding: SRTLineEnding
    /// When true, a line the image preparer marked as leaning is wrapped in `<i>`.
    /// Off by default. The lean check is experimental and often wrong for upright type.
    public var italics: Bool
    /// When true, each captured cue keeps its bitmap so the review window can show it.
    /// The command-line tool leaves this off.
    public var keepPictures: Bool

    public static let noTextMessage = "no text recognized"

    public init(
        languages: [String] = ["en-US"],
        maxConcurrent: Int = 4,
        lineEnding: SRTLineEnding = .crlf,
        italics: Bool = false,
        keepPictures: Bool = false,
        cleaner: OCRTextCleaner? = nil
    ) {
        self.languages = languages
        self.maxConcurrent = max(1, maxConcurrent)
        self.lineEnding = lineEnding
        self.italics = italics
        self.keepPictures = keepPictures
        self.cleaner = cleaner ?? OCRTextCleaner(fixEnglishPronounI: OCRTextCleaner.usesEnglish(languages))
    }

    /// Decode a .sup file, recognize every cue, and assemble the SRT text.
    /// A cancelled task stops during decoding, before any cue is recognized.
    public func transcribeFile(
        data: Data,
        decoder: PGSDecoder = PGSDecoder(),
        recognizer: any SubtitleRecognizing,
        progress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        let started = Date()
        DebugLog.shared.record(.decode, "Decode started, \(data.count) bytes")
        let cues: [SubtitleCue]
        do {
            cues = try decoder.decode(data)
        } catch {
            let duration = DebugLogFormatting.duration(since: started)
            if error is CancellationError {
                DebugLog.shared.record(.decode, "Decode cancelled, \(duration)")
            } else {
                DebugLog.shared.record(.error, "Decode failed, \(duration): \(error)", isError: true)
            }
            throw error
        }
        DebugLog.shared.record(
            .decode,
            "Decode finished, \(cues.count) cues, \(DebugLogFormatting.duration(since: started))"
        )
        return try await transcribe(cues: cues, recognizer: recognizer, progress: progress)
    }

    /// Recognize cues that are already decoded.
    public func transcribe(
        cues: [SubtitleCue],
        recognizer: any SubtitleRecognizing,
        progress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        let started = Date()
        let languageList = languages.isEmpty ? "default" : languages.joined(separator: ", ")
        // Counts and recognizer errors only. The recognized subtitle text is not logged.
        DebugLog.shared.record(.ocr, "OCR started, \(cues.count) cues, languages \(languageList)")
        let total = cues.count
        if total == 0 {
            DebugLog.shared.record(
                .ocr,
                "OCR finished, 0 cues, 0 failed, \(DebugLogFormatting.duration(since: started))"
            )
            return TranscriptionResult(cues: [], failures: [], srt: try SRTWriter(lineEnding: lineEnding).write([]), captured: [])
        }

        let outcomes: [CueOutcome?]
        do {
            outcomes = try await recognizeAll(cues: cues, recognizer: recognizer, progress: progress)
        } catch {
            let duration = DebugLogFormatting.duration(since: started)
            if error is CancellationError {
                DebugLog.shared.record(.ocr, "OCR cancelled, \(duration)")
            } else {
                DebugLog.shared.record(.error, "OCR failed, \(duration): \(error)", isError: true)
            }
            throw error
        }

        var srtCues: [SRTCue] = []
        var failures: [CueRecognitionFailure] = []
        var captured: [CapturedReviewCue] = []
        srtCues.reserveCapacity(total)
        captured.reserveCapacity(total)
        for outcome in outcomes {
            guard let outcome else { continue }
            srtCues.append(outcome.cue)
            captured.append(outcome.captured)
            if let failure = outcome.failure {
                failures.append(failure)
            }
        }
        let srt = try SRTWriter(lineEnding: lineEnding).write(srtCues)
        let reasons = Array(Set(failures.map(\.message))).sorted().joined(separator: "; ")
        let reasonText = reasons.isEmpty ? "" : " (\(reasons))"
        DebugLog.shared.record(
            .ocr,
            "OCR finished, \(total) cues, \(failures.count) failed\(reasonText), \(DebugLogFormatting.duration(since: started))"
        )
        return TranscriptionResult(cues: srtCues, failures: failures, srt: srt, captured: captured)
    }

    private func recognizeAll(
        cues: [SubtitleCue],
        recognizer: any SubtitleRecognizing,
        progress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> [CueOutcome?] {
        let total = cues.count
        let limit = maxConcurrent
        var outcomes = [CueOutcome?](repeating: nil, count: total)
        try await withThrowingTaskGroup(of: (Int, CueOutcome).self) { group in
            var nextIndex = 0
            var running = 0
            func scheduleNext() {
                while running < limit && nextIndex < total {
                    let index = nextIndex
                    nextIndex += 1
                    running += 1
                    group.addTask {
                        let outcome = try await self.recognize(cues[index], index: index, recognizer: recognizer)
                        return (index, outcome)
                    }
                }
            }
            scheduleNext()
            var completed = 0
            while let (index, outcome) = try await group.next() {
                running -= 1
                outcomes[index] = outcome
                completed += 1
                progress?(TranscriptionProgress(completed: completed, total: total, cueIndex: index))
                scheduleNext()
            }
        }
        return outcomes
    }

    private struct CueOutcome: Sendable {
        var cue: SRTCue
        var failure: CueRecognitionFailure?
        var captured: CapturedReviewCue
    }

    private func recognize(
        _ cue: SubtitleCue,
        index: Int,
        recognizer: any SubtitleRecognizing
    ) async throws -> CueOutcome {
        try Task.checkCancellation()
        do {
            let recognized = try await recognizer.recognize(image: cue.image, languages: languages)
            let text = assemble(recognized)
            if text.isEmpty {
                let failure = CueRecognitionFailure(
                    cueIndex: index,
                    startPTS: cue.startPTS,
                    endPTS: cue.endPTS,
                    message: Self.noTextMessage
                )
                return CueOutcome(
                    cue: SRTCue(startPTS: cue.startPTS, endPTS: cue.endPTS, text: failure.placeholder),
                    failure: failure,
                    captured: capturedCue(cue, text: "", failure: failure.message, confidence: recognized.confidence)
                )
            }
            return CueOutcome(
                cue: SRTCue(startPTS: cue.startPTS, endPTS: cue.endPTS, text: text),
                failure: nil,
                captured: capturedCue(cue, text: text, failure: nil, confidence: recognized.confidence)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let message = Self.flatten((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            let failure = CueRecognitionFailure(
                cueIndex: index,
                startPTS: cue.startPTS,
                endPTS: cue.endPTS,
                message: message
            )
            return CueOutcome(
                cue: SRTCue(startPTS: cue.startPTS, endPTS: cue.endPTS, text: failure.placeholder),
                failure: failure,
                captured: capturedCue(cue, text: "", failure: failure.message, confidence: nil)
            )
        }
    }

    /// The editable cue. The placeholder stays on the SRT cue only.
    private func capturedCue(
        _ cue: SubtitleCue,
        text: String,
        failure: String?,
        confidence: Double?
    ) -> CapturedReviewCue {
        CapturedReviewCue(
            startPTS: cue.startPTS,
            endPTS: cue.endPTS,
            text: text,
            failureMessage: failure,
            confidence: confidence,
            alternatives: [],
            image: keepPictures ? cue.image : nil
        )
    }

    /// Lines with positions win over the flat `text` string. When `italics` is
    /// on, italic pieces on the same row are joined before cleanup, then wrapped
    /// in `<i>`. Otherwise the lean flag is ignored and no italic tags are written.
    private func assemble(_ result: OCRResult) -> String {
        let lines = result.lines.isEmpty ? fallbackLines(result.text) : result.lines
        let rendered = ReadingOrder.rows(from: lines).compactMap { row -> String? in
            let text = render(row)
            return text.isEmpty ? nil : text
        }
        return rendered.joined(separator: "\n")
    }

    private func render(_ row: [RecognizedLine]) -> String {
        var chunks: [(italic: Bool, text: String)] = []
        for item in row {
            let raw = item.text
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            let italic = italics && item.isItalic
            if let last = chunks.indices.last, chunks[last].italic == italic {
                chunks[last].text += " " + raw
            } else {
                chunks.append((italic, raw))
            }
        }
        var pieces: [String] = []
        for chunk in chunks {
            let cleaned = cleaner.cleanLine(chunk.text)
            guard !cleaned.isEmpty else { continue }
            pieces.append(chunk.italic ? "<i>\(cleaned)</i>" : cleaned)
        }
        return pieces.joined(separator: " ")
    }

    private func fallbackLines(_ text: String) -> [RecognizedLine] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let parts = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        return parts.enumerated().map { index, part in
            RecognizedLine(text: String(part), confidence: nil, isItalic: false, top: index, left: 0, height: 1)
        }
    }

    private static func flatten(_ message: String) -> String {
        let collapsed = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if collapsed.isEmpty { return "recognition failed" }
        if collapsed.count > 180 {
            return String(collapsed.prefix(180)) + "…"
        }
        return collapsed
    }
}
