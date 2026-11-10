import Foundation

/// Opt-in trace for menu flicker (#35) and review publishing warnings (#30).
///
/// The app turns this on with an environment variable or a defaults flag.
/// These types only format and coalesce lines. They do not publish view state,
/// change command availability, or record subtitle text.
public enum DiagnosticSwitch {
    /// `1`, `yes`, `true`, and `on` enable. `0`, `no`, `false`, and `off` disable.
    /// An absent or blank value leaves the choice to `defaultsFlag`. Any other
    /// word also leaves the choice to `defaultsFlag`, so a typo does not enable tracing.
    public static func isOn(environmentValue: String?, defaultsFlag: Bool) -> Bool {
        if let token = normalized(environmentValue) {
            switch token {
            case "1", "yes", "true", "on":
                return true
            case "0", "no", "false", "off":
                return false
            default:
                break
            }
        }
        return defaultsFlag
    }

    /// Stable queue actions are the default. `0`, `no`, `false`, and `off` restore
    /// the old per-cue rebuilds. An absent, blank, `1`, or any other word stays on,
    /// so a typo does not turn the fix off.
    public static func stableCommandsEnabled(environmentValue: String?) -> Bool {
        guard let token = normalized(environmentValue) else { return true }
        switch token {
        case "0", "no", "false", "off":
            return false
        default:
            return true
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return token.isEmpty ? nil : token
    }
}

/// Review, Cancel All, and Clear Finished availability. Cue progress is not an input.
public struct QueueActionInputs: Equatable, Sendable {
    public var canReview: Bool
    public var canCancel: Bool
    public var canClear: Bool

    public init(canReview: Bool, canCancel: Bool, canClear: Bool) {
        self.canReview = canReview
        self.canCancel = canCancel
        self.canClear = canClear
    }
}

/// Whether the focused queue actions should be replaced.
/// Equal availability keeps the previous value.
public enum StableCommandFocus {
    public static func shouldApply(previous: QueueActionInputs?, next: QueueActionInputs) -> Bool {
        previous != next
    }
}

public enum DiagnosticEditPhase: String, Equatable, Sendable {
    case none
    case text
    case time
    case textAndTime = "text+time"

    public static func combine(text: Bool, time: Bool) -> DiagnosticEditPhase {
        switch (text, time) {
        case (false, false): return .none
        case (true, false): return .text
        case (false, true): return .time
        case (true, true): return .textAndTime
        }
    }
}

public enum DiagnosticScopeSource: String, Equatable, Sendable {
    case picker
    case pickerApply = "picker-apply"
    /// The segmented control caught up with the model after a command changed it.
    case echo
    case command
}

public enum DiagnosticTimeField: String, Equatable, Sendable {
    case start
    case end
    case duration
}

/// Menu title class. Standard menu-bar titles are logged. Anything else is only
/// a count, so a filename in Open Recent is not copied into the trace.
public enum DiagnosticMenuName: Equatable, Sendable {
    case standard(String)
    case other

    private static let standardTitles: Set<String> = [
        "pgs2srt", "file", "edit", "view", "format", "window", "go", "help"
    ]

    public static func classify(title: String?) -> DiagnosticMenuName {
        guard let title else { return .other }
        let token = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.standardTitles.contains(token) else { return .other }
        return .standard(token)
    }

    public var logToken: String {
        switch self {
        case let .standard(name): return name
        case .other: return "other"
        }
    }
}

public enum QueueProgressObservation: Equatable, Sendable {
    case none
    case converting(completed: Int, total: Int)
    case multiple

    public var label: String {
        switch self {
        case .none:
            return "none"
        case let .converting(completed, total):
            return "\(completed)/\(total)"
        case .multiple:
            return "multiple"
        }
    }
}

/// Command-relevant queue facts. Progress counts are visible in the line and
/// are left out of `availabilityKey`, so cue ticks can be coalesced.
public struct QueueCommandSnapshot: Equatable, Sendable {
    public var itemCount: Int
    public var activeCount: Int
    public var removableCount: Int
    public var hasCancellableWork: Bool
    public var canClearFinished: Bool
    public var hasReviewsNeedingSave: Bool
    public var progress: QueueProgressObservation

    public init(
        itemCount: Int,
        activeCount: Int,
        removableCount: Int,
        hasCancellableWork: Bool,
        canClearFinished: Bool,
        hasReviewsNeedingSave: Bool,
        progress: QueueProgressObservation
    ) {
        self.itemCount = itemCount
        self.activeCount = activeCount
        self.removableCount = removableCount
        self.hasCancellableWork = hasCancellableWork
        self.canClearFinished = canClearFinished
        self.hasReviewsNeedingSave = hasReviewsNeedingSave
        self.progress = progress
    }

    public static func observe(items: [ConversionItem], hasReviewsNeedingSave: Bool) -> QueueCommandSnapshot {
        var active = 0
        var removable = 0
        var converting: [(completed: Int, total: Int)] = []
        for item in items {
            if item.status.isActive { active += 1 }
            if item.status.isRemovable { removable += 1 }
            if case let .converting(completed, total) = item.status {
                converting.append((completed, total))
            }
        }
        let progress: QueueProgressObservation
        if converting.count > 1 {
            progress = .multiple
        } else if let only = converting.first {
            progress = .converting(completed: only.completed, total: only.total)
        } else {
            progress = .none
        }
        return QueueCommandSnapshot(
            itemCount: items.count,
            activeCount: active,
            removableCount: removable,
            hasCancellableWork: active > 0,
            canClearFinished: removable > 0,
            hasReviewsNeedingSave: hasReviewsNeedingSave,
            progress: progress
        )
    }

    /// Identity of Cancel All, Clear Finished, and Save All Reviewed. Progress numbers are excluded.
    public var availabilityKey: String {
        "\(itemCount)|\(activeCount)|\(removableCount)|\(hasCancellableWork)|\(canClearFinished)|\(hasReviewsNeedingSave)|\(progressKind)"
    }

    private var progressKind: String {
        switch progress {
        case .none: return "none"
        case .converting: return "converting"
        case .multiple: return "multiple"
        }
    }
}

/// Booleans the review commands read. Closures and cue text are not included.
public struct ReviewCommandFocusSnapshot: Equatable, Sendable {
    public var canSaveAll: Bool
    public var canUndo: Bool
    public var canRedo: Bool
    public var canMerge: Bool
    public var canDelete: Bool
    public var canStepProblem: Bool
    public var canNextFile: Bool
    public var showPictures: Bool

    public init(
        canSaveAll: Bool,
        canUndo: Bool,
        canRedo: Bool,
        canMerge: Bool,
        canDelete: Bool,
        canStepProblem: Bool,
        canNextFile: Bool,
        showPictures: Bool
    ) {
        self.canSaveAll = canSaveAll
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.canMerge = canMerge
        self.canDelete = canDelete
        self.canStepProblem = canStepProblem
        self.canNextFile = canNextFile
        self.showPictures = showPictures
    }

    public var key: String {
        "\(canSaveAll)|\(canUndo)|\(canRedo)|\(canMerge)|\(canDelete)|\(canStepProblem)|\(canNextFile)|\(showPictures)"
    }
}

public struct DiagnosticEvent: Equatable, Sendable {
    public var group: String
    public var signature: String
    public var message: String
    public var coalesce: Bool

    public init(group: String, signature: String, message: String, coalesce: Bool) {
        self.group = group
        self.signature = signature
        self.message = message
        self.coalesce = coalesce
    }
}

public enum DiagnosticFormatting {
    public static func startup(version: String, build: String, tracing: Bool, stableCommands: Bool) -> DiagnosticEvent {
        let tracingText = tracing ? "on" : "off"
        let stableText = stableCommands ? "on" : "off"
        return immediate(
            group: "startup",
            message: "diagnostics on version=\(version) build=\(build) tracing=\(tracingText) stable-commands=\(stableText)"
        )
    }

    public static func modelRefresh(_ snapshot: QueueCommandSnapshot, menu: String) -> DiagnosticEvent {
        let message = "model-refresh items=\(snapshot.itemCount) active=\(snapshot.activeCount) removable=\(snapshot.removableCount) cancel=\(flag(snapshot.hasCancellableWork)) clear=\(flag(snapshot.canClearFinished)) saveAll=\(flag(snapshot.hasReviewsNeedingSave)) progress=\(snapshot.progress.label) menu=\(menu)"
        return coalesced(group: "model-refresh", signature: snapshot.availabilityKey + "|" + menu, message: message)
    }

    public static func commandsEval(
        hasCancellableWork: Bool,
        canClearFinished: Bool,
        hasReviewsNeedingSave: Bool,
        reviewFocused: Bool,
        queueCanReview: Bool,
        menu: String
    ) -> DiagnosticEvent {
        let message = "commands-eval cancel=\(flag(hasCancellableWork)) clear=\(flag(canClearFinished)) saveAll=\(flag(hasReviewsNeedingSave)) review=\(flag(reviewFocused)) canReview=\(flag(queueCanReview)) menu=\(menu)"
        let signature = "\(hasCancellableWork)|\(canClearFinished)|\(hasReviewsNeedingSave)|\(reviewFocused)|\(queueCanReview)|\(menu)"
        return coalesced(group: "commands-eval", signature: signature, message: message)
    }

    public static func queueFocus(
        candidate: Bool,
        stable: Bool,
        canReview: Bool,
        canCancel: Bool,
        canClear: Bool,
        menu: String
    ) -> DiagnosticEvent {
        let kind = candidate ? "candidate" : "apply"
        let message = "queue-focus \(kind) stable=\(flag(stable)) canReview=\(flag(canReview)) cancel=\(flag(canCancel)) clear=\(flag(canClear)) menu=\(menu)"
        let signature = "\(kind)|\(stable)|\(canReview)|\(canCancel)|\(canClear)|\(menu)"
        return coalesced(group: "queue-focus", signature: signature, message: message)
    }

    public static func reviewFocus(_ snapshot: ReviewCommandFocusSnapshot, menu: String) -> DiagnosticEvent {
        let message = "review-focus saveAll=\(flag(snapshot.canSaveAll)) undo=\(flag(snapshot.canUndo)) redo=\(flag(snapshot.canRedo)) merge=\(flag(snapshot.canMerge)) delete=\(flag(snapshot.canDelete)) problem=\(flag(snapshot.canStepProblem)) nextFile=\(flag(snapshot.canNextFile)) pictures=\(flag(snapshot.showPictures)) menu=\(menu)"
        return coalesced(group: "review-focus", signature: snapshot.key + "|" + menu, message: message)
    }

    public static func windowMarker(hadWindow: Bool, identifierChanged: Bool, menu: String) -> DiagnosticEvent {
        let message = "window-marker hadWindow=\(flag(hadWindow)) identifierChanged=\(flag(identifierChanged)) menu=\(menu)"
        return coalesced(
            group: "window-marker",
            signature: "\(hadWindow)|\(identifierChanged)|\(menu)",
            message: message
        )
    }

    public static func menuTrack(
        phase: String,
        menu: DiagnosticMenuName,
        itemCount: Int,
        cancelAll: String?,
        clearFinished: String?
    ) -> DiagnosticEvent {
        var message = "menu-track \(phase) menu=\(menu.logToken) items=\(itemCount)"
        if let cancelAll, let clearFinished {
            message += " cancelAll=\(cancelAll) clearFinished=\(clearFinished)"
        }
        return immediate(group: "menu-track", message: message)
    }

    public static func scopeIntent(
        source: DiagnosticScopeSource,
        from: ReviewScope,
        to: ReviewScope,
        edit: DiagnosticEditPhase,
        selectionCount: Int,
        dirty: Bool
    ) -> DiagnosticEvent {
        immediate(
            group: "scope",
            message: "scope intent source=\(source.rawValue) from=\(from.rawValue) to=\(to.rawValue) edit=\(edit.rawValue) selection=\(selectionCount) dirty=\(flag(dirty))"
        )
    }

    public static func scopeBoundary(
        phase: String,
        source: DiagnosticScopeSource,
        from: ReviewScope,
        to: ReviewScope,
        edit: DiagnosticEditPhase,
        selectionCount: Int,
        dirty: Bool,
        published: Bool,
        stickyCount: Int?
    ) -> DiagnosticEvent {
        let sticky = stickyCount.map(String.init) ?? "none"
        return immediate(
            group: "scope",
            message: "scope \(phase) source=\(source.rawValue) from=\(from.rawValue) to=\(to.rawValue) edit=\(edit.rawValue) selection=\(selectionCount) dirty=\(flag(dirty)) published=\(flag(published)) sticky=\(sticky)"
        )
    }

    public static func editPhase(_ phase: DiagnosticEditPhase, field: DiagnosticTimeField?) -> DiagnosticEvent {
        var message = "edit-phase phase=\(phase.rawValue)"
        if let field {
            message += " field=\(field.rawValue)"
        }
        return immediate(group: "edit-phase", message: message)
    }

    public static func coalesce(phase: String, published: Bool) -> DiagnosticEvent {
        immediate(group: "coalesce", message: "coalesce-end \(phase) published=\(flag(published))")
    }

    public static func timeCommit(field: DiagnosticTimeField, phase: String, changed: Bool) -> DiagnosticEvent {
        immediate(
            group: "time-commit",
            message: "time-commit field=\(field.rawValue) \(phase) changed=\(flag(changed))"
        )
    }

    public static func selection(phase: String, count: Int) -> DiagnosticEvent {
        coalesced(group: "selection", signature: "\(phase)|\(count)", message: "selection \(phase) count=\(count)")
    }

    /// `willWrite` records what this call site is about to do. The update site
    /// and the install site assign only when the value differs.
    public static func documentEdited(
        site: String,
        windowExisted: Bool,
        previous: Bool?,
        requested: Bool,
        willWrite: Bool
    ) -> DiagnosticEvent {
        let previousText = previous.map { flag($0) } ?? "none"
        let message = "document-edited site=\(site) window=\(flag(windowExisted)) previous=\(previousText) requested=\(flag(requested)) willWrite=\(flag(willWrite))"
        let signature = "\(site)|\(windowExisted)|\(previousText)|\(requested)|\(willWrite)"
        return coalesced(group: "document-edited", signature: signature, message: message)
    }

    public static func save(phase: String, result: String?, dirty: Bool?) -> DiagnosticEvent {
        var message = "save \(phase)"
        if let result {
            message += " result=\(result)"
        }
        if let dirty {
            message += " dirty=\(flag(dirty))"
        }
        return immediate(group: "save", message: message)
    }

    private static func flag(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private static func immediate(group: String, message: String) -> DiagnosticEvent {
        DiagnosticEvent(group: group, signature: message, message: message, coalesce: false)
    }

    private static func coalesced(group: String, signature: String, message: String) -> DiagnosticEvent {
        DiagnosticEvent(group: group, signature: signature, message: message, coalesce: true)
    }
}

/// Collapses repeated high-frequency lines. Each group is counted on its own,
/// so a command evaluation does not cancel a model-refresh run.
/// A line that does not coalesce flushes every open run first, which is how a
/// File-menu boundary stays next to the publications that preceded it.
public final class DiagnosticCoalescer: @unchecked Sendable {
    public static let repeatFlushInterval: TimeInterval = 1

    private struct Pending {
        var signature: String
        var message: String
        var count: Int
        var windowStart: Date
    }

    private let lock = NSLock()
    private var pending: [String: Pending] = [:]

    public init() {}

    public func ingest(_ event: DiagnosticEvent, at date: Date) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if event.coalesce {
            return ingestCoalesced(event, at: date)
        }
        var lines = flushPending(at: date)
        lines.append(event.message)
        return lines
    }

    public func flush(at date: Date) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return flushPending(at: date)
    }

    private func ingestCoalesced(_ event: DiagnosticEvent, at date: Date) -> [String] {
        if var current = pending[event.group], current.signature == event.signature {
            current.count += 1
            current.message = event.message
            let elapsed = date.timeIntervalSince(current.windowStart)
            if elapsed >= Self.repeatFlushInterval {
                let line = Self.repeatLine(count: current.count, elapsed: elapsed, message: current.message)
                current.count = 0
                current.windowStart = date
                pending[event.group] = current
                return [line]
            }
            pending[event.group] = current
            return []
        }
        var lines: [String] = []
        if let current = pending[event.group], current.count > 0 {
            lines.append(Self.repeatLine(
                count: current.count,
                elapsed: date.timeIntervalSince(current.windowStart),
                message: current.message
            ))
        }
        lines.append(event.message)
        pending[event.group] = Pending(
            signature: event.signature,
            message: event.message,
            count: 0,
            windowStart: date
        )
        return lines
    }

    private func flushPending(at date: Date) -> [String] {
        let groups = pending.keys.sorted()
        var lines: [String] = []
        for group in groups {
            guard let current = pending[group], current.count > 0 else { continue }
            lines.append(Self.repeatLine(
                count: current.count,
                elapsed: date.timeIntervalSince(current.windowStart),
                message: current.message
            ))
        }
        pending.removeAll()
        return lines
    }

    private static func repeatLine(count: Int, elapsed: TimeInterval, message: String) -> String {
        let seconds = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), max(0, elapsed))
        return "repeated \(count) over \(seconds)s; last \(message)"
    }
}
