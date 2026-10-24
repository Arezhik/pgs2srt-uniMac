import Foundation

/// Failure while reading a PGS (.sup) file or writing an SRT cue list.
public enum PGSError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case emptyInput
    case truncated(offset: Int, context: String)
    case invalidMagic(offset: Int, byte0: UInt8, byte1: UInt8)
    case unknownSegmentType(offset: Int, type: UInt8)
    case invalidSegment(offset: Int, kind: String, message: String)
    case missingPresentationComposition(offset: Int)
    case duplicatePresentationComposition(offset: Int)
    case missingEnd(offset: Int)
    case incompleteObject(objectID: UInt16, offset: Int)
    case objectLengthMismatch(objectID: UInt16, expected: Int, actual: Int)
    case rleDecodingFailed(objectID: UInt16, message: String)
    case missingPalette(paletteID: UInt8)
    case missingObject(objectID: UInt16)
    case missingWindow(windowID: UInt8)
    case invalidCrop(objectID: UInt16, message: String)
    case nonMonotonicPTS(previous: UInt32, next: UInt32)

    public var description: String {
        switch self {
        case .emptyInput:
            return "The PGS file is empty."
        case let .truncated(offset, context):
            return "The PGS file is cut off at byte \(offset) while reading \(context)."
        case let .invalidMagic(offset, byte0, byte1):
            return "Expected the bytes PG at byte \(offset), found \(hexByte(byte0)) \(hexByte(byte1))."
        case let .unknownSegmentType(offset, type):
            return "Segment at byte \(offset) has unknown type \(hexByte(type)). Expected PCS (0x16), WDS (0x17), PDS (0x14), ODS (0x15), or END (0x80)."
        case let .invalidSegment(offset, kind, message):
            return "The \(kind) segment at byte \(offset) is invalid: \(message)"
        case let .missingPresentationComposition(offset):
            return "The display set starting at byte \(offset) has no presentation composition segment (PCS)."
        case let .duplicatePresentationComposition(offset):
            return "The display set starting at byte \(offset) contains more than one presentation composition segment (PCS)."
        case let .missingEnd(offset):
            return "The display set starting at byte \(offset) never reaches an END segment."
        case let .incompleteObject(objectID, offset):
            return "Object \(objectID) near byte \(offset) is missing the rest of its image (a multi-part object never finished)."
        case let .objectLengthMismatch(objectID, expected, actual):
            return "Object \(objectID) declared \(expected) bytes of image data but \(actual) bytes were present."
        case let .rleDecodingFailed(objectID, message):
            return "Object \(objectID) image data could not be decoded: \(message)"
        case let .missingPalette(paletteID):
            return "Palette \(paletteID) is used by a subtitle but was never defined."
        case let .missingObject(objectID):
            return "Object \(objectID) is placed on screen but its image was never defined."
        case let .missingWindow(windowID):
            return "Window \(windowID) is referenced by a subtitle but was never defined."
        case let .invalidCrop(objectID, message):
            return "The crop rectangle for object \(objectID) is invalid: \(message)"
        case let .nonMonotonicPTS(previous, next):
            return "Timestamps go backwards (\(previous) then \(next) at 90 kHz)."
        }
    }

    public var errorDescription: String? { description }
}

/// Failure while writing an SRT file.
public enum SRTError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case endBeforeStart(startPTS: UInt32, endPTS: UInt32)

    public var description: String {
        switch self {
        case let .endBeforeStart(startPTS, endPTS):
            return "SRT cue ends before it starts (PTS \(startPTS) → \(endPTS))."
        }
    }

    public var errorDescription: String? { description }
}

func hexByte(_ value: UInt8) -> String {
    let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]
    return "0x\(digits[Int(value >> 4)])\(digits[Int(value & 0x0F)])"
}
