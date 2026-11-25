import Foundation

/// `.srt` suffixes for one MKV. A single chosen track keeps `Movie.srt`.
public enum MKVOutputName {
    /// Suffix after the file stem, without a leading dot. Empty means `Movie.srt`.
    public static func suffixes(for tracks: [PGSSubtitleTrack]) -> [Int: String] {
        if tracks.count <= 1 {
            return Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, "") })
        }
        var seen: [String: Int] = [:]
        var result: [Int: String] = [:]
        for track in tracks {
            var suffix = token(for: track)
            if track.forced {
                suffix += ".forced"
            }
            let prior = seen[suffix, default: 0]
            seen[suffix] = prior + 1
            if prior > 0 {
                suffix += ".\(prior + 1)"
            }
            result[track.id] = suffix
        }
        return result
    }

    /// `Movie.en.srt` for one track. The stem is the source file name without `.mkv`.
    public static func fileName(stem: String, suffix: String) -> String {
        if suffix.isEmpty { return "\(stem).srt" }
        return "\(stem).\(suffix).srt"
    }

    /// Popover footer. One chosen track always previews the plain `.srt` name.
    public static func savesLine(stem: String, tracks: [PGSSubtitleTrack]) -> String {
        if tracks.isEmpty { return "No tracks selected" }
        let suffixes = suffixes(for: tracks)
        let names = tracks.map { fileName(stem: stem, suffix: suffixes[$0.id] ?? "") }
        switch names.count {
        case 1:
            return "1 selected · saves \(names[0])"
        case 2:
            return "2 selected · saves \(names[0]) and \(names[1])"
        default:
            let head = names.dropLast().joined(separator: ", ")
            return "\(names.count) selected · saves \(head), and \(names[names.count - 1])"
        }
    }

    public static func stem(of sourcePath: String) -> String {
        let base = (sourcePath as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        return stem.isEmpty ? base : stem
    }

    private static func token(for track: PGSSubtitleTrack) -> String {
        if let code = shortCode(track.languageIETF) { return code }
        if let code = shortCode(track.language) { return code }
        let name = sanitize(track.name)
        if !name.isEmpty { return name }
        return "und"
    }

    private static func shortCode(_ value: String) -> String? {
        let primary = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? ""
        if primary.isEmpty || primary == "und" || primary == "undetermined" { return nil }
        if primary.count == 2 { return primary }
        if let mapped = iso639[primary] { return mapped }
        return primary
    }

    private static func sanitize(_ name: String) -> String {
        var out = ""
        var dash = false
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                dash = false
            } else if !dash && !out.isEmpty {
                out.append("-")
                dash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    private static let iso639: [String: String] = [
        "eng": "en", "spa": "es", "fra": "fr", "fre": "fr",
        "deu": "de", "ger": "de", "jpn": "ja", "kor": "ko",
        "zho": "zh", "chi": "zh", "por": "pt", "ita": "it",
        "rus": "ru", "nld": "nl", "dut": "nl", "swe": "sv",
        "nor": "no", "dan": "da", "fin": "fi", "pol": "pl",
        "ces": "cs", "cze": "cs", "hun": "hu", "ron": "ro",
        "rum": "ro", "ell": "el", "gre": "el", "ara": "ar",
        "heb": "he", "hin": "hi", "tha": "th", "vie": "vi",
        "ind": "id", "tur": "tr", "ukr": "uk", "nob": "nb",
        "nno": "nn", "cat": "ca", "hrv": "hr", "srp": "sr",
        "slk": "sk", "slo": "sk", "slv": "sl", "bul": "bg",
        "est": "et", "lav": "lv", "lit": "lt", "isl": "is",
        "ice": "is", "gle": "ga"
    ]
}
