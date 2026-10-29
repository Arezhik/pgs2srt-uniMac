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
        panel.message = "Choose .sup files or a folder. An .mkv can be chosen too, but those are not converted yet."
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
            }
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

    static func ask(outputPath: String) async -> OverwriteAnswer {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<OverwriteAnswer, Never>) in
                let session = Session(continuation: continuation)
                active = session
                session.present(outputPath: outputPath)
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

        func present(outputPath: String) {
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
            let host = QueueWindow.frontmost() ?? NSApp.keyWindow ?? NSApp.mainWindow
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
