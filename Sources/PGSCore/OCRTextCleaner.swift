import Foundation

/// Tidies a string that came back from OCR before it is written to an SRT file.
///
/// The fixes are deliberately small. A letter inside a real word is left alone,
/// so "dollar" and "Illinois" stay as they are. The English pronoun fixes turn
/// on for English and stay off for other languages.
public struct OCRTextCleaner: Equatable, Sendable {
    /// A lone "l", and a few whole words that are really "I", "It", "If", or "I'm".
    public var fixEnglishPronounI: Bool

    public init(fixEnglishPronounI: Bool = true) {
        self.fixEnglishPronounI = fixEnglishPronounI
    }

    /// Cleans a whole cue. Each line is cleaned on its own. Lines that are only
    /// noise are removed. A line that is "?", "!", or "..." is kept.
    public func clean(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { cleanLine(String($0)) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Cleans one line. A newline inside the line is treated as a space.
    public func cleanLine(_ line: String) -> String {
        var text = line
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        text = text.replacingOccurrences(of: "\u{2007}", with: " ")
        text = text.replacingOccurrences(of: "\u{202F}", with: " ")
        text = text.replacingOccurrences(of: "\u{200B}", with: "")
        text = text.replacingOccurrences(of: "\u{200C}", with: "")
        text = text.replacingOccurrences(of: "\u{200D}", with: "")
        text = text.replacingOccurrences(of: "\u{FEFF}", with: "")
        text = text.replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(of: "\r", with: " ")
        text = text.replacingOccurrences(of: "\u{2019}", with: "'")
        text = text.replacingOccurrences(of: "\u{2018}", with: "'")
        // A vertical bar is a common misread of the letter I. Other languages
        // do not get that guess; the bar is dropped as stray marks instead.
        if fixEnglishPronounI {
            text = text.replacingOccurrences(of: "|", with: "I")
            text = text.replacingOccurrences(of: "¦", with: "I")
            text = text.replacingOccurrences(of: "∣", with: "I")
        } else {
            text = text.replacingOccurrences(of: "|", with: "")
            text = text.replacingOccurrences(of: "¦", with: "")
            text = text.replacingOccurrences(of: "∣", with: "")
        }
        text = collapseWhitespaceAndPunctuation(text)
        text = trimStrayEdges(text)
        if fixEnglishPronounI {
            text = replaceEnglishPronouns(text)
        }
        text = text.trimmingCharacters(in: .whitespaces)
        if !isMeaningful(text) { return "" }
        return text
    }

    /// True when the tag list includes English, or when the list is empty.
    /// An empty list means the engine falls back to English.
    public static func usesEnglish(_ languages: [String]) -> Bool {
        if languages.isEmpty { return true }
        return languages.contains { tag in
            let lower = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lower == "en" || lower.hasPrefix("en-") || lower.hasPrefix("en_")
        }
    }

    private func collapseWhitespaceAndPunctuation(_ text: String) -> String {
        var output = ""
        var pendingSpace = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == " " || character == "\t" {
                if !output.isEmpty { pendingSpace = true }
                index = text.index(after: index)
                continue
            }
            if character == "'" && pendingSpace {
                pendingSpace = false
            }
            if pendingSpace {
                let skipSpace = ",.;:!?".contains(character) || character == ")"
                if !skipSpace { output.append(" ") }
                pendingSpace = false
            }
            output.append(character)
            if character == "(" {
                var next = text.index(after: index)
                while next < text.endIndex && (text[next] == " " || text[next] == "\t") {
                    next = text.index(after: next)
                }
                index = next
                continue
            }
            index = text.index(after: index)
        }
        return output
    }

    private func trimStrayEdges(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespaces)
        let junk = CharacterSet(charactersIn: "_~*•·●◦▪■□►▸")
        while let first = text.unicodeScalars.first, junk.contains(first) {
            text.unicodeScalars.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        if !text.hasPrefix("...") && !text.hasPrefix("…"), let first = text.first, ",.;:".contains(first) {
            let rest = text.dropFirst()
            if let next = rest.first, next.isLetter || next.isNumber {
                text = String(rest).trimmingCharacters(in: .whitespaces)
            }
        }
        while let last = text.unicodeScalars.last, junk.contains(last) {
            text.unicodeScalars.removeLast()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    private func replaceEnglishPronouns(_ text: String) -> String {
        var result = ""
        var word = ""
        func flushWord() {
            switch word {
            case "l":
                result += "I"
            case "lt":
                result += "It"
            case "lf":
                result += "If"
            case "lm":
                result += "I'm"
            default:
                if word.hasPrefix("l'") {
                    let contraction = String(word.dropFirst(2)).lowercased()
                    if ["m", "ll", "ve", "d"].contains(contraction) {
                        result += "I'" + contraction
                    } else {
                        result += word
                    }
                } else {
                    result += word
                }
            }
            word = ""
        }
        for character in text {
            if character.isLetter || character == "'" {
                word.append(character)
            } else {
                flushWord()
                result.append(character)
            }
        }
        flushWord()
        return result
    }

    private func isMeaningful(_ text: String) -> Bool {
        if text.isEmpty { return false }
        if text.contains(where: { $0.isLetter || $0.isNumber }) { return true }
        switch text {
        case "?", "!", "...", "…", "—", "–", "-", "--", "---":
            return true
        default:
            return false
        }
    }
}
