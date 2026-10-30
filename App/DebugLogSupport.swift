import AppKit
import Darwin
import Foundation
import OSLog
import PGSCore
import UniformTypeIdentifiers

/// `os.Logger` categories for Console.app. Lines are already redacted.
enum AppLog {
    private static let subsystem = "com.pgs2srt.PGS2SRT"

    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let queue = Logger(subsystem: subsystem, category: "queue")
    static let decode = Logger(subsystem: subsystem, category: "decode")
    static let ocr = Logger(subsystem: subsystem, category: "ocr")
    static let mkv = Logger(subsystem: subsystem, category: "mkv")
    static let error = Logger(subsystem: subsystem, category: "error")

    static func write(_ line: DebugLogLine) {
        let message = line.message
        if line.isError {
            logger(for: line.category).error("\(message, privacy: .public)")
            if line.category != .error {
                error.error("\(message, privacy: .public)")
            }
        } else {
            logger(for: line.category).info("\(message, privacy: .public)")
        }
    }

    private static func logger(for category: DebugLogCategory) -> Logger {
        switch category {
        case .lifecycle: return lifecycle
        case .queue: return queue
        case .decode: return decode
        case .ocr: return ocr
        case .mkv: return mkv
        case .error: return error
        }
    }
}

enum AppVersion {
    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }
}

/// Machine facts for the exported header. This stays in the app so PGSCore has no AppKit.
enum DebugMachine {
    static func environment(settings: String) -> DebugEnvironment {
        let architecture = processArchitecture
        let rosetta = runningUnderRosetta
        let tools = MKVToolNix.locate()
        let version = tools.flatMap { MKVToolNix.version(of: $0.mkvmerge) }
        return DebugEnvironment(
            appVersion: AppVersion.marketing,
            appBuild: AppVersion.build,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            model: modelIdentifier,
            chip: DebugChip.label(architecture: architecture, runningUnderRosetta: rosetta),
            architecture: architecture,
            runningUnderRosetta: rosetta,
            mkvToolNixPath: tools?.mkvmerge,
            mkvToolNixVersion: version,
            settings: settings
        )
    }

    private static var processArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// `sysctl.proc_translated` is 1 when an Intel slice is running on Apple silicon.
    private static var runningUnderRosetta: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0)
        return result == 0 && value == 1
    }

    private static var modelIdentifier: String {
        sysctlString("hw.model") ?? sysctlString("hw.machine") ?? "unknown"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        if sysctlbyname(name, nil, &size, nil, 0) != 0 || size <= 1 {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        let status = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let base = pointer.baseAddress else { return -1 }
            return sysctlbyname(name, base, &size, nil, 0)
        }
        guard status == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Writes the debug log to the Desktop, then confirms. A save panel is the fallback.
@MainActor
enum DebugLogExporter {
    static func write(text: String, fileName: String) {
        let desktop = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Desktop", isDirectory: true)
        let destination = desktop.appendingPathComponent(fileName)
        do {
            try text.write(to: destination, atomically: true, encoding: .utf8)
            DebugLog.shared.record(.lifecycle, "Exported debug log to \(destination.path)")
            confirm(url: destination, onDesktop: true)
        } catch {
            DebugLog.shared.record(
                .error,
                "Desktop export failed: \(reason(error))",
                isError: true
            )
            saveElsewhere(text: text, fileName: fileName, desktopError: error)
        }
    }

    private static func saveElsewhere(text: String, fileName: String, desktopError: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The debug log could not be saved to the Desktop."
        alert.informativeText = "\(reason(desktopError)) Choose another folder."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        if alert.buttons.count > 1 {
            alert.buttons[1].keyEquivalent = "\u{1b}"
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSSavePanel()
        panel.title = "Export Debug Log"
        panel.prompt = "Save"
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.plainText]
        panel.message = "The Desktop could not be written. \(reason(desktopError))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            DebugLog.shared.record(.lifecycle, "Exported debug log to \(url.path)")
            confirm(url: url, onDesktop: false)
        } catch {
            DebugLog.shared.record(.error, "Export failed: \(reason(error))", isError: true)
            let failed = NSAlert()
            failed.alertStyle = .warning
            failed.messageText = "The debug log could not be saved."
            failed.informativeText = reason(error)
            failed.addButton(withTitle: "OK")
            failed.runModal()
        }
    }

    private static func confirm(url: URL, onDesktop: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Debug log saved"
        if onDesktop {
            alert.informativeText = "Saved on the Desktop as \(url.lastPathComponent)."
        } else {
            alert.informativeText = "Saved as \(url.lastPathComponent)."
        }
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "OK")
        if alert.buttons.count > 1 {
            alert.buttons[1].keyEquivalent = "\u{1b}"
        }
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private static func reason(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "The file could not be written." }
        return trimmed
    }
}
