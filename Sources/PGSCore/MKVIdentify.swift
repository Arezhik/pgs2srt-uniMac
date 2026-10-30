import Foundation

/// One PGS subtitle track inside an MKV, as `mkvmerge -J` describes it.
public struct PGSSubtitleTrack: Equatable, Sendable, Identifiable {
    /// Track id passed to `mkvextract`.
    public var id: Int
    /// Number stored on the track. Falls back to `id` when the file omits it.
    public var number: Int
    /// Matroska language code, such as `eng`. Empty when the file has none.
    public var language: String
    /// IETF language tag, such as `en`. Empty when the file has none.
    public var languageIETF: String
    public var name: String
    public var forced: Bool
    public var isDefault: Bool

    public init(
        id: Int,
        number: Int,
        language: String,
        languageIETF: String,
        name: String,
        forced: Bool,
        isDefault: Bool
    ) {
        self.id = id
        self.number = number
        self.language = language
        self.languageIETF = languageIETF
        self.name = name
        self.forced = forced
        self.isDefault = isDefault
    }

    /// `eng` / `en`, including `en-US` and the IETF tag.
    public var isEnglish: Bool {
        Self.isEnglishLanguage(language) || Self.isEnglishLanguage(languageIETF)
    }

    /// A short label for the track list. English is spelled out. Anything else keeps the code from the file.
    public var displayLanguage: String {
        if isEnglish { return "English" }
        let ietf = languageIETF.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ietf.isEmpty, !Self.isUndetermined(ietf) { return ietf }
        let code = language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !code.isEmpty, !Self.isUndetermined(code) { return code }
        return "Unknown"
    }

    static func isEnglishLanguage(_ value: String) -> Bool {
        let primary = primarySubtag(value)
        return primary == "en" || primary == "eng"
    }

    private static func isUndetermined(_ value: String) -> Bool {
        let primary = primarySubtag(value)
        return primary == "und" || primary == "undetermined"
    }

    private static func primarySubtag(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return "" }
        let separators = CharacterSet(charactersIn: "-_")
        return trimmed.components(separatedBy: separators).first ?? trimmed
    }
}

/// What the person picked in the per-file track sheet.
public enum MKVTrackChoice: Equatable, Sendable {
    case convert(trackID: Int)
    case skip
    case cancel
}

/// Sentences the queue shows for an MKV that is not converted.
public enum MKVCopy {
    public static let downloadURL = "https://mkvtoolnix.download"
    public static let needsToolNix = "MKVToolNix is needed to convert this MKV. Download it from \(downloadURL) and try again."
    public static let noPGS = "No PGS subtitles in this MKV."
    public static let skippedTrack = "This MKV was skipped."
}

/// Reads `mkvmerge -J` JSON and picks the PGS track to extract.
public enum MKVIdentify {
    public static let pgsCodecID = "S_HDMV/PGS"

    /// PGS subtitle tracks, in the order `mkvmerge` listed them.
    public static func tracks(in data: Data) throws -> [PGSSubtitleTrack] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MKVFailure.unreadableTracks
        }
        guard let root = object as? [String: Any] else {
            throw MKVFailure.unreadableTracks
        }
        let rawTracks = root["tracks"] as? [Any] ?? []
        var tracks: [PGSSubtitleTrack] = []
        for entry in rawTracks {
            guard let raw = entry as? [String: Any] else { continue }
            guard let id = intValue(raw["id"]) else { continue }
            let properties = raw["properties"] as? [String: Any] ?? [:]
            let codecID = stringValue(properties["codec_id"])
            let codec = stringValue(raw["codec"])
            guard codecID == pgsCodecID || codec == pgsCodecID else { continue }
            let number = intValue(properties["number"]) ?? id
            tracks.append(PGSSubtitleTrack(
                id: id,
                number: number,
                language: stringValue(properties["language"]),
                languageIETF: stringValue(properties["language_ietf"]),
                name: stringValue(properties["track_name"]),
                forced: boolValue(properties["forced_track"]),
                isDefault: boolValue(properties["default_track"])
            ))
        }
        return tracks
    }

    /// The first English PGS track, or the first PGS track when none is English.
    public static func preferredTrack(in tracks: [PGSSubtitleTrack]) -> PGSSubtitleTrack? {
        tracks.first(where: \.isEnglish) ?? tracks.first
    }

    private static func stringValue(_ value: Any?) -> String {
        guard let string = value as? String else { return "" }
        return string
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let int = value as? Int { return int != 0 }
        if let string = value as? String {
            let lowered = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lowered == "true" || lowered == "yes" || lowered == "1"
        }
        return false
    }
}
