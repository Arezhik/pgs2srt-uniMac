import Foundation
import PGSCore

/// Launch hooks for XCUITest. Active only when the process was started with
/// `--uitesting`. Settings go to an isolated defaults suite that is cleared on
/// every launch, and optional `UITEST_*` directories are applied as if the
/// person had opened or chosen them. The real `UserDefaults.standard` domain
/// is never read or written in this mode.
enum UITestingLaunch {
    static let argument = "--uitesting"
    static let suiteName = "com.pgs2srt.PGS2SRT.uitesting"
    static let inputKey = "UITEST_INPUT_DIR"
    static let outputKey = "UITEST_OUTPUT_DIR"

    static var isActive: Bool {
        CommandLine.arguments.contains(argument)
    }

    /// Isolated suite while testing, otherwise the ordinary app defaults.
    static let defaults: UserDefaults = makeDefaults()

    static func prepare() {
        _ = defaults
    }

    static func inputDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        directoryExists: (String) -> Bool = directoryExists
    ) -> URL? {
        guard isActive else { return nil }
        return UITestingEnvironment.directory(
            named: inputKey,
            from: environment,
            directoryExists: directoryExists
        )
    }

    static func outputDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        directoryExists: (String) -> Bool = directoryExists
    ) -> URL? {
        guard isActive else { return nil }
        return UITestingEnvironment.directory(
            named: outputKey,
            from: environment,
            directoryExists: directoryExists
        )
    }

    static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func makeDefaults() -> UserDefaults {
        guard isActive else { return .standard }
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        guard let store = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create the UI testing defaults suite \(suiteName)")
        }
        return store
    }
}
