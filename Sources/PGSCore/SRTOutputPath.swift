import Foundation

/// Where one source file should be written, or why it should not be.
public enum OutputDestination: Equatable, Sendable {
    case write(String)
    /// The `.srt` name is already on disk.
    case skipBecauseExists(String)
    /// An earlier file in this batch is already going to that name.
    case skipBecauseReserved(String)
    case reject(String)
}

/// Picks the `.srt` path for one source file.
///
/// A name already claimed by another file in the same batch counts as taken,
/// so two `Movie.sup` files dropped into one folder do not overwrite each other
/// even when the setting is Overwrite. Overwrite still replaces a file that
/// was already on disk before this batch.
public enum SRTOutputPath {
    public static func plan(
        sourcePath: String,
        preferences: ConversionPreferences,
        fileExists: (String) -> Bool,
        directoryExists: (String) -> Bool,
        reserved: Set<String> = []
    ) -> OutputDestination {
        let preferences = preferences.normalized
        let base: String
        switch preferences.placement {
        case .nextToSource:
            base = ConversionCommand.defaultOutputPath(for: sourcePath)
        case let .folder(folder):
            if folder.isEmpty {
                return .reject("Choose an output folder in Settings, or save next to the source file.")
            }
            if !directoryExists(folder) {
                return .reject("The output folder is missing. Choose it again in Settings.")
            }
            let filename = (ConversionCommand.defaultOutputPath(for: sourcePath) as NSString).lastPathComponent
            base = (folder as NSString).appendingPathComponent(filename)
        }

        switch preferences.existingFile {
        case .overwrite:
            if reserved.contains(base) {
                return firstNumbered(base: base, fileExists: fileExists, reserved: reserved)
            }
            return .write(base)
        case .addNumber:
            if !fileExists(base) && !reserved.contains(base) {
                return .write(base)
            }
            return firstNumbered(base: base, fileExists: fileExists, reserved: reserved)
        case .skip:
            if reserved.contains(base) {
                return .skipBecauseReserved(base)
            }
            if fileExists(base) {
                return .skipBecauseExists(base)
            }
            return .write(base)
        }
    }

    /// `Movie.srt` with number 2 is `Movie 2.srt` in the same folder.
    public static func numbered(_ base: String, number: Int) -> String {
        if number <= 1 { return base }
        let path = base as NSString
        let ext = path.pathExtension
        let stem = (path.lastPathComponent as NSString).deletingPathExtension
        let name = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
        let directory = path.deletingLastPathComponent
        if directory.isEmpty {
            return name
        }
        return (directory as NSString).appendingPathComponent(name)
    }

    private static func firstNumbered(
        base: String,
        fileExists: (String) -> Bool,
        reserved: Set<String>
    ) -> OutputDestination {
        for number in 2...999 {
            let candidate = numbered(base, number: number)
            if !fileExists(candidate) && !reserved.contains(candidate) {
                return .write(candidate)
            }
        }
        let name = (base as NSString).lastPathComponent
        return .reject("Every numbered name for \(name) is already taken.")
    }
}

/// A sentence a person can read. Decoder errors keep their own wording.
public enum ConversionFailureText {
    public static let generic = "Something went wrong while converting this file."

    public static func message(for error: Error) -> String {
        if error is CancellationError { return "Cancelled." }
        if let localized = error as? LocalizedError {
            let text = localized.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { return text }
        }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain || cocoa.domain == NSPOSIXErrorDomain || cocoa.domain == NSURLErrorDomain {
            let text = cocoa.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return generic
    }
}
