import Foundation
import PGSCore

/// Whether this build can recognize text with Apple Vision.
public enum VisionOCRAvailability {
    public static let isAvailable: Bool = {
        #if canImport(Vision)
        return true
        #else
        return false
        #endif
    }()
}

#if canImport(Vision)
import CoreGraphics
import Vision

/// Reads a decoded PGS bitmap with `VNRecognizeTextRequest`.
///
/// Recognition is accurate, language correction is on, and the language list
/// defaults to English (`en-US`) when the caller does not pass one. The bitmap
/// is prepared by `ImagePreprocessor` first (contrasting background, padding,
/// upscale). Lines come back top to bottom. A line whose ink leans right is
/// marked italic so the pipeline can wrap it in `<i>`.
public struct VisionOCR: SubtitleRecognizing {
    public var preprocessor: ImagePreprocessor

    public init(preprocessor: ImagePreprocessor = ImagePreprocessor()) {
        self.preprocessor = preprocessor
    }

    public func recognize(image: SubtitleImage, languages: [String]) async throws -> OCRResult {
        let prepared = preprocessor.prepare(image)
        if prepared.isBlank || prepared.width == 0 || prepared.height == 0 {
            return OCRResult(text: "", confidence: nil, lines: [])
        }
        let tags = languages
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let cgImage = try PreparedImageRenderer.cgImage(from: prepared)
                    let request = Self.makeRequest(languages: tags)
                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    try handler.perform([request])
                    let result = Self.result(from: request.results ?? [], prepared: prepared)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The request the recognizer performs. Tests check the level, language
    /// correction, and the English default without needing a picture.
    static func makeRequest(languages: [String]) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = false
        let tags = languages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        request.recognitionLanguages = tags.isEmpty ? ["en-US"] : tags
        return request
    }

    static func result(from observations: [VNRecognizedTextObservation], prepared: PreparedSubtitleImage) -> OCRResult {
        var lines: [RecognizedLine] = []
        var confidences: [Double] = []
        let imageWidth = max(prepared.width, 1)
        let imageHeight = max(prepared.height, 1)
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let pieces = candidate.string
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if pieces.isEmpty { continue }
            let box = observation.boundingBox
            let pixelLeft = Int((box.origin.x * CGFloat(imageWidth)).rounded())
            let pixelHeight = max(1, Int((box.height * CGFloat(imageHeight)).rounded()))
            let pixelTop = Int(((1 - box.origin.y - box.height) * CGFloat(imageHeight)).rounded())
            let sliceHeight = max(1, pixelHeight / pieces.count)
            let confidence = Double(candidate.confidence)
            confidences.append(confidence)
            for (offset, piece) in pieces.enumerated() {
                let top = pixelTop + offset * sliceHeight
                let height = offset == pieces.count - 1 ? max(1, pixelTop + pixelHeight - top) : sliceHeight
                lines.append(RecognizedLine(
                    text: piece,
                    confidence: confidence,
                    isItalic: isItalic(top: top, height: height, lines: prepared.lines),
                    top: top,
                    left: pixelLeft,
                    height: height
                ))
            }
        }
        let text = ReadingOrder.rows(from: lines)
            .map { row in row.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
        let confidence = confidences.min()
        return OCRResult(text: text, confidence: confidence, lines: lines)
    }

    static func isItalic(top: Int, height: Int, lines: [PreparedTextLine]) -> Bool {
        let bottom = top + max(height, 1)
        var bestOverlap = 0
        var italic = false
        for line in lines {
            let overlap = min(bottom, line.bottom) - max(top, line.top)
            if overlap > bestOverlap {
                bestOverlap = overlap
                italic = line.isItalic
            }
        }
        return bestOverlap > 0 && italic
    }
}

public enum VisionOCRError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case unreadableImage

    public var description: String {
        switch self {
        case .unreadableImage:
            return "The subtitle picture could not be prepared for text recognition."
        }
    }

    public var errorDescription: String? { description }
}

enum PreparedImageRenderer {
    static func cgImage(from prepared: PreparedSubtitleImage) throws -> CGImage {
        let data = Data(prepared.rgba) as CFData
        guard prepared.width > 0, prepared.height > 0, let provider = CGDataProvider(data: data) else {
            throw VisionOCRError.unreadableImage
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        guard let image = CGImage(
            width: prepared.width,
            height: prepared.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: prepared.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw VisionOCRError.unreadableImage
        }
        return image
    }
}
#endif
