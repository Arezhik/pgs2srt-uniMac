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
    case notSubtitle(path: String)
    case noSubtitles(folderName: String)
    case unreadableFolder(folderName: String)

    public var message: String {
        switch self {
        case let .notSubtitle(path):
            return "\(FileIntake.lastComponent(path)) is not a .sup or .mkv file, so it was skipped."
        case let .noSubtitles(folderName):
            return "No .sup or .mkv files were found in \(folderName)."
        case let .unreadableFolder(folderName):
            return "Could not look inside \(folderName)."
        }
    }

    public var path: String? {
        switch self {
        case let .notSubtitle(path):
            return path
        case .noSubtitles, .unreadableFolder:
            return nil
        }
    }

    /// File-shaped notices become a row. Folder-shaped notices become a banner.
    public var isFile: Bool {
        switch self {
        case .notSubtitle: return true
        case .noSubtitles, .unreadableFolder: return false
        }
    }
}

/// `.sup` and `.mkv` files to convert, plus polite notes for everything else.
public struct IntakeResult: Equatable, Sendable {
    public var sourcePaths: [String]
    public var notices: [IntakeNotice]

    public init(sourcePaths: [String], notices: [IntakeNotice]) {
        self.sourcePaths = sourcePaths
        self.notices = notices
    }
}

/// Sorts dropped paths into subtitle files, folders of subtitle files, and notes.
public enum FileIntake {
    public static func collect(paths: [String], listing: DirectoryListing) -> IntakeResult {
        var sourcePaths: [String] = []
        var notices: [IntakeNotice] = []
        var seenSources: Set<String> = []
        var seenDirectories: Set<String> = []
        for path in paths {
            let cleaned = trimTrailingSlash(path)
            if cleaned.isEmpty { continue }
            if listing.isDirectory(cleaned) {
                let before = sourcePaths.count
                let seenBefore = seenDirectories.contains(listing.identity(cleaned))
                walk(
                    cleaned,
                    listing: listing,
                    sourcePaths: &sourcePaths,
                    seenSources: &seenSources,
                    seenDirectories: &seenDirectories,
                    notices: &notices
                )
                let unreadable = notices.contains { notice in
                    if case let .unreadableFolder(name) = notice { return name == lastComponent(cleaned) }
                    return false
                }
                if !seenBefore && sourcePaths.count == before && !unreadable {
                    notices.append(.noSubtitles(folderName: lastComponent(cleaned)))
                }
            } else {
                classifyFile(cleaned, sourcePaths: &sourcePaths, seenSources: &seenSources, notices: &notices)
            }
        }
        return IntakeResult(sourcePaths: sourcePaths, notices: notices)
    }

    private static func walk(
        _ directory: String,
        listing: DirectoryListing,
        sourcePaths: inout [String],
        seenSources: inout Set<String>,
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
                    sourcePaths: &sourcePaths,
                    seenSources: &seenSources,
                    seenDirectories: &seenDirectories,
                    notices: &notices
                )
            } else if isSource(cleaned) {
                appendSource(cleaned, sourcePaths: &sourcePaths, seenSources: &seenSources)
            }
        }
    }

    private static func classifyFile(
        _ path: String,
        sourcePaths: inout [String],
        seenSources: inout Set<String>,
        notices: inout [IntakeNotice]
    ) {
        if isSource(path) {
            appendSource(path, sourcePaths: &sourcePaths, seenSources: &seenSources)
        } else {
            notices.append(.notSubtitle(path: path))
        }
    }

    private static func appendSource(_ path: String, sourcePaths: inout [String], seenSources: inout Set<String>) {
        if seenSources.insert(path).inserted {
            sourcePaths.append(path)
        }
    }

    private static func isSource(_ path: String) -> Bool {
        isSup(path) || isMkv(path)
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
