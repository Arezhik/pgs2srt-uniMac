import Foundation

/// Where a log line belongs. The Mac app mirrors these to `os.Logger` categories.
public enum DebugLogCategory: String, Sendable, CaseIterable {
    case lifecycle
    case queue
    case decode
    case ocr
    case mkv
    case error
}

/// One redacted line, before it is written to disk.
public struct DebugLogLine: Equatable, Sendable {
    public var date: Date
    public var category: DebugLogCategory
    public var message: String
    public var isError: Bool

    public init(date: Date, category: DebugLogCategory, message: String, isError: Bool) {
        self.date = date
        self.category = category
        self.message = message
        self.isError = isError
    }
}

/// Replaces the home folder with `~` so a shared log does not include the account name.
public enum PathRedaction {
    public static func redact(_ text: String, homeDirectory: String) -> String {
        var text = text
        for home in homePrefixes(homeDirectory) {
            text = replacing(home, in: text)
        }
        return text
    }

    private static func homePrefixes(_ homeDirectory: String) -> [String] {
        let trimmed = trimSlash(homeDirectory)
        guard trimmed.count > 1, trimmed != "/" else { return [] }
        var homes = [trimmed]
        if FileManager.default.fileExists(atPath: trimmed) {
            let resolved = trimSlash(URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().path)
            if resolved.count > 1, resolved != "/", resolved != trimmed {
                homes.append(resolved)
            }
        }
        return homes.sorted { $0.count > $1.count }
    }

    private static func trimSlash(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// A match has to end at a path boundary, so `/Users/ada` does not swallow `/Users/ada2`.
    private static func replacing(_ home: String, in text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard let range = text.range(
                of: home,
                options: [.caseInsensitive],
                range: index..<text.endIndex
            ) else {
                result.append(contentsOf: text[index...])
                break
            }
            result.append(contentsOf: text[index..<range.lowerBound])
            let after = range.upperBound
            let atBoundary = after == text.endIndex || text[after] == "/"
            if atBoundary {
                result.append("~")
                index = after
            } else {
                result.append(text[range.lowerBound])
                index = text.index(after: range.lowerBound)
            }
        }
        return result
    }
}

/// Apple silicon or Intel, including a Mac that is running the Intel build under Rosetta.
public enum DebugChip {
    public static func label(architecture: String, runningUnderRosetta: Bool) -> String {
        if runningUnderRosetta || architecture == "arm64" {
            return "Apple silicon"
        }
        return "Intel"
    }
}

/// Facts printed at the top of an exported debug log. The app fills these in.
public struct DebugEnvironment: Equatable, Sendable {
    public var appVersion: String
    public var appBuild: String
    public var operatingSystem: String
    public var model: String
    public var chip: String
    public var architecture: String
    public var runningUnderRosetta: Bool
    public var mkvToolNixPath: String?
    public var mkvToolNixVersion: String?
    public var settings: String

    public init(
        appVersion: String,
        appBuild: String,
        operatingSystem: String,
        model: String,
        chip: String,
        architecture: String,
        runningUnderRosetta: Bool,
        mkvToolNixPath: String?,
        mkvToolNixVersion: String?,
        settings: String
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.operatingSystem = operatingSystem
        self.model = model
        self.chip = chip
        self.architecture = architecture
        self.runningUnderRosetta = runningUnderRosetta
        self.mkvToolNixPath = mkvToolNixPath
        self.mkvToolNixVersion = mkvToolNixVersion
        self.settings = settings
    }
}

/// The Desktop file name and the header that sits above the recent log lines.
public enum DebugLogDocument {
    public static func fileName(at date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "PGS2SRT-debug-log-%04d-%02d-%02d-%02d%02d%02d.txt",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }

    public static func header(for environment: DebugEnvironment) -> String {
        let rosetta = environment.runningUnderRosetta ? "yes" : "no"
        let toolPath = environment.mkvToolNixPath ?? "not found"
        let toolVersion = environment.mkvToolNixVersion ?? "not found"
        return """
        PGS2SRT debug log
        App version: \(environment.appVersion)
        App build: \(environment.appBuild)
        macOS: \(environment.operatingSystem)
        Model: \(environment.model)
        Chip: \(environment.chip)
        Architecture: \(environment.architecture)
        Rosetta: \(rosetta)
        MKVToolNix: \(toolPath)
        MKVToolNix version: \(toolVersion)
        Settings: \(environment.settings)
        """
    }

    /// Header, a blank line, then the log. Home-folder paths in either part become `~`.
    public static func document(
        environment: DebugEnvironment,
        logText: String,
        homeDirectory: String
    ) -> String {
        var text = header(for: environment)
        text += "\n\n"
        text += logText
        if !text.hasSuffix("\n") {
            text += "\n"
        }
        return PathRedaction.redact(text, homeDirectory: homeDirectory)
    }
}

public enum DebugLogFormatting {
    public static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        let milliseconds = min(999, max(0, (parts.nanosecond ?? 0) / 1_000_000))
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d.%03d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0,
            milliseconds
        )
    }

    public static func duration(since start: Date, until end: Date = Date()) -> String {
        let seconds = max(0, end.timeIntervalSince(start))
        let number = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), seconds)
        return number + "s"
    }

    public static func line(_ entry: DebugLogLine, timeZone: TimeZone) -> String {
        let level = entry.isError ? "error" : "info"
        return "\(stamp(entry.date, timeZone: timeZone)) [\(entry.category.rawValue)] \(level) \(entry.message)"
    }
}

/// Process-wide log. Until `configure` is called, recording does nothing.
///
/// The Mac app points this at `~/Library/Logs/PGS2SRT/` and mirrors each line
/// to `os.Logger`. Subtitle text and OCR output are not passed in.
public final class DebugLog: @unchecked Sendable {
    public static let shared = DebugLog()

    private let lock = NSLock()
    private var store: RollingLogStore?
    private var mirror: (@Sendable (DebugLogLine) -> Void)?
    private var homeDirectory: String
    private var timeZone: TimeZone

    public init(homeDirectory: String = NSHomeDirectory(), timeZone: TimeZone = .current) {
        self.homeDirectory = homeDirectory
        self.timeZone = timeZone
    }

    /// `~/Library/Logs/PGS2SRT/`
    public static var libraryLogsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("PGS2SRT", isDirectory: true)
    }

    public func configure(
        directory: URL,
        maxTotalBytes: Int = RollingLogStore.defaultMaxTotalBytes,
        fileCount: Int = RollingLogStore.defaultFileCount,
        homeDirectory: String? = nil,
        timeZone: TimeZone? = nil,
        mirror: (@Sendable (DebugLogLine) -> Void)? = nil
    ) {
        lock.lock()
        if let homeDirectory {
            self.homeDirectory = homeDirectory
        }
        if let timeZone {
            self.timeZone = timeZone
        }
        self.mirror = mirror
        store = RollingLogStore(directory: directory, maxTotalBytes: maxTotalBytes, fileCount: fileCount)
        lock.unlock()
    }

    /// Forgets the file and the mirror. Used so a test can put the shared log back.
    public func reset() {
        lock.lock()
        store = nil
        mirror = nil
        lock.unlock()
    }

    public func record(
        _ category: DebugLogCategory,
        _ message: String,
        isError: Bool = false,
        date: Date = Date()
    ) {
        lock.lock()
        let store = self.store
        let mirror = self.mirror
        let home = homeDirectory
        let zone = timeZone
        lock.unlock()
        guard store != nil || mirror != nil else { return }
        let redacted = PathRedaction.redact(message, homeDirectory: home)
        let entry = DebugLogLine(date: date, category: category, message: redacted, isError: isError)
        store?.append(DebugLogFormatting.line(entry, timeZone: zone))
        mirror?(entry)
    }

    public func recentText() -> String {
        lock.lock()
        let store = self.store
        lock.unlock()
        return store?.combinedText() ?? ""
    }
}

extension ConversionPreferences {
    /// One line for the debug log. A folder path is still full here; the log shortens the home folder.
    public var logDescription: String {
        let place: String
        switch placement {
        case .nextToSource:
            place = "next to the source file"
        case let .folder(path):
            place = path.isEmpty ? "a folder that has not been chosen" : "folder \(path)"
        }
        let existing: String
        switch existingFile {
        case .overwrite:
            existing = "overwrite"
        case .addNumber:
            existing = "add a number"
        case .skip:
            existing = "skip"
        }
        let italics = experimentalItalics ? "on" : "off"
        let choose = chooseMKVTrack ? "on" : "off"
        return "language \(language), save \(place), if the .srt exists \(existing), \(concurrency) pictures at a time, italics \(italics), choose MKV track \(choose)"
    }
}
