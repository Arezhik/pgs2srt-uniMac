import AppKit
import Combine
import Foundation
import PGSCore
import UniformTypeIdentifiers
import UserNotifications
import VisionOCR

/// Owns the queue, the open panel, and notifications. The window watches this object.
/// Conversion itself goes through `TranscriptionPipeline`, on a background task.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var items: [ConversionItem] = []
    @Published private(set) var banners: [String] = []
    @Published private(set) var preferences: ConversionPreferences
    @Published var selectedItemID: UUID?
    @Published private(set) var reviewRevision = 0
    @Published var reviewOpenRequest: UUID?
    @Published private(set) var reviewWindows: [ReviewWindowState] = []
    private var reviewFiles: [UUID: ReviewFileModel] = [:]
    private var focusedReviewWindowID: UUID?

    private let queue: ConversionQueue
    static weak var shared: AppModel?

    init() {
        let preferences = ConversionPreferenceStore.load(from: .standard)
        self.preferences = preferences
        let queue = ConversionQueue(preferences: preferences, services: Self.makeServices())
        self.queue = queue
        queue.onChange = { [weak self] in
            self?.refresh()
        }
        queue.onBatchFinished = { outcome in
            BatchNotifier.announce(outcome)
        }
        queue.confirmReplace = { path in
            await OverwritePrompt.ask(outputPath: path)
        }
        queue.chooseTrack = { name, tracks, suggested in
            await TrackPrompt.ask(fileName: name, tracks: tracks, suggestedTrackID: suggested)
        }
        AppModel.shared = self
        let pending = AppDelegate.setDeliver { urls in
            let urls = urls
            Task { @MainActor in
                AppModel.shared?.importURLs(urls)
            }
        }
        if !pending.isEmpty {
            importURLs(pending)
        }
    }

    var hasCancellableWork: Bool {
        items.contains(where: \.status.isActive)
    }

    /// Done, failed, skipped, and cancelled rows can leave the list.
    var canClearFinished: Bool {
        items.contains(where: \.status.isRemovable)
    }

    var settingsSummary: String {
        let language = LanguageChoices.label(for: preferences.language)
        let place: String
        switch preferences.placement {
        case .nextToSource:
            place = "next to the source file"
        case let .folder(path):
            place = path.isEmpty ? "choose a folder in Settings" : path
        }
        let italics = preferences.experimentalItalics ? " · Experimental italics on" : ""
        return "\(language) · \(place) · \(preferences.concurrency) pictures at a time\(italics)"
    }

    func importURLs(_ urls: [URL]) {
        add(paths: urls.map(\.path))
    }

    func add(paths: [String]) {
        queue.add(paths: paths)
        refresh()
        if hasCancellableWork {
            BatchNotifier.requestPermissionIfNeeded()
        }
    }

    func cancel(id: UUID) {
        queue.cancel(id: id)
    }

    func cancelAll() {
        queue.cancelAll()
    }

    func remove(id: UUID) {
        queue.remove(id: id)
    }

    func clearFinished() {
        queue.clearFinished()
    }

    func dismissBanner(at index: Int) {
        queue.dismissBanner(at: index)
    }

    func reveal(_ item: ConversionItem) {
        guard case let .done(_, _, path) = item.status else { return }
        switch RevealFollowUp.plan(
            outputPath: path,
            sourcePath: item.sourcePath,
            fileExists: Self.regularFileExists,
            directoryExists: Self.directoryExists
        ) {
        case let .showFile(path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case let .alert(alert):
            let source = item.sourcePath
            Task { @MainActor in
                let choice = await RevealPrompt.ask(alert)
                self.followUp(choice, alert: alert, source: source)
            }
        }
    }

    private func followUp(_ choice: RevealButton, alert: RevealAlert, source: String) {
        switch choice {
        case .showFolder:
            guard alert.folderExists, !alert.outputFolder.isEmpty else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: alert.outputFolder, isDirectory: true))
        case .convertAgain:
            if let folder = RevealFollowUp.restoredFolder(for: alert) {
                try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                queue.add(paths: [source], outputFolder: folder)
            } else {
                add(paths: [source])
            }
        case .cancel, .ok:
            break
        }
    }

    private static func regularFileExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Subtitles"
        panel.message = "Choose .sup files, .mkv files, or a folder."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.openableTypes
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    func chooseOutputFolder() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Output Folder"
        panel.message = "Converted .srt files will be written in this folder."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    func updatePreferences(_ preferences: ConversionPreferences) {
        let preferences = preferences.normalized
        self.preferences = preferences
        queue.preferences = preferences
    }

    private func refresh() {
        items = queue.items
        banners = queue.banners
        let ids = Set(items.map(\.id))
        for item in items where reviewFiles[item.id] == nil && queue.hasReview(for: item.id) {
            reviewFiles[item.id] = ReviewFileModel(itemID: item.id, queue: queue) { [weak self] in
                self?.reviewRevision &+= 1
            }
        }
        for id in reviewFiles.keys where !ids.contains(id) {
            reviewFiles[id] = nil
        }
        if let selectedItemID, !ids.contains(selectedItemID) {
            self.selectedItemID = nil
        }
    }

    func reviewFile(for id: UUID) -> ReviewFileModel? {
        reviewFiles[id]
    }

    func summary(for item: ConversionItem) -> ReviewRowSummary? {
        reviewFiles[item.id]?.summary
    }

    func requestReview(itemID: UUID, newWindow: Bool) {
        guard queue.hasReview(for: itemID) else { return }
        selectedItemID = itemID
        let windowID: UUID
        if !newWindow, let focused = focusedReviewWindowID,
           let state = reviewWindows.first(where: { $0.id == focused }) {
            state.itemID = itemID
            windowID = state.id
        } else if !newWindow, let existing = reviewWindows.first {
            existing.itemID = itemID
            windowID = existing.id
        } else {
            let state = ReviewWindowState(itemID: itemID)
            reviewWindows.append(state)
            windowID = state.id
        }
        focusedReviewWindowID = windowID
        reviewOpenRequest = windowID
    }

    func closeReviewWindow(_ id: UUID) {
        reviewWindows.removeAll { $0.id == id }
        if focusedReviewWindowID == id {
            focusedReviewWindowID = reviewWindows.last?.id
        }
    }

    func noteReviewWindowKey(_ id: UUID) {
        focusedReviewWindowID = id
    }

    var finishedReviewCount: Int {
        items.reduce(0) { partial, item in
            partial + (reviewFiles[item.id] == nil ? 0 : 1)
        }
    }

    var hasReviewsNeedingSave: Bool {
        reviewFiles.values.contains { $0.document.needsWriting }
    }

    func batchEntries() -> [ReviewQueueEntry] {
        items.compactMap { item in
            guard let file = reviewFiles[item.id] else { return nil }
            let document = file.document
            return ReviewQueueEntry(
                id: item.id,
                needsReview: ReviewBatchOrder.needsReview(
                    problemCount: document.ocrFailedCount + document.lowConfidenceCount,
                    needsWriting: document.needsWriting
                )
            )
        }
    }

    func nextReviewFile(after id: UUID) -> UUID? {
        ReviewBatchOrder.nextReviewFile(after: id, in: batchEntries())
    }

    func batchPosition(for id: UUID) -> (index: Int, total: Int)? {
        ReviewBatchOrder.position(of: id, in: batchEntries())
    }

    func discardAllUnsavedEdits() {
        for file in reviewFiles.values {
            file.discardUnsavedEdits()
        }
    }

    func resolveUnsavedEdits(for itemID: UUID, host: NSWindow?) async -> Bool {
        guard let file = reviewFiles[itemID], file.document.hasUnsavedEdits else { return true }
        let name = ReviewFormat.title(for: items.first { $0.id == itemID }?.name ?? "Subtitles")
        switch await UnsavedPrompt.ask(fileName: name, host: host) {
        case .cancel:
            return false
        case .discard:
            file.discardUnsavedEdits()
            return true
        case .save:
            return await saveReview(itemID: itemID, host: host)
        }
    }

    func saveReview(itemID: UUID, host: NSWindow?) async -> Bool {
        guard let file = reviewFiles[itemID] else { return false }
        let path = file.savedPath ?? file.plannedPath
        guard !path.isEmpty else { return false }
        return await writeReview(file, to: path, host: host)
    }

    func saveReviewAs(itemID: UUID, host: NSWindow?) async -> Bool {
        guard let file = reviewFiles[itemID] else { return false }
        let suggested = file.savedPath ?? file.plannedPath
        guard let path = chooseSavePath(suggested: suggested) else { return false }
        return await writeReview(file, to: path, host: host)
    }

    func saveAllReviewed() async {
        let host = NSApp.keyWindow
        for item in items where reviewFiles[item.id]?.document.needsWriting == true {
            let saved = await saveReview(itemID: item.id, host: host)
            if !saved { return }
        }
    }

    private func writeReview(_ file: ReviewFileModel, to path: String, host: NSWindow?) async -> Bool {
        let plan = ReviewWritePlanner.plan(
            path: path,
            plannedPath: file.plannedPath,
            savedPath: file.savedPath,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
        if case .confirmReplace = plan {
            switch await OverwritePrompt.ask(outputPath: path, host: host) {
            case let .replace(applyToAll):
                if applyToAll {
                    queue.rememberOverwriteAnswer(.replace(applyToAll: true))
                }
            case .skip, .cancel:
                return false
            }
        }
        do {
            try await queue.saveReview(id: file.itemID, to: path)
            file.noteExternalChange()
            return true
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not save the subtitle"
            alert.informativeText = (error as? LocalizedError)?.errorDescription ?? "The .srt file could not be written."
            alert.addButton(withTitle: "OK")
            if let host {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    alert.beginSheetModal(for: host) { _ in
                        continuation.resume()
                    }
                }
            } else {
                alert.runModal()
            }
            return false
        }
    }

    private func chooseSavePath(suggested: String) -> String? {
        let panel = NSSavePanel()
        panel.title = "Save Subtitles"
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = URL(fileURLWithPath: suggested).lastPathComponent
        if let srt = UTType(filenameExtension: "srt") {
            panel.allowedContentTypes = [srt]
        }
        let directory = URL(fileURLWithPath: suggested).deletingLastPathComponent()
        if !directory.path.isEmpty, directory.path != "/" {
            panel.directoryURL = directory
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if url.pathExtension.isEmpty {
            return url.appendingPathExtension("srt").path
        }
        return url.path
    }

    /// Reads and writes the files the person picked. Recognition uses the shared pipeline.
    private static func makeServices() -> ConversionServices {
        ConversionServices(
            read: { path in
                let url = URL(fileURLWithPath: path)
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try SourceFileBytes.read(path)
            },
            write: { path, text in
                let url = URL(fileURLWithPath: path)
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try text.write(to: url, atomically: true, encoding: .utf8)
            },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            directoryExists: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            listing: .live,
            convert: { work in
                try await TranscriptionPipeline.run(work, recognizer: VisionOCR())
            },
            mkv: .live
        )
    }

    private static var openableTypes: [UTType] {
        var types: [UTType] = [.folder]
        if let sup = UTType(filenameExtension: "sup") { types.append(sup) }
        if let mkv = UTType(filenameExtension: "mkv") { types.append(mkv) }
        return types
    }
}

/// Receives files opened from the Dock or from Finder's Open With.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files that arrive before the window exists, plus the handler that takes later ones.
    /// The lock is why this shared state is safe to touch from the Dock callback.
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var deliver: (([URL]) -> Void)?
        private var pending: [URL] = []

        func accept(_ urls: [URL]) {
            lock.lock()
            let deliver = self.deliver
            if deliver == nil {
                pending.append(contentsOf: urls)
            }
            lock.unlock()
            deliver?(urls)
        }

        func setDeliver(_ deliver: @escaping ([URL]) -> Void) -> [URL] {
            lock.lock()
            self.deliver = deliver
            let urls = pending
            pending = []
            lock.unlock()
            return urls
        }
    }

    private static let inbox = Inbox()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppModel.shared, model.hasReviewsNeedingSave else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the subtitles that are not saved yet?"
        alert.informativeText = "Save writes each .srt file. Don't Save leaves them unsaved."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        if alert.buttons.count > 2 {
            alert.buttons[2].keyEquivalent = "\u{1b}"
        }
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            model.discardAllUnsavedEdits()
            return .terminateNow
        case .alertFirstButtonReturn:
            Task { @MainActor in
                await model.saveAllReviewed()
                NSApp.reply(toApplicationShouldTerminate: !model.hasReviewsNeedingSave)
            }
            return .terminateLater
        default:
            return .terminateCancel
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppDelegate.inbox.accept(urls)
        // The open event can also create a window. Drop the extra one after
        // SwiftUI has had a turn to show it, and again once its view exists.
        Task { @MainActor in
            QueueWindow.keepOne()
            await Task.yield()
            QueueWindow.keepOne()
        }
    }

    /// Installs the handler and returns files that arrived before the window existed.
    static func setDeliver(_ deliver: @escaping ([URL]) -> Void) -> [URL] {
        inbox.setDeliver(deliver)
    }
}

/// The queue window, as opposed to Settings. Dock and Open With drops keep one of these.
enum QueueWindow {
    static let marker = NSUserInterfaceItemIdentifier("pgs2srt.queue")

    @MainActor
    static func keepOne() {
        let windows = NSApp.windows
            .filter { $0.identifier == marker && ($0.isVisible || $0.isMiniaturized) }
            .sorted { $0.windowNumber < $1.windowNumber }
        guard let keeper = windows.first else { return }
        for extra in windows.dropFirst() {
            extra.close()
        }
        if keeper.isMiniaturized {
            keeper.deminiaturize(nil)
        }
        keeper.makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @MainActor
    static func frontmost() -> NSWindow? {
        let windows = NSApp.windows.filter { $0.identifier == marker && ($0.isVisible || $0.isMiniaturized) }
        return windows.first { $0.isKeyWindow } ?? windows.first
    }
}

/// Sheet that asks before Overwrite replaces an existing `.srt`.
@MainActor
enum OverwritePrompt {
    private static var active: Session?

    static func ask(outputPath: String, host: NSWindow? = nil) async -> OverwriteAnswer {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<OverwriteAnswer, Never>) in
                let session = Session(continuation: continuation)
                active = session
                session.present(outputPath: outputPath, preferredHost: host)
            }
        } onCancel: {
            Task { @MainActor in
                active?.cancel()
            }
        }
    }

    @MainActor
    private final class Session {
        private var continuation: CheckedContinuation<OverwriteAnswer, Never>?
        private var cancelled = false
        private var alert: NSAlert?
        private var host: NSWindow?

        init(continuation: CheckedContinuation<OverwriteAnswer, Never>) {
            self.continuation = continuation
        }

        func present(outputPath: String, preferredHost: NSWindow?) {
            if cancelled {
                finish(response: .abort)
                return
            }
            let name = (outputPath as NSString).lastPathComponent
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(name)” already exists."
            let folder = (outputPath as NSString).deletingLastPathComponent
            if folder.isEmpty {
                alert.informativeText = "Replacing it erases the subtitle file that is already there. Skip leaves that file alone."
            } else {
                alert.informativeText = "It is in \(folder). Replacing it erases the subtitle file that is already there. Skip leaves that file alone."
            }
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Skip")
            if alert.buttons.count > 1 {
                alert.buttons[1].keyEquivalent = "\u{1b}"
            }
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Apply to all"
            alert.suppressionButton?.state = .off
            self.alert = alert
            let host = preferredHost ?? QueueWindow.frontmost() ?? NSApp.keyWindow ?? NSApp.mainWindow
            self.host = host
            if let host {
                alert.beginSheetModal(for: host) { response in
                    let response = response
                    Task { @MainActor in
                        OverwritePrompt.active?.finish(response: response)
                    }
                }
            } else {
                let response = alert.runModal()
                finish(response: response)
            }
        }

        func cancel() {
            cancelled = true
            if let host, let sheet = alert?.window, host.attachedSheet === sheet {
                host.endSheet(sheet)
                return
            }
            finish(response: .abort)
        }

        func finish(response: NSApplication.ModalResponse) {
            guard let continuation else { return }
            self.continuation = nil
            if OverwritePrompt.active === self {
                OverwritePrompt.active = nil
            }
            if cancelled {
                continuation.resume(returning: .cancel)
                return
            }
            let applyToAll = alert?.suppressionButton?.state == .on
            switch response {
            case .alertFirstButtonReturn:
                continuation.resume(returning: .replace(applyToAll: applyToAll))
            default:
                continuation.resume(returning: .skip(applyToAll: applyToAll))
            }
        }
    }
}

/// Sheet shown when Reveal in Finder cannot find the finished `.srt`.
@MainActor
enum RevealPrompt {
    private static var active: Session?

    static func ask(_ alert: RevealAlert) async -> RevealButton {
        await withCheckedContinuation { (continuation: CheckedContinuation<RevealButton, Never>) in
            let session = Session(alert: alert, continuation: continuation)
            active = session
            session.present()
        }
    }

    @MainActor
    private final class Session {
        private let alertPlan: RevealAlert
        private var continuation: CheckedContinuation<RevealButton, Never>?

        init(alert: RevealAlert, continuation: CheckedContinuation<RevealButton, Never>) {
            self.alertPlan = alert
            self.continuation = continuation
        }

        func present() {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = alertPlan.title
            alert.informativeText = alertPlan.detail
            let buttons = alertPlan.buttons.isEmpty ? [RevealButton.ok] : alertPlan.buttons
            for button in buttons {
                alert.addButton(withTitle: button.title)
            }
            if let index = buttons.firstIndex(where: { $0 == .cancel || $0 == .ok }),
               index > 0,
               alert.buttons.indices.contains(index) {
                alert.buttons[index].keyEquivalent = "\u{1b}"
            }
            let host = QueueWindow.frontmost() ?? NSApp.keyWindow ?? NSApp.mainWindow
            if let host {
                alert.beginSheetModal(for: host) { response in
                    let response = response
                    Task { @MainActor in
                        RevealPrompt.active?.finish(response: response)
                    }
                }
            } else {
                finish(response: alert.runModal())
            }
        }

        func finish(response: NSApplication.ModalResponse) {
            guard let continuation else { return }
            self.continuation = nil
            if RevealPrompt.active === self {
                RevealPrompt.active = nil
            }
            let buttons = alertPlan.buttons.isEmpty ? [RevealButton.ok] : alertPlan.buttons
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let choice = buttons.indices.contains(index) ? buttons[index] : (buttons.last ?? .ok)
            continuation.resume(returning: choice)
        }
    }
}

/// Sheet that lists the PGS tracks in one MKV. Convert uses the selected track. Skip leaves the file alone.
@MainActor
enum TrackPrompt {
    private static var active: Session?

    static func ask(fileName: String, tracks: [PGSSubtitleTrack], suggestedTrackID: Int) async -> MKVTrackChoice {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<MKVTrackChoice, Never>) in
                let session = Session(tracks: tracks, suggestedTrackID: suggestedTrackID, continuation: continuation)
                active = session
                session.present(fileName: fileName)
            }
        } onCancel: {
            Task { @MainActor in
                active?.cancel()
            }
        }
    }

    @MainActor
    private final class Session: NSObject {
        private let tracks: [PGSSubtitleTrack]
        private let suggestedTrackID: Int
        private var continuation: CheckedContinuation<MKVTrackChoice, Never>?
        private var cancelled = false
        private var alert: NSAlert?
        private var host: NSWindow?
        private var buttons: [NSButton] = []

        init(tracks: [PGSSubtitleTrack], suggestedTrackID: Int, continuation: CheckedContinuation<MKVTrackChoice, Never>) {
            self.tracks = tracks
            self.suggestedTrackID = suggestedTrackID
            self.continuation = continuation
        }

        func present(fileName: String) {
            if cancelled {
                finish(choice: .cancel)
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Choose a subtitle track"
            alert.informativeText = "\(fileName) has these PGS tracks."
            alert.addButton(withTitle: "Convert")
            alert.addButton(withTitle: "Skip")
            if alert.buttons.count > 1 {
                alert.buttons[1].keyEquivalent = "\u{1b}"
            }
            let accessory = makeAccessory()
            alert.accessoryView = accessory.view
            buttons = accessory.buttons
            self.alert = alert
            let host = QueueWindow.frontmost() ?? NSApp.keyWindow ?? NSApp.mainWindow
            self.host = host
            if let host {
                alert.beginSheetModal(for: host) { response in
                    let response = response
                    Task { @MainActor in
                        TrackPrompt.active?.finish(response: response)
                    }
                }
            } else {
                finish(response: alert.runModal())
            }
        }

        func cancel() {
            cancelled = true
            if let host, let sheet = alert?.window, host.attachedSheet === sheet {
                host.endSheet(sheet)
                return
            }
            finish(choice: .cancel)
        }

        func finish(response: NSApplication.ModalResponse) {
            if cancelled {
                finish(choice: .cancel)
                return
            }
            switch response {
            case .alertFirstButtonReturn:
                finish(choice: .convert(trackID: selectedTrackID()))
            default:
                finish(choice: .skip)
            }
        }

        private func finish(choice: MKVTrackChoice) {
            guard let continuation else { return }
            self.continuation = nil
            if TrackPrompt.active === self {
                TrackPrompt.active = nil
            }
            continuation.resume(returning: choice)
        }

        private func selectedTrackID() -> Int {
            if let button = buttons.first(where: { $0.state == .on }) {
                return button.tag
            }
            return tracks.first { $0.id == suggestedTrackID }?.id ?? tracks.first?.id ?? suggestedTrackID
        }

        private func makeAccessory() -> (view: NSView, buttons: [NSButton]) {
            let row: CGFloat = 24
            let width: CGFloat = 460
            let contentHeight = max(row, CGFloat(tracks.count) * row)
            // Flipped so the first track sits at the top, including inside the scroller.
            let content = TopDownView(frame: NSRect(x: 0, y: 0, width: width, height: contentHeight))
            var made: [NSButton] = []
            let suggested = tracks.contains(where: { $0.id == suggestedTrackID }) ? suggestedTrackID : tracks.first?.id
            var y: CGFloat = 0
            for track in tracks {
                let button = NSButton(
                    radioButtonWithTitle: Self.label(track),
                    target: self,
                    action: #selector(pick(_:))
                )
                button.frame = NSRect(x: 0, y: y, width: width - 4, height: row)
                button.tag = track.id
                button.state = track.id == suggested ? .on : .off
                button.lineBreakMode = .byTruncatingTail
                content.addSubview(button)
                made.append(button)
                y += row
            }
            let visible = min(contentHeight, row * 12)
            if contentHeight <= visible {
                return (content, made)
            }
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: visible))
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.documentView = content
            return (scroll, made)
        }

        @objc private func pick(_ sender: NSButton) {}

        private static func label(_ track: PGSSubtitleTrack) -> String {
            var parts = ["\(track.number)", track.displayLanguage]
            if !track.name.isEmpty {
                parts.append(track.name)
            }
            var flags: [String] = []
            if track.forced { flags.append("Forced") }
            if track.isDefault { flags.append("Default") }
            if !flags.isEmpty {
                parts.append(flags.joined(separator: ", "))
            }
            return parts.joined(separator: " · ")
        }
    }
}

/// Top-left origin, so the first radio button is the one at the top of the sheet.
private final class TopDownView: NSView {
    override var isFlipped: Bool { true }
}

enum LanguageChoices {
    static let all: [(label: String, tag: String)] = [
        ("English", "en-US"),
        ("French", "fr-FR"),
        ("German", "de-DE"),
        ("Spanish", "es-ES"),
        ("Italian", "it-IT"),
        ("Portuguese (Brazil)", "pt-BR"),
        ("Dutch", "nl-NL"),
        ("Swedish", "sv-SE"),
        ("Norwegian", "nb-NO"),
        ("Danish", "da-DK"),
        ("Finnish", "fi-FI"),
        ("Polish", "pl-PL"),
        ("Russian", "ru-RU"),
        ("Turkish", "tr-TR"),
        ("Japanese", "ja-JP"),
        ("Korean", "ko-KR"),
        ("Chinese (Simplified)", "zh-Hans"),
        ("Chinese (Traditional)", "zh-Hant")
    ]

    static func label(for tag: String) -> String {
        all.first { $0.tag == tag }?.label ?? tag
    }
}

/// Asks the first time a batch starts, and stays quiet if the person says no.
enum BatchNotifier {
    static func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func announce(_ outcome: BatchOutcome) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                break
            default:
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "PGS2SRT"
            content.body = outcome.notificationBody
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { _ in }
        }
    }
}
