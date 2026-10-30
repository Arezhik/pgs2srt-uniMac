import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Paths to the two MKVToolNix commands this app shells out to.
public struct MKVToolPaths: Equatable, Sendable {
    public var mkvmerge: String
    public var mkvextract: String

    public init(mkvmerge: String, mkvextract: String) {
        self.mkvmerge = mkvmerge
        self.mkvextract = mkvextract
    }
}

/// A failure while asking MKVToolNix about a file or pulling a track out of it.
public enum MKVFailure: Error, Equatable, LocalizedError {
    case unreadableTracks
    case extractFailed
    case couldNotStartTool

    public var errorDescription: String? {
        switch self {
        case .unreadableTracks:
            return "Could not read the subtitle tracks in this MKV."
        case .extractFailed:
            return "Could not extract the PGS subtitles from this MKV."
        case .couldNotStartTool:
            return "MKVToolNix could not be started."
        }
    }
}

/// Where `mkvmerge` and `mkvextract` are on this Mac.
public enum MKVToolNix {
    /// Looks in Homebrew's usual folders, an MKVToolNix app bundle, then `PATH`.
    /// Both tools have to be found. A partial install is treated as missing.
    public static func locate() -> MKVToolPaths? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        return locate(
            executableExists: { FileManager.default.isExecutableFile(atPath: $0) },
            applications: names,
            searchPath: ProcessInfo.processInfo.environment["PATH"] ?? ""
        )
    }

    /// `applications` is the names inside `/Applications`, such as `MKVToolNix.app`.
    public static func locate(
        executableExists: (String) -> Bool,
        applications: [String],
        searchPath: String
    ) -> MKVToolPaths? {
        let bundles = applications
            .filter { $0.hasPrefix("MKVToolNix") && $0.hasSuffix(".app") }
            .sorted()
        func find(_ name: String) -> String? {
            for path in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"] where executableExists(path) {
                return path
            }
            for bundle in bundles {
                let path = "/Applications/\(bundle)/Contents/MacOS/\(name)"
                if executableExists(path) { return path }
            }
            for directory in searchPath.split(separator: ":", omittingEmptySubsequences: true) {
                let path = (String(directory) as NSString).appendingPathComponent(name)
                if executableExists(path) { return path }
            }
            return nil
        }
        guard let mkvmerge = find("mkvmerge"), let mkvextract = find("mkvextract") else {
            return nil
        }
        return MKVToolPaths(mkvmerge: mkvmerge, mkvextract: mkvextract)
    }
}

/// One run of an external command. Cancelling the calling task terminates the process.
public struct MKVCommandResult: Equatable, Sendable {
    public var status: Int32
    public var standardOutput: Data
    public var standardError: Data

    public init(status: Int32, standardOutput: Data, standardError: Data) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum MKVCommand {
    public static func run(executable: String, arguments: [String]) async throws -> MKVCommandResult {
        let runner = CommandRunner()
        return try await withTaskCancellationHandler {
            try await runner.start(executable: executable, arguments: arguments)
        } onCancel: {
            runner.cancel()
        }
    }

    /// `mkvmerge -J <file>`. The returned data is the JSON document.
    public static func identify(tool: String, file: String) async throws -> Data {
        let result = try await run(executable: tool, arguments: ["-J", file])
        guard result.status == 0 else { throw MKVFailure.unreadableTracks }
        return result.standardOutput
    }

    /// `mkvextract <file> tracks <id>:<destination>`.
    public static func extract(tool: String, file: String, trackID: Int, destination: String) async throws {
        let result = try await run(executable: tool, arguments: [file, "tracks", "\(trackID):\(destination)"])
        guard result.status == 0, FileManager.default.fileExists(atPath: destination) else {
            throw MKVFailure.extractFailed
        }
    }
}

/// Locate, list tracks, and extract. Tests substitute their own.
public struct MKVClient: Sendable {
    public var locate: @Sendable () -> MKVToolPaths?
    public var identify: @Sendable (String, String) async throws -> Data
    public var extract: @Sendable (String, String, Int, String) async throws -> Void

    public init(
        locate: @escaping @Sendable () -> MKVToolPaths?,
        identify: @escaping @Sendable (String, String) async throws -> Data,
        extract: @escaping @Sendable (String, String, Int, String) async throws -> Void
    ) {
        self.locate = locate
        self.identify = identify
        self.extract = extract
    }

    public static let live = MKVClient(
        locate: { MKVToolNix.locate() },
        identify: { tool, file in
            try await MKVCommand.identify(tool: tool, file: file)
        },
        extract: { tool, file, trackID, destination in
            try await MKVCommand.extract(tool: tool, file: file, trackID: trackID, destination: destination)
        }
    )

    /// No MKVToolNix. An MKV row is skipped instead of converted.
    public static let unavailable = MKVClient(
        locate: { nil },
        identify: { _, _ in throw MKVFailure.couldNotStartTool },
        extract: { _, _, _, _ in throw MKVFailure.couldNotStartTool }
    )
}

/// Owns the running `Process` so a cancel from another task can terminate it.
private final class CommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        guard let process else { return }
        stop(process)
    }

    func start(executable: String, arguments: [String]) async throws -> MKVCommandResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MKVCommandResult, Error>) in
            let resume = ResumeBox(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try self.blocking(executable: executable, arguments: arguments) }
                resume.resume(result)
            }
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Stores the process. Returns false when cancel already won.
    private func adopt(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        self.process = process
        return true
    }

    /// `terminate()` is not enough on Linux when it is called off the thread that
    /// launched the tool. SIGKILL makes Cancel stop mkvmerge and mkvextract immediately.
    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        if pid > 0 {
            kill(pid, SIGKILL)
        }
    }

    private func forget() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    private func blocking(executable: String, arguments: [String]) throws -> MKVCommandResult {
        if isCancelled { throw CancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        guard adopt(process) else { throw CancellationError() }
        do {
            try process.run()
        } catch {
            forget()
            throw MKVFailure.couldNotStartTool
        }
        if isCancelled {
            stop(process)
        }
        let stdout = PipeReader(stdoutPipe.fileHandleForReading)
        let stderr = PipeReader(stderrPipe.fileHandleForReading)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdout.readToEnd()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderr.readToEnd()
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        let status = process.terminationStatus
        forget()
        if isCancelled { throw CancellationError() }
        return MKVCommandResult(status: status, standardOutput: stdout.data, standardError: stderr.data)
    }
}

/// Reads a pipe on a background thread. `Pipe` and `FileHandle` are not sendable, so they stay in here.
private final class PipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private(set) var data = Data()

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func readToEnd() {
        data = (try? handle.readToEnd()) ?? Data()
    }
}

/// Resumes a continuation once. The process thread and a failure path must not both resume it.
private final class ResumeBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
