import AppKit
import Foundation
import PGSCore

/// Opt-in trace for #35 and #30. Off unless `PGS2SRT_DIAGNOSTICS` or the
/// `PGS2SRTDiagnostics` default is on. `PGS2SRT_STABLE_COMMANDS` (or
/// `PGS2SRTStableCommands`) is a separate comparison: focused queue actions
/// update only when Review's availability changes. Neither flag is a fix.
///
/// Set `PGS2SRT_DIAGNOSTICS=0` to force the trace off. Lines go to the debug
/// log under the `diagnostic` category and do not include subtitle text.
enum IssueDiagnosticLog {
    static let enabled = DiagnosticSwitch.isOn(
        environmentValue: ProcessInfo.processInfo.environment["PGS2SRT_DIAGNOSTICS"],
        defaultsFlag: UserDefaults.standard.bool(forKey: "PGS2SRTDiagnostics")
    )
    static let stableCommands = DiagnosticSwitch.isOn(
        environmentValue: ProcessInfo.processInfo.environment["PGS2SRT_STABLE_COMMANDS"],
        defaultsFlag: UserDefaults.standard.bool(forKey: "PGS2SRTStableCommands")
    )

    private static let stateLock = NSLock()
    private static let coalescer = DiagnosticCoalescer()
    private static var started = false
    private static let menuRelay = MenuTraceRelay()
    private static var menuToken = "closed"
    private static var textEditing = false
    private static var timeField: DiagnosticTimeField?

    static func start(version: String, build: String) {
        stateLock.lock()
        if started {
            stateLock.unlock()
            return
        }
        started = true
        stateLock.unlock()
        guard enabled || stableCommands else { return }
        write(DiagnosticFormatting.startup(
            version: version,
            build: build,
            tracing: enabled,
            stableCommands: stableCommands
        ))
        guard enabled else { return }
        installMenuObservers()
    }

    static func flush() {
        guard enabled else { return }
        for line in coalescer.flush(at: Date()) {
            DebugLog.shared.record(.diagnostic, line)
        }
    }

    static var currentEditPhase: DiagnosticEditPhase {
        stateLock.lock()
        defer { stateLock.unlock() }
        return DiagnosticEditPhase.combine(text: textEditing, time: timeField != nil)
    }

    static func recordModelRefresh(items: [ConversionItem], hasReviewsNeedingSave: Bool) {
        guard enabled else { return }
        let snapshot = QueueCommandSnapshot.observe(items: items, hasReviewsNeedingSave: hasReviewsNeedingSave)
        write(DiagnosticFormatting.modelRefresh(snapshot, menu: menu))
    }

    static func recordCommands(
        hasCancellableWork: Bool,
        canClearFinished: Bool,
        hasReviewsNeedingSave: Bool,
        reviewFocused: Bool,
        queueCanReview: Bool
    ) {
        guard enabled else { return }
        write(DiagnosticFormatting.commandsEval(
            hasCancellableWork: hasCancellableWork,
            canClearFinished: canClearFinished,
            hasReviewsNeedingSave: hasReviewsNeedingSave,
            reviewFocused: reviewFocused,
            queueCanReview: queueCanReview,
            menu: menu
        ))
    }

    static func recordQueueFocus(candidate: Bool, canReview: Bool) {
        guard enabled else { return }
        write(DiagnosticFormatting.queueFocus(
            candidate: candidate,
            stable: stableCommands,
            canReview: canReview,
            menu: menu
        ))
    }

    static func recordReviewFocus(_ snapshot: ReviewCommandFocusSnapshot) {
        guard enabled else { return }
        write(DiagnosticFormatting.reviewFocus(snapshot, menu: menu))
    }

    static func recordWindowMarker(hadWindow: Bool, identifierChanged: Bool) {
        guard enabled else { return }
        write(DiagnosticFormatting.windowMarker(
            hadWindow: hadWindow,
            identifierChanged: identifierChanged,
            menu: menu
        ))
    }

    static func recordScopeIntent(
        source: DiagnosticScopeSource,
        from: ReviewScope,
        to: ReviewScope,
        selectionCount: Int,
        dirty: Bool
    ) {
        guard enabled else { return }
        write(DiagnosticFormatting.scopeIntent(
            source: source,
            from: from,
            to: to,
            edit: currentEditPhase,
            selectionCount: selectionCount,
            dirty: dirty
        ))
    }

    static func recordScopeBoundary(
        phase: String,
        source: DiagnosticScopeSource,
        from: ReviewScope,
        to: ReviewScope,
        selectionCount: Int,
        dirty: Bool,
        published: Bool,
        stickyCount: Int?
    ) {
        guard enabled else { return }
        write(DiagnosticFormatting.scopeBoundary(
            phase: phase,
            source: source,
            from: from,
            to: to,
            edit: currentEditPhase,
            selectionCount: selectionCount,
            dirty: dirty,
            published: published,
            stickyCount: stickyCount
        ))
    }

    static func noteTextEditing(_ active: Bool) {
        guard enabled else { return }
        stateLock.lock()
        textEditing = active
        let phase = DiagnosticEditPhase.combine(text: textEditing, time: timeField != nil)
        let field = timeField
        stateLock.unlock()
        write(DiagnosticFormatting.editPhase(phase, field: field))
    }

    static func noteTimeField(_ field: DiagnosticTimeField, focused: Bool) {
        guard enabled else { return }
        stateLock.lock()
        if focused {
            timeField = field
        } else if timeField == field {
            timeField = nil
        }
        let phase = DiagnosticEditPhase.combine(text: textEditing, time: timeField != nil)
        stateLock.unlock()
        write(DiagnosticFormatting.editPhase(phase, field: field))
    }

    static func recordCoalesce(phase: String, published: Bool) {
        guard enabled else { return }
        write(DiagnosticFormatting.coalesce(phase: phase, published: published))
    }

    static func recordTimeCommit(field: DiagnosticTimeField, phase: String, changed: Bool) {
        guard enabled else { return }
        write(DiagnosticFormatting.timeCommit(field: field, phase: phase, changed: changed))
    }

    static func recordSelection(phase: String, count: Int) {
        guard enabled else { return }
        write(DiagnosticFormatting.selection(phase: phase, count: count))
    }

    static func recordDocumentEdited(
        site: String,
        windowExisted: Bool,
        previous: Bool?,
        requested: Bool,
        willWrite: Bool
    ) {
        guard enabled else { return }
        write(DiagnosticFormatting.documentEdited(
            site: site,
            windowExisted: windowExisted,
            previous: previous,
            requested: requested,
            willWrite: willWrite
        ))
    }

    static func recordSave(phase: String, result: String?, dirty: Bool?) {
        guard enabled else { return }
        write(DiagnosticFormatting.save(phase: phase, result: result, dirty: dirty))
    }

    private static var menu: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return menuToken
    }

    private static func write(_ event: DiagnosticEvent) {
        for line in coalescer.ingest(event, at: Date()) {
            DebugLog.shared.record(.diagnostic, line)
        }
    }

    private static func installMenuObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            menuRelay,
            selector: #selector(MenuTraceRelay.menuBegan(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        center.addObserver(
            menuRelay,
            selector: #selector(MenuTraceRelay.menuEnded(_:)),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    /// Posted on the main thread while a menu is tracking. Reads titles and enabled
    /// flags only. It does not enable, disable, or rebuild items.
    fileprivate static func noteMenu(_ notification: Notification, phase: String) {
        let menu = notification.object as? NSMenu
        let name = DiagnosticMenuName.classify(title: menu?.title)
        let count = menu?.items.count ?? 0
        var cancelAll: String?
        var clearFinished: String?
        if name.logToken == "file", let menu {
            cancelAll = enabledFlag(menu, title: "Cancel All")
            clearFinished = enabledFlag(menu, title: "Clear Finished")
        }
        stateLock.lock()
        menuToken = phase == "begin" ? name.logToken : "closed"
        stateLock.unlock()
        write(DiagnosticFormatting.menuTrack(
            phase: phase,
            menu: name,
            itemCount: count,
            cancelAll: cancelAll,
            clearFinished: clearFinished
        ))
    }

    private static func enabledFlag(_ menu: NSMenu, title: String) -> String {
        guard let item = menu.items.first(where: { $0.title == title }) else { return "missing" }
        return item.isEnabled ? "on" : "off"
    }
}

/// Holds the menu-tracking observers for the life of the process.
private final class MenuTraceRelay: NSObject {
    @objc func menuBegan(_ notification: Notification) {
        IssueDiagnosticLog.noteMenu(notification, phase: "begin")
    }

    @objc func menuEnded(_ notification: Notification) {
        IssueDiagnosticLog.noteMenu(notification, phase: "end")
    }
}
