import Foundation

/// One piece of text an OCR engine found in a subtitle image.
///
/// `top` and `left` are pixels in the image that was recognized. Zero is the
/// top-left. The transcription pipeline uses them to put lines in reading order.
/// An engine that only has a finished string can leave `lines` empty and put the
/// whole cue in `OCRResult.text`.
public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    public var confidence: Double?
    public var isItalic: Bool
    public var top: Int
    public var left: Int
    public var height: Int

    public init(
        text: String,
        confidence: Double? = nil,
        isItalic: Bool = false,
        top: Int,
        left: Int,
        height: Int
    ) {
        self.text = text
        self.confidence = confidence
        self.isItalic = isItalic
        self.top = top
        self.left = left
        self.height = height
    }
}

/// Text recognized from one subtitle image. `confidence` is 0...1 when the engine provides it.
public struct OCRResult: Equatable, Sendable {
    public var text: String
    public var confidence: Double?
    /// Separate lines or words, with positions. Empty when the engine only returned `text`.
    public var lines: [RecognizedLine]

    public init(text: String, confidence: Double? = nil, lines: [RecognizedLine] = []) {
        self.text = text
        self.confidence = confidence
        self.lines = lines
    }
}

/// OCR backend. PGSCore does not recognize text itself.
///
/// A Mac build plugs in Apple Vision through the VisionOCR module. A Windows
/// build can conform to the same protocol later. Both can share the image
/// preparation, cleanup, and `TranscriptionPipeline` in this module.
public protocol SubtitleRecognizing: Sendable {
    /// `languages` uses BCP-47 tags such as "en-US". An empty list lets the engine choose.
    func recognize(image: SubtitleImage, languages: [String]) async throws -> OCRResult
}

public extension SubtitleRecognizing {
    /// Recognizes each cue, in order, and keeps the decoded timestamps.
    ///
    /// This is the simple one-at-a-time helper. It stops at the first error and
    /// does not clean text or fill in failed cues. `TranscriptionPipeline` is the
    /// batch path: it runs several cues at once, reports progress, can be
    /// cancelled, and writes a visible note when a cue comes back empty.
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
