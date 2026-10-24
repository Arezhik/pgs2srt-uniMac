import Foundation

/// Text recognized from one subtitle image. `confidence` is 0...1 when the engine provides it.
public struct OCRResult: Equatable, Sendable {
    public var text: String
    public var confidence: Double?

    public init(text: String, confidence: Double? = nil) {
        self.text = text
        self.confidence = confidence
    }
}

/// OCR backend for a later platform-specific engine (Apple Vision on macOS).
///
/// This module does not recognize text. A conforming type receives composed
/// RGBA images and returns the string that should be written to the SRT file.
public protocol SubtitleRecognizing: Sendable {
    /// `languages` uses BCP-47 tags such as "en-US". An empty list lets the engine choose.
    func recognize(image: SubtitleImage, languages: [String]) async throws -> OCRResult
}

public extension SubtitleRecognizing {
    /// Runs recognition on each cue, in order, and keeps the decoded timestamps.
    func transcribe(_ cues: [SubtitleCue], languages: [String]) async throws -> [SRTCue] {
        var results: [SRTCue] = []
        results.reserveCapacity(cues.count)
        for cue in cues {
            let recognized = try await recognize(image: cue.image, languages: languages)
            results.append(SRTCue(startPTS: cue.startPTS, endPTS: cue.endPTS, text: recognized.text))
        }
        return results
    }
}
