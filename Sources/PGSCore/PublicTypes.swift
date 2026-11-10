import Foundation

/// Version of the cross-platform subtitle core.
public enum PGSCoreInfo {
    public static let version = "0.2.1"
}

/// Straight (non-premultiplied) 8-bit color.
public struct RGBA: Equatable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

/// Blu-ray PGS palettes store limited-range YCbCr. HD frames use BT.709; SD frames use BT.601.
public enum ColorMatrix: String, Equatable, Sendable, CustomStringConvertible {
    case bt601
    case bt709

    /// Height above 576 (anything larger than PAL SD) selects BT.709. SD selects BT.601.
    public static func automatic(videoHeight: Int) -> ColorMatrix {
        videoHeight > 576 ? .bt709 : .bt601
    }

    public var description: String {
        switch self {
        case .bt601: return "BT.601"
        case .bt709: return "BT.709"
        }
    }
}

/// One composed subtitle bitmap, cropped to the area the objects actually cover.
public struct SubtitleImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// Row-major straight RGBA, `width * height * 4` bytes.
    public var rgba: [UInt8]
    /// Left edge of this bitmap on the video frame.
    public var originX: Int
    /// Top edge of this bitmap on the video frame.
    public var originY: Int
    public var videoWidth: Int
    public var videoHeight: Int

    public init(
        width: Int,
        height: Int,
        rgba: [UInt8],
        originX: Int,
        originY: Int,
        videoWidth: Int,
        videoHeight: Int
    ) {
        precondition(width >= 0 && height >= 0, "Image dimensions must be non-negative")
        precondition(rgba.count == width * height * 4, "RGBA buffer size must be width * height * 4")
        self.width = width
        self.height = height
        self.rgba = rgba
        self.originX = originX
        self.originY = originY
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
    }

    public func color(x: Int, y: Int) -> RGBA {
        precondition(x >= 0 && y >= 0 && x < width && y < height, "Pixel is outside the image")
        let i = (y * width + x) * 4
        return RGBA(r: rgba[i], g: rgba[i + 1], b: rgba[i + 2], a: rgba[i + 3])
    }
}

/// Why a cue's end timestamp was chosen.
public enum CueEndReason: Equatable, Sendable, CustomStringConvertible {
    /// A later display set contained no composition objects.
    case clearingDisplaySet
    /// A new epoch started, which discards the previous graphic.
    case epochStart
    /// A later display set drew a different image before the screen was cleared.
    case replaced
    /// The file ended without a clearing display set. `endPTS` equals `startPTS`.
    case endOfFile

    public var description: String {
        switch self {
        case .clearingDisplaySet: return "clearing display set"
        case .epochStart: return "epoch start"
        case .replaced: return "replaced"
        case .endOfFile: return "end of file"
        }
    }
}

/// A decoded subtitle image and the time it is on screen.
///
/// Times are 90 kHz presentation timestamps from the .sup file.
/// The end time is the next display set that clears the screen. A different
/// image, or a new epoch, also closes the current cue so nothing is lost.
public struct SubtitleCue: Equatable, Sendable {
    public var startPTS: UInt32
    public var endPTS: UInt32
    public var image: SubtitleImage
    public var forced: Bool
    public var endReason: CueEndReason

    public init(
        startPTS: UInt32,
        endPTS: UInt32,
        image: SubtitleImage,
        forced: Bool,
        endReason: CueEndReason
    ) {
        self.startPTS = startPTS
        self.endPTS = endPTS
        self.image = image
        self.forced = forced
        self.endReason = endReason
    }
}

/// Reads a .sup file into timed subtitle images. No OCR.
///
/// A cancelled task stops between segments and between pictures. The check is
/// a flag read, so a conversion that is not cancelled does the same work as before.
public struct PGSDecoder: Sendable {
    /// When nil, BT.709 is used for video heights above 576 and BT.601 otherwise.
    public var colorMatrix: ColorMatrix?
    /// Called before decoding and between segments and pictures.
    /// The default stops when the current task is cancelled.
    var cancellationCheck: @Sendable () throws -> Void

    public init(colorMatrix: ColorMatrix? = nil) {
        self.colorMatrix = colorMatrix
        self.cancellationCheck = { try Task.checkCancellation() }
    }

    public func decode(_ data: Data) throws -> [SubtitleCue] {
        try cancellationCheck()
        let sets = try SUPParser.parse(data, cancellationCheck: cancellationCheck)
        return try DisplaySetComposer(colorMatrix: colorMatrix).compose(
            sets,
            cancellationCheck: cancellationCheck
        )
    }
}
