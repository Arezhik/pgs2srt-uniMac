import Foundation

/// Where a converted `.srt` file is written.
public enum OutputPlacement: Equatable, Sendable {
    /// `Movie.sup` becomes `Movie.srt` in the same folder.
    case nextToSource
    /// Every file in the batch is written into this folder, using the source file's name.
    case folder(String)
}

/// What to do when the destination `.srt` is already on disk.
public enum ExistingSubtitleAction: String, Equatable, Sendable {
    /// Replace the existing file.
    case overwrite
    /// Write `Name 2.srt`, then `Name 3.srt`, and so on.
    case addNumber
    /// Leave the existing file alone and do not convert this one.
    case skip
}

/// Choices the window remembers between launches.
///
/// Italics stay off unless the person turns the experimental option on. That
/// matches the `pgs2srt --italics` flag: the lean check is the same opt-in.
public struct ConversionPreferences: Equatable, Sendable {
    public var placement: OutputPlacement
    public var language: String
    public var existingFile: ExistingSubtitleAction
    public var concurrency: Int
    public var experimentalItalics: Bool
    /// When on, each MKV asks which PGS track to extract. Off uses English, or the first PGS track.
    public var chooseMKVTrack: Bool
    /// `.immediately` writes the `.srt` when conversion finishes. `.afterReview` waits for Save.
    public var saveTiming: SaveTiming

    public static let defaultLanguage = "en-US"
    public static let defaultConcurrency = 4
    public static let minimumConcurrency = 1
    public static let maximumConcurrency = 32

    public init(
        placement: OutputPlacement,
        language: String,
        existingFile: ExistingSubtitleAction,
        concurrency: Int,
        experimentalItalics: Bool,
        chooseMKVTrack: Bool = false,
        saveTiming: SaveTiming = .immediately
    ) {
        self.placement = placement
        self.language = language
        self.existingFile = existingFile
        self.concurrency = concurrency
        self.experimentalItalics = experimentalItalics
        self.chooseMKVTrack = chooseMKVTrack
        self.saveTiming = saveTiming
    }

    public static let `default` = ConversionPreferences(
        placement: .nextToSource,
        language: defaultLanguage,
        existingFile: .overwrite,
        concurrency: defaultConcurrency,
        experimentalItalics: false,
        chooseMKVTrack: false,
        saveTiming: .immediately
    )

    /// Language, concurrency, and folder text the queue can use without further checks.
    public var normalized: ConversionPreferences {
        var copy = self
        let trimmedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.language = trimmedLanguage.isEmpty ? Self.defaultLanguage : trimmedLanguage
        copy.concurrency = min(Self.maximumConcurrency, max(Self.minimumConcurrency, concurrency))
        if case let .folder(path) = placement {
            copy.placement = .folder(path.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return copy
    }
}

/// UserDefaults keys shared by the window and the tests.
public enum ConversionPreferenceKey {
    public static let placement = "outputPlacement"
    public static let folder = "outputFolder"
    public static let language = "recognitionLanguage"
    public static let existingFile = "existingFileAction"
    public static let concurrency = "concurrency"
    public static let italics = "experimentalItalics"
    public static let chooseMKVTrack = "chooseMKVTrack"
    public static let saveTiming = "saveTiming"

    public static let placementNextToSource = "nextToSource"
    public static let placementFolder = "folder"
}

/// Reads and writes `ConversionPreferences` with UserDefaults.
public enum ConversionPreferenceStore {
    public static func load(from defaults: UserDefaults) -> ConversionPreferences {
        let preferences = read(from: defaults).normalized
        let raw = read(from: defaults)
        if preferences != raw {
            save(preferences, to: defaults)
        }
        return preferences
    }

    public static func save(_ preferences: ConversionPreferences, to defaults: UserDefaults) {
        let preferences = preferences.normalized
        switch preferences.placement {
        case .nextToSource:
            defaults.set(ConversionPreferenceKey.placementNextToSource, forKey: ConversionPreferenceKey.placement)
        case let .folder(path):
            defaults.set(ConversionPreferenceKey.placementFolder, forKey: ConversionPreferenceKey.placement)
            defaults.set(path, forKey: ConversionPreferenceKey.folder)
        }
        // Next to the source leaves the saved folder path alone, so switching back does not forget it.
        defaults.set(preferences.language, forKey: ConversionPreferenceKey.language)
        defaults.set(preferences.existingFile.rawValue, forKey: ConversionPreferenceKey.existingFile)
        defaults.set(preferences.concurrency, forKey: ConversionPreferenceKey.concurrency)
        defaults.set(preferences.experimentalItalics, forKey: ConversionPreferenceKey.italics)
        defaults.set(preferences.chooseMKVTrack, forKey: ConversionPreferenceKey.chooseMKVTrack)
        defaults.set(preferences.saveTiming.rawValue, forKey: ConversionPreferenceKey.saveTiming)
    }

    private static func read(from defaults: UserDefaults) -> ConversionPreferences {
        let placement: OutputPlacement
        let placementRaw = defaults.string(forKey: ConversionPreferenceKey.placement)
        if placementRaw == ConversionPreferenceKey.placementFolder {
            placement = .folder(defaults.string(forKey: ConversionPreferenceKey.folder) ?? "")
        } else {
            placement = .nextToSource
        }
        let language = defaults.string(forKey: ConversionPreferenceKey.language) ?? ConversionPreferences.defaultLanguage
        let existing = ExistingSubtitleAction(
            rawValue: defaults.string(forKey: ConversionPreferenceKey.existingFile) ?? ""
        ) ?? .overwrite
        let concurrency: Int
        if defaults.object(forKey: ConversionPreferenceKey.concurrency) == nil {
            concurrency = ConversionPreferences.defaultConcurrency
        } else {
            concurrency = defaults.integer(forKey: ConversionPreferenceKey.concurrency)
        }
        let italics = defaults.bool(forKey: ConversionPreferenceKey.italics)
        let chooseMKVTrack = defaults.bool(forKey: ConversionPreferenceKey.chooseMKVTrack)
        let saveTiming = SaveTiming(rawValue: defaults.string(forKey: ConversionPreferenceKey.saveTiming) ?? "") ?? .immediately
        return ConversionPreferences(
            placement: placement,
            language: language,
            existingFile: existing,
            concurrency: concurrency,
            experimentalItalics: italics,
            chooseMKVTrack: chooseMKVTrack,
            saveTiming: saveTiming
        )
    }
}
