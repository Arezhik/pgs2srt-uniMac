import Foundation

/// What the person chose when asked about replacing an existing `.srt`.
public enum OverwriteAnswer: Equatable, Sendable {
    case replace(applyToAll: Bool)
    case skip(applyToAll: Bool)
    /// The prompt was dismissed by Cancel. Leave the existing file alone.
    case cancel
}

/// A Replace or Skip answer that applies to the rest of this batch.
public enum RememberedOverwrite: Equatable, Sendable {
    case replace
    case skip
}

/// Whether to convert, skip, or ask before replacing a file that is already there.
public enum OverwriteResolution: Equatable, Sendable {
    /// Use this destination. Add a number and Skip never ask.
    case ready(OutputDestination)
    /// Overwrite would replace this existing file. Ask first.
    case ask(String)
}

/// Decides when Overwrite must ask, and how a remembered answer applies.
///
/// Add a number and Skip are unchanged: they never ask. A remembered answer
/// lasts for the current batch only.
public enum OverwriteConfirmation {
    public static func resolve(
        planned: OutputDestination,
        setting: ExistingSubtitleAction,
        fileExists: (String) -> Bool,
        remembered: RememberedOverwrite?
    ) -> OverwriteResolution {
        guard setting == .overwrite, case let .write(path) = planned, fileExists(path) else {
            return .ready(planned)
        }
        switch remembered {
        case .replace:
            return .ready(.write(path))
        case .skip:
            return .ready(.skipBecauseExists(path))
        case nil:
            return .ask(path)
        }
    }

    public static func remember(_ answer: OverwriteAnswer) -> RememberedOverwrite? {
        switch answer {
        case let .replace(applyToAll):
            return applyToAll ? .replace : nil
        case let .skip(applyToAll):
            return applyToAll ? .skip : nil
        case .cancel:
            return nil
        }
    }
}
