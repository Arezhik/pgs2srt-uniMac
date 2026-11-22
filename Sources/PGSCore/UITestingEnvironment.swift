import Foundation

/// Reads optional `UITEST_*` folder paths from a process environment.
/// A path is used only when it exists and is a directory. Missing, empty, or
/// non-directory values are ignored. Tests launch the app with `--uitesting`
/// and these variables so folders can be set without an open panel.
public enum UITestingEnvironment: Sendable {
    /// The directory at `key`, if that environment value is a real folder.
    public static func directory(
        named key: String,
        from environment: [String: String],
        directoryExists: (String) -> Bool
    ) -> URL? {
        guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        guard directoryExists(raw) else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }
}
