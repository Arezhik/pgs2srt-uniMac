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
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
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
                return try Data(contentsOf: url)
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let lock = NSLock()
    private static var deliver: (([URL]) -> Void)?
    private static var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        AppDelegate.lock.lock()
        let deliver = AppDelegate.deliver
        if deliver == nil {
            AppDelegate.pending.append(contentsOf: urls)
        }
        AppDelegate.lock.unlock()
        deliver?(urls)
    }

    /// Installs the handler and returns files that arrived before the window existed.
    static func setDeliver(_ deliver: @escaping ([URL]) -> Void) -> [URL] {
        lock.lock()
        self.deliver = deliver
        let urls = pending
        pending = []
        lock.unlock()
        return urls
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
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func announce(_ outcome: BatchOutcome) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
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
            center.add(request) { _ in }
        }
    }
}
