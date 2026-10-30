import Foundation

/// When the window writes the `.srt`.
///
/// `.immediately` is today's behavior. `.afterReview` keeps the cues in the
/// queue until the person saves them from the review window.
public enum SaveTiming: String, Equatable, Sendable {
    case immediately
    case afterReview
}

/// A cue the review window can edit.
///
/// `text` is what the field shows. An OCR failure leaves it empty. The
/// "[OCR failed…]" placeholder is only written into the `.srt` while the field
/// is still empty, and it is never placed in the field.
///
/// `lowConfidencePercent` and `alternatives` are reserved for issue #19.
/// Nothing in this version sets them. `failureMessage` stays on the cue so a
/// later Retry OCR (issue #27) can replace it without a new model.
public struct ReviewCue: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var startPTS: UInt32
    public var endPTS: UInt32
    public var text: String
    /// Set when recognition failed. Cleared from the list once `text` is non-empty.
    public var failureMessage: String?
    /// 0...1 when the recognizer reported a confidence. Not turned into a flag here.
    public var confidence: Double?
    /// 1...100 when issue #19 flags the cue. Nil in this version.
    public var lowConfidencePercent: Int?
    /// Other OCR readings. Empty until issue #19.
    public var alternatives: [String]
    /// Picture file kept for this session. Nil when no picture was stored.
    public var pictureID: UUID?
    public var isEdited: Bool
    /// True when this cue was produced by merging a word-by-word reveal.
    public var mergedFromWordByWord: Bool

    public init(
        id: UUID = UUID(),
        startPTS: UInt32,
        endPTS: UInt32,
        text: String,
        failureMessage: String? = nil,
        confidence: Double? = nil,
        lowConfidencePercent: Int? = nil,
        alternatives: [String] = [],
        pictureID: UUID? = nil,
        isEdited: Bool = false,
        mergedFromWordByWord: Bool = false
    ) {
        self.id = id
        self.startPTS = startPTS
        self.endPTS = endPTS
        self.text = text
        self.failureMessage = failureMessage
        self.confidence = confidence
        self.lowConfidencePercent = lowConfidencePercent
        self.alternatives = alternatives
        self.pictureID = pictureID
        self.isEdited = isEdited
        self.mergedFromWordByWord = mergedFromWordByWord
    }

    public var showsOCRFailure: Bool {
        guard let failureMessage, !failureMessage.isEmpty else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var showsLowConfidence: Bool {
        guard !showsOCRFailure, let lowConfidencePercent, (1...100).contains(lowConfidencePercent) else {
            return false
        }
        return true
    }

    /// Words next to the flag icon. Never color alone.
    public var listPrimaryText: String {
        if showsOCRFailure {
            return "OCR failed · \(failureMessage ?? "no text recognized")"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Empty cue" : text
    }

    /// Text written to the `.srt`. Failures that are still empty keep the placeholder.
    public var srtBody: String {
        if showsOCRFailure, let failureMessage {
            return CueRecognitionFailure.placeholder(for: failureMessage)
        }
        return text
    }

    public var durationPTS: UInt32 {
        endPTS >= startPTS ? endPTS - startPTS : 0
    }
}

/// One captured cue, before pictures are spilled to a temp folder.
public struct CapturedReviewCue: Equatable, Sendable {
    public var startPTS: UInt32
    public var endPTS: UInt32
    /// Recognized text. Empty when recognition failed. Never the placeholder.
    public var text: String
    public var failureMessage: String?
    public var confidence: Double?
    public var alternatives: [String]
    public var image: SubtitleImage?

    public init(
        startPTS: UInt32,
        endPTS: UInt32,
        text: String,
        failureMessage: String?,
        confidence: Double?,
        alternatives: [String] = [],
        image: SubtitleImage? = nil
    ) {
        self.startPTS = startPTS
        self.endPTS = endPTS
        self.text = text
        self.failureMessage = failureMessage
        self.confidence = confidence
        self.alternatives = alternatives
        self.image = image
    }
}

extension CueRecognitionFailure {
    /// Pulls the message back out of an `[OCR failed: …]` placeholder.
    /// Returns nil when `text` is ordinary subtitle text.
    public static func message(inPlaceholder text: String) -> String? {
        let prefix = "[OCR failed: "
        guard text.hasPrefix(prefix), text.hasSuffix("]"), text.count > prefix.count + 1 else { return nil }
        let body = text.dropFirst(prefix.count).dropLast()
        guard !body.isEmpty else { return nil }
        return String(body)
    }
}

public enum CueEditError: Error, Equatable, Sendable {
    case endBeforeStart
    case missingCue
}

/// Consecutive cues whose text grows one word at a time.
public struct WordByWordGroup: Equatable, Sendable, Identifiable {
    public var cueIDs: [UUID]

    public var id: UUID { cueIDs[0] }

    public init(cueIDs: [UUID]) {
        self.cueIDs = cueIDs
    }
}

/// Finds word-by-word reveals. A group is never merged on its own.
public enum WordByWordDetection {
    /// One second, on the 90 kHz clock. A longer gap starts a new group.
    public static let maximumGapPTS: UInt32 = 90_000

    public static func groups(in cues: [ReviewCue]) -> [WordByWordGroup] {
        var groups: [WordByWordGroup] = []
        var run: [UUID] = []
        func close() {
            if run.count >= 2 {
                groups.append(WordByWordGroup(cueIDs: run))
            }
            run.removeAll(keepingCapacity: true)
        }
        for (index, cue) in cues.enumerated() {
            if run.isEmpty {
                if canStart(cue) { run = [cue.id] }
                continue
            }
            let previous = cues[index - 1]
            if extends(previous, cue) {
                run.append(cue.id)
            } else {
                close()
                if canStart(cue) { run = [cue.id] }
            }
        }
        close()
        return groups
    }

    /// True when `next` is `previous` plus whitespace and more text.
    public static func textExtends(_ previous: String, _ next: String) -> Bool {
        let previous = normalize(previous)
        let next = normalize(next)
        guard previous.count >= 1, next.count > previous.count, next.hasPrefix(previous) else { return false }
        let boundary = next[next.index(next.startIndex, offsetBy: previous.count)]
        return boundary.isWhitespace
    }

    private static func canStart(_ cue: ReviewCue) -> Bool {
        !cue.showsOCRFailure && !normalize(cue.text).isEmpty
    }

    private static func extends(_ previous: ReviewCue, _ next: ReviewCue) -> Bool {
        guard canStart(previous), canStart(next) else { return false }
        guard next.startPTS >= previous.startPTS else { return false }
        let gap = Int64(next.startPTS) - Int64(previous.endPTS)
        guard gap <= Int64(maximumGapPTS) else { return false }
        return textExtends(previous.text, next.text)
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The cues for one file, with undo.
///
/// Typing in one cue is a single undo until a different cue or a different
/// kind of edit starts. Merge, delete, and retiming are each their own undo.
/// Pictures are not stored here, so undo does not copy bitmaps.
public struct CueDocument: Equatable, Sendable {
    public private(set) var cues: [ReviewCue]

    private struct Origin: Equatable, Sendable {
        var text: String
        var startPTS: UInt32
        var endPTS: UInt32
    }

    private struct Snapshot: Equatable, Sendable {
        var cues: [ReviewCue]
    }

    private var origins: [UUID: Origin]
    private var originCues: [ReviewCue]
    private var savedCues: [ReviewCue]?
    private var undoStack: [Snapshot]
    private var redoStack: [Snapshot]
    /// Cue whose keystrokes share the undo entry that is currently open.
    private var coalesceID: UUID?

    public static let undoLimit = 100

    public static let empty = CueDocument.recognized([])

    private init(cues: [ReviewCue], origins: [UUID: Origin], originCues: [ReviewCue]) {
        self.cues = cues
        self.origins = origins
        self.originCues = originCues
        self.savedCues = nil
        self.undoStack = []
        self.redoStack = []
        self.coalesceID = nil
    }

    /// A document as recognized. Nothing is edited, and nothing has been saved.
    public static func recognized(_ cues: [ReviewCue]) -> CueDocument {
        let origins = Dictionary(uniqueKeysWithValues: cues.map { cue in
            (cue.id, Origin(text: cue.text, startPTS: cue.startPTS, endPTS: cue.endPTS))
        })
        return CueDocument(cues: cues, origins: origins, originCues: cues)
    }

    /// Builds a document from a transcription. Captured cues win. Otherwise the
    /// placeholder is stripped so it cannot land in the editable field.
    public static func fromTranscription(_ result: TranscriptionResult) -> CueDocument {
        if !result.captured.isEmpty {
            let cues = result.captured.map { item in
                ReviewCue(
                    startPTS: item.startPTS,
                    endPTS: item.endPTS,
                    text: item.text,
                    failureMessage: item.failureMessage,
                    confidence: item.confidence,
                    alternatives: item.alternatives
                )
            }
            return recognized(cues)
        }
        let cues = result.cues.enumerated().map { index, cue in
            let failure = result.failures.first { $0.cueIndex == index }
            let parsed = CueRecognitionFailure.message(inPlaceholder: cue.text)
            let message = failure?.message ?? parsed
            let isPlaceholder: Bool
            if let message {
                isPlaceholder = cue.text.isEmpty || cue.text == CueRecognitionFailure.placeholder(for: message)
            } else {
                isPlaceholder = false
            }
            return ReviewCue(
                startPTS: cue.startPTS,
                endPTS: cue.endPTS,
                text: isPlaceholder ? "" : cue.text,
                failureMessage: isPlaceholder ? message : nil
            )
        }
        return recognized(cues)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// True when the cues differ from the last save, or from the recognized
    /// original when nothing has been saved yet.
    public var hasUnsavedEdits: Bool {
        cues != (savedCues ?? originCues)
    }

    /// True when Save would write something that is not already the file on disk.
    /// A file that was held and never saved still needs writing, even with no edits.
    public var needsWriting: Bool {
        guard let savedCues else { return true }
        return cues != savedCues
    }

    public var editedCount: Int { cues.reduce(0) { $0 + ($1.isEdited ? 1 : 0) } }
    public var ocrFailedCount: Int { cues.reduce(0) { $0 + ($1.showsOCRFailure ? 1 : 0) } }
    public var lowConfidenceCount: Int { cues.reduce(0) { $0 + ($1.showsLowConfidence ? 1 : 0) } }

    public var problemCues: [ReviewCue] {
        cues.filter { $0.showsOCRFailure || $0.showsLowConfidence }
    }

    public func wordByWordGroups() -> [WordByWordGroup] {
        WordByWordDetection.groups(in: cues)
    }

    public func group(containing id: UUID) -> WordByWordGroup? {
        wordByWordGroups().first { $0.cueIDs.contains(id) }
    }

    public func cueNumber(of id: UUID) -> Int? {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return nil }
        return index + 1
    }

    public func neighbors(of id: UUID) -> (previous: ReviewCue?, current: ReviewCue?, next: ReviewCue?) {
        guard let index = cues.firstIndex(where: { $0.id == id }) else {
            return (nil, nil, nil)
        }
        let previous = index > 0 ? cues[index - 1] : nil
        let next = index + 1 < cues.count ? cues[index + 1] : nil
        return (previous, cues[index], next)
    }

    public func srtCues() -> [SRTCue] {
        cues.map { SRTCue(startPTS: $0.startPTS, endPTS: $0.endPTS, text: $0.srtBody) }
    }

    public func srtText(lineEnding: SRTLineEnding = .crlf) throws -> String {
        try SRTWriter(lineEnding: lineEnding).write(srtCues())
    }

    public mutating func noteSaved() {
        noteSaved(cues)
    }

    /// Records `snapshot` as the cues now on disk. Later edits stay in `cues`.
    public mutating func noteSaved(_ snapshot: [ReviewCue]) {
        savedCues = snapshot
        coalesceID = nil
    }

    /// Drops edits that were not saved. A file that was never saved returns to
    /// the recognized cues. Undo history for those edits is discarded with them.
    public mutating func discardUnsavedEdits() {
        cues = savedCues ?? originCues
        undoStack.removeAll()
        redoStack.removeAll()
        coalesceID = nil
    }

    public mutating func setText(id: UUID, text: String) {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        guard cues[index].text != text else { return }
        if coalesceID != id {
            pushUndo()
            coalesceID = id
        }
        cues[index].text = text
        refreshEdited(at: index)
        redoStack.removeAll()
    }

    /// Ends the open typing undo so the next keystroke in the same cue is a new edit.
    /// Returns false when there was nothing to end, so the caller can skip a write.
    @discardableResult
    public mutating func endTextCoalescing() -> Bool {
        guard coalesceID != nil else { return false }
        coalesceID = nil
        return true
    }

    /// Escape. Restores the cue text from before this typing burst and does not
    /// leave that burst on the redo stack.
    public mutating func revertCoalescedText() {
        guard coalesceID != nil, let snapshot = undoStack.popLast() else { return }
        cues = snapshot.cues
        coalesceID = nil
    }

    public mutating func setTiming(id: UUID, startPTS: UInt32, endPTS: UInt32) throws {
        guard endPTS >= startPTS else { throw CueEditError.endBeforeStart }
        guard let index = cues.firstIndex(where: { $0.id == id }) else { throw CueEditError.missingCue }
        guard cues[index].startPTS != startPTS || cues[index].endPTS != endPTS else { return }
        beginSeparateEdit()
        cues[index].startPTS = startPTS
        cues[index].endPTS = endPTS
        refreshEdited(at: index)
    }

    @discardableResult
    public mutating func delete(ids: Set<UUID>) -> Bool {
        let remaining = cues.filter { !ids.contains($0.id) }
        guard remaining.count != cues.count else { return false }
        beginSeparateEdit()
        cues = remaining
        return true
    }

    /// True when `ids` are two or more cues that sit next to each other.
    public func canMerge(ids: [UUID]) -> Bool {
        makeMergedCue(from: ids) != nil
    }

    /// Merges a contiguous selection. A word-by-word group keeps the last cue's
    /// text and runs from the first start to the last end. Any other selection
    /// joins the non-empty lines so dialogue is not dropped.
    @discardableResult
    public mutating func merge(ids: [UUID]) -> UUID? {
        guard let merged = makeMergedCue(from: ids) else { return nil }
        beginSeparateEdit()
        replace(ids: ids, with: merged)
        return merged.id
    }

    /// Merges every current word-by-word group. One undo puts them all back.
    @discardableResult
    public mutating func mergeAllWordByWordGroups() -> Int {
        let groups = wordByWordGroups()
        guard !groups.isEmpty else { return 0 }
        beginSeparateEdit()
        var mergedCount = 0
        for group in groups.reversed() {
            guard let merged = makeMergedCue(from: group.cueIDs) else { continue }
            replace(ids: group.cueIDs, with: merged)
            mergedCount += 1
        }
        return mergedCount
    }

    public mutating func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        pushRedo()
        cues = snapshot.cues
        coalesceID = nil
    }

    public mutating func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(cues: cues))
        Self.trim(&undoStack)
        cues = snapshot.cues
        coalesceID = nil
    }

    private mutating func beginSeparateEdit() {
        coalesceID = nil
        pushUndo()
        redoStack.removeAll()
    }

    private mutating func pushUndo() {
        undoStack.append(Snapshot(cues: cues))
        Self.trim(&undoStack)
    }

    private mutating func pushRedo() {
        redoStack.append(Snapshot(cues: cues))
        Self.trim(&redoStack)
    }

    private static func trim(_ stack: inout [Snapshot]) {
        if stack.count > Self.undoLimit {
            stack.removeFirst(stack.count - Self.undoLimit)
        }
    }

    private mutating func refreshEdited(at index: Int) {
        let cue = cues[index]
        guard let origin = origins[cue.id] else {
            cues[index].isEdited = true
            return
        }
        cues[index].isEdited = cue.text != origin.text
            || cue.startPTS != origin.startPTS
            || cue.endPTS != origin.endPTS
    }

    private func ordered(_ ids: [UUID]) -> [ReviewCue]? {
        let wanted = Set(ids)
        guard wanted.count >= 2, wanted.count == ids.count else { return nil }
        let chosen = cues.filter { wanted.contains($0.id) }
        guard chosen.count == wanted.count else { return nil }
        guard let first = cues.firstIndex(where: { $0.id == chosen[0].id }) else { return nil }
        let slice = cues[first..<(first + chosen.count)]
        guard slice.map(\.id) == chosen.map(\.id) else { return nil }
        return chosen
    }

    private func makeMergedCue(from ids: [UUID]) -> ReviewCue? {
        guard let chosen = ordered(ids), let last = chosen.last else { return nil }
        let groups = WordByWordDetection.groups(in: chosen)
        let reveal = groups.count == 1 && groups[0].cueIDs == chosen.map(\.id)
        let text: String
        let failure: String?
        if reveal {
            text = last.text
            failure = last.showsOCRFailure ? last.failureMessage : nil
        } else {
            let lines = chosen.map(\.text).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            text = lines.joined(separator: "\n")
            failure = text.isEmpty ? last.failureMessage : nil
        }
        return ReviewCue(
            startPTS: chosen[0].startPTS,
            endPTS: last.endPTS,
            text: text,
            failureMessage: failure,
            confidence: last.confidence,
            lowConfidencePercent: reveal ? last.lowConfidencePercent : nil,
            alternatives: reveal ? last.alternatives : [],
            pictureID: last.pictureID,
            isEdited: true,
            mergedFromWordByWord: reveal
        )
    }

    private mutating func replace(ids: [UUID], with merged: ReviewCue) {
        guard let chosen = ordered(ids), let first = cues.firstIndex(where: { $0.id == chosen[0].id }) else { return }
        cues.replaceSubrange(first..<(first + chosen.count), with: [merged])
    }
}

/// The count drawn on a queue row. Failed-only rows say "failed". A row that
/// also has a low-confidence cue says "to check", which is how issue #19 will
/// light up without a new row layout.
public enum ReviewProblemBadge: Equatable, Sendable {
    case failed(Int)
    case toCheck(Int)

    public static func make(ocrFailed: Int, lowConfidence: Int) -> ReviewProblemBadge? {
        let problems = ocrFailed + lowConfidence
        guard problems > 0, ocrFailed >= 0, lowConfidence >= 0 else { return nil }
        if lowConfidence > 0 { return .toCheck(problems) }
        return .failed(ocrFailed)
    }

    public var label: String {
        switch self {
        case let .failed(count):
            return count == 1 ? "1 failed" : "\(count) failed"
        case let .toCheck(count):
            return count == 1 ? "1 to check" : "\(count) to check"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case let .failed(count):
            return count == 1 ? "1 OCR failed" : "\(count) OCR failed"
        case let .toCheck(count):
            return count == 1 ? "1 cue to check" : "\(count) cues to check"
        }
    }
}

/// Which files Next File visits, in queue order.
public struct ReviewQueueEntry: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var needsReview: Bool

    public init(id: UUID, needsReview: Bool) {
        self.id = id
        self.needsReview = needsReview
    }
}

public enum ReviewBatchOrder {
    /// A file needs review when it still has a problem, or the `.srt` is not the saved text.
    public static func needsReview(problemCount: Int, needsWriting: Bool) -> Bool {
        problemCount > 0 || needsWriting
    }

    public static func position(of id: UUID, in entries: [ReviewQueueEntry]) -> (index: Int, total: Int)? {
        let ids = entries.filter(\.needsReview).map(\.id)
        guard let offset = ids.firstIndex(of: id) else { return nil }
        return (offset + 1, ids.count)
    }

    /// The next file that needs review, after `id`, wrapping once. Nil when
    /// there is not another one.
    public static func nextReviewFile(after id: UUID, in entries: [ReviewQueueEntry]) -> UUID? {
        let ids = entries.filter(\.needsReview).map(\.id)
        guard !ids.isEmpty else { return nil }
        guard let offset = ids.firstIndex(of: id) else { return ids[0] }
        let next = ids.index(after: offset)
        if next < ids.endIndex { return ids[next] }
        return ids.count > 1 ? ids[0] : nil
    }
}

/// Whether Save must ask before replacing a file.
///
/// The queue already asked about the planned path, so the first save there
/// does not ask again. Saving again over the file this review wrote does not
/// ask. A different path that already exists does.
public enum ReviewWritePlan: Equatable, Sendable {
    case write
    case confirmReplace
}

public enum ReviewWritePlanner {
    public static func plan(
        path: String,
        plannedPath: String,
        savedPath: String?,
        fileExists: (String) -> Bool
    ) -> ReviewWritePlan {
        if let savedPath, path == savedPath { return .write }
        if savedPath == nil, path == plannedPath { return .write }
        if fileExists(path) { return .confirmReplace }
        return .write
    }
}

/// Parses and steps cue times. Display goes through `SRTWriter.timestamp`.
public enum CueClock {
    /// 100 milliseconds, in 90 kHz ticks.
    public static let stepPTS: UInt32 = 9_000

    public static func parse(_ text: String) -> UInt32? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(of: ".", with: ",")
        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let hours = UInt64(parts[0]), let minutes = UInt64(parts[1]) else { return nil }
        let secondsPart = parts[2].split(separator: ",", omittingEmptySubsequences: false)
        guard secondsPart.count == 2, let seconds = UInt64(secondsPart[0]), let millis = UInt64(secondsPart[1]) else {
            return nil
        }
        guard hours < 1_000, minutes < 60, seconds < 60, millis < 1_000 else { return nil }
        let totalMillis = hours * 3_600_000 + minutes * 60_000 + seconds * 1_000 + millis
        let pts = totalMillis * 90
        guard pts <= UInt64(UInt32.max) else { return nil }
        return UInt32(pts)
    }

    public static func nudging(_ pts: UInt32, bySteps steps: Int) -> UInt32 {
        let next = Int64(pts) + Int64(steps) * Int64(stepPTS)
        if next <= 0 { return 0 }
        if next >= Int64(UInt32.max) { return UInt32.max }
        return UInt32(next)
    }

    public static func end(start: UInt32, duration: UInt32) -> UInt32 {
        let sum = UInt64(start) + UInt64(duration)
        if sum >= UInt64(UInt32.max) { return UInt32.max }
        return UInt32(sum)
    }
}
