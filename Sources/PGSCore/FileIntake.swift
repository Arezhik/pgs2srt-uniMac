import Foundation

/// How the window looks at files and folders that were dropped or opened.
public struct DirectoryListing: Sendable {
    public var isDirectory: @Sendable (String) -> Bool
    /// Names inside a directory. Each entry is a full path. Throw when the folder cannot be read.
    public var children: @Sendable (String) throws -> [String]
    /// A stable identity so a symbolic link back to a parent does not loop.
    public var identity: @Sendable (String) -> String

    public init(
        isDirectory: @escaping @Sendable (String) -> Bool,
        children: @escaping @Sendable (String) throws -> [String],
        identity: @escaping @Sendable (String) -> String = { $0 }
    ) {
        self.isDirectory = isDirectory
        self.children = children
        self.identity = identity
    }

    public static let live: DirectoryListing = DirectoryListing(
        isDirectory: { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        },
        children: { path in
            let names = try FileManager.default.contentsOfDirectory(atPath: path)
            return names
                .filter { !$0.hasPrefix(".") }
                .map { (path as NSString).appendingPathComponent($0) }
        },
        identity: { path in
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
    )
}

/// A file or folder the person dropped that is not turned into an `.srt`.
public enum IntakeNotice: Equatable, Sendable {
    case mkv(path: String)
    case notSubtitle(path: String)
    case noSubtitles(folderName: String)
    case unreadableFolder(folderName: String)

    public var message: String {
        switch self {
        case .mkv:
            return "MKV support is coming."
        case let .notSubtitle(path):
            return "\(FileIntake.lastComponent(path)) is not a .sup subtitle file, so it was skipped."
        case let .noSubtitles(folderName):
            return "No .sup files were found in \(folderName)."
        case let .unreadableFolder(folderName):
            return "Could not look inside \(folderName)."
        }
    }

    public var path: String? {
        switch self {
        case let .mkv(path), let .notSubtitle(path):
            return path
        case .noSubtitles, .unreadableFolder:
            return nil
        }
    }

    /// File-shaped notices become a row. Folder-shaped notices become a banner.
    public var isFile: Bool {
        switch self {
        case .mkv, .notSubtitle: return true
        case .noSubtitles, .unreadableFolder: return false
        }
    }
}

/// `.sup` files to convert, plus polite notes for everything else.
public struct IntakeResult: Equatable, Sendable {
    public var supPaths: [String]
    public var notices: [IntakeNotice]

    public init(supPaths: [String], notices: [IntakeNotice]) {
        self.supPaths = supPaths
        self.notices = notices
    }
}

/// Sorts dropped paths into subtitle files, folders of subtitle files, and notes.
public enum FileIntake {
    public static func collect(paths: [String], listing: DirectoryListing) -> IntakeResult {
        var supPaths: [String] = []
        var notices: [IntakeNotice] = []
        var seenSup: Set<String> = []
        var seenDirectories: Set<String> = []
        for path in paths {
            let cleaned = trimTrailingSlash(path)
            if cleaned.isEmpty { continue }
            if listing.isDirectory(cleaned) {
                let before = supPaths.count
                let seenBefore = seenDirectories.contains(listing.identity(cleaned))
                walk(
                    cleaned,
                    listing: listing,
                    supPaths: &supPaths,
                    seenSup: &seenSup,
                    seenDirectories: &seenDirectories,
                    notices: &notices
                )
                let unreadable = notices.contains { notice in
                    if case let .unreadableFolder(name) = notice { return name == lastComponent(cleaned) }
                    return false
                }
                if !seenBefore && supPaths.count == before && !unreadable {
                    notices.append(.noSubtitles(folderName: lastComponent(cleaned)))
                }
            } else {
                classifyFile(cleaned, supPaths: &supPaths, seenSup: &seenSup, notices: &notices)
            }
        }
        return IntakeResult(supPaths: supPaths, notices: notices)
    }

    private static func walk(
        _ directory: String,
        listing: DirectoryListing,
        supPaths: inout [String],
        seenSup: inout Set<String>,
        seenDirectories: inout Set<String>,
        notices: inout [IntakeNotice]
    ) {
        let key = listing.identity(directory)
        if seenDirectories.contains(key) { return }
        seenDirectories.insert(key)
        let children: [String]
        do {
            children = try listing.children(directory)
        } catch {
            notices.append(.unreadableFolder(folderName: lastComponent(directory)))
            return
        }
        for child in children {
            let cleaned = trimTrailingSlash(child)
            if listing.isDirectory(cleaned) {
                walk(
                    cleaned,
                    listing: listing,
                    supPaths: &supPaths,
                    seenSup: &seenSup,
                    seenDirectories: &seenDirectories,
                    notices: &notices
                )
            } else if isSup(cleaned) {
                appendSup(cleaned, supPaths: &supPaths, seenSup: &seenSup)
            }
        }
    }

    private static func classifyFile(
        _ path: String,
        supPaths: inout [String],
        seenSup: inout Set<String>,
        notices: inout [IntakeNotice]
    ) {
        if isSup(path) {
            appendSup(path, supPaths: &supPaths, seenSup: &seenSup)
        } else if isMkv(path) {
            notices.append(.mkv(path: path))
        } else {
            notices.append(.notSubtitle(path: path))
        }
    }

    private static func appendSup(_ path: String, supPaths: inout [String], seenSup: inout Set<String>) {
        if seenSup.insert(path).inserted {
            supPaths.append(path)
        }
    }

    static func isSup(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "sup"
    }

    static func isMkv(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "mkv"
    }

    static func lastComponent(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func trimTrailingSlash(_ path: String) -> String {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
