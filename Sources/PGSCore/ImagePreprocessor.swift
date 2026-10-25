import Foundation

/// One row of ink in a prepared subtitle image, in that image's pixels.
public struct PreparedTextLine: Equatable, Sendable {
    /// Inclusive top. Zero is the top of the prepared image.
    public var top: Int
    /// Exclusive bottom.
    public var bottom: Int
    public var left: Int
    /// Exclusive right edge.
    public var right: Int
    /// The ink leans to the right, which is the usual italic slant.
    public var isItalic: Bool

    public var height: Int { bottom - top }

    public init(top: Int, bottom: Int, left: Int, right: Int, isItalic: Bool) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
        self.isItalic = isItalic
    }
}

/// A subtitle bitmap turned into an opaque image an OCR engine can read.
public struct PreparedSubtitleImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// Row-major straight RGBA. Every pixel is opaque. Empty when `isBlank` is true.
    public var rgba: [UInt8]
    /// Integer scale applied after padding. 1 means the ink was already tall enough.
    public var scale: Int
    public var lines: [PreparedTextLine]
    public var background: RGBA
    /// No pixel was opaque enough to be ink.
    public var isBlank: Bool

    public init(
        width: Int,
        height: Int,
        rgba: [UInt8],
        scale: Int,
        lines: [PreparedTextLine],
        background: RGBA,
        isBlank: Bool
    ) {
        self.width = width
        self.height = height
        self.rgba = rgba
        self.scale = scale
        self.lines = lines
        self.background = background
        self.isBlank = isBlank
    }

    public static let blank = PreparedSubtitleImage(
        width: 0,
        height: 0,
        rgba: [],
        scale: 1,
        lines: [],
        background: RGBA(r: 0, g: 0, b: 0, a: 255),
        isBlank: true
    )

    public func color(x: Int, y: Int) -> RGBA {
        precondition(x >= 0 && y >= 0 && x < width && y < height, "Pixel is outside the prepared image")
        let index = (y * width + x) * 4
        return RGBA(r: rgba[index], g: rgba[index + 1], b: rgba[index + 2], a: rgba[index + 3])
    }
}

/// Turns a decoded PGS bitmap into a picture Vision (or another engine) can read.
///
/// PGS stores straight RGBA. The letters are usually light, often with a dark
/// outline, on a transparent background, and the bitmap is already cropped tight
/// to the letters. That is a poor input for a recognizer trained on documents:
///
/// - Transparent pixels are easy to treat as black, so a black outline vanishes
///   or the letter shape gets muddy.
/// - Light letters on a white page would disappear, so the background has to
///   contrast with the ink. Light ink is drawn on black. Dark ink is drawn on
///   white. A light fill with a dark outline, the usual Blu-ray look, is light
///   ink: the outline is ignored and the fill is drawn on black, so the outline
///   melts into the page and the fill stays.
/// - Text that touches the edge of the bitmap is often skipped, so the ink is
///   padded.
/// - A line only a few pixels tall is upscaled, by a whole-number factor, until
///   the ink is about 64 pixels tall. Scaling stops at 4x and also stops before
///   the picture gets wider than 4096 pixels. A line that is already tall is
///   not scaled, so it is not blurred.
/// - Rows of ink separated by a real gap become separate lines. A one-pixel gap,
///   such as the dot on an i, stays on the same line.
/// - Italics are a slant in the pixels, not a flag in the file. If the top half
///   of a line sits far enough to the right of the bottom half, the line is
///   marked italic. That guess is experimental. The SRT pipeline leaves it off
///   unless italics were requested, because upright Blu-ray type was often
///   marked italic.
public struct ImagePreprocessor: Equatable, Sendable {
    public var padding: Int
    public var minimumInkHeight: Int
    public var maximumScale: Int
    public var maximumPixelWidth: Int
    /// Alpha at or above this value counts as ink.
    public var inkAlpha: Int
    /// Ink at least this bright (0...255, Rec. 709) is treated as light text.
    public var lightInkLuminance: Int
    /// This many empty rows between ink start a new line.
    public var lineGap: Int

    public init(
        padding: Int = 16,
        minimumInkHeight: Int = 64,
        maximumScale: Int = 4,
        maximumPixelWidth: Int = 4096,
        inkAlpha: Int = 16,
        lightInkLuminance: Int = 140,
        lineGap: Int = 3
    ) {
        self.padding = max(0, padding)
        self.minimumInkHeight = max(1, minimumInkHeight)
        self.maximumScale = max(1, maximumScale)
        self.maximumPixelWidth = max(1, maximumPixelWidth)
        self.inkAlpha = min(255, max(0, inkAlpha))
        self.lightInkLuminance = min(255, max(0, lightInkLuminance))
        self.lineGap = max(1, lineGap)
    }

    public func prepare(_ image: SubtitleImage) -> PreparedSubtitleImage {
        guard image.width > 0, image.height > 0, let crop = inkBounds(of: image) else {
            return .blank
        }
        let background = backgroundColor(of: image, crop: crop)
        let composited = composite(image, crop: crop, background: background)
        let sourceLines = lineBands(of: image, crop: crop)
        let paddedWidth = crop.width + padding * 2
        let paddedHeight = crop.height + padding * 2
        var padded = [UInt8](repeating: 0, count: paddedWidth * paddedHeight * 4)
        fill(&padded, width: paddedWidth, height: paddedHeight, with: background)
        blit(
            composited,
            sourceWidth: crop.width,
            into: &padded,
            destinationWidth: paddedWidth,
            originX: padding,
            originY: padding
        )
        let scale = resolvedScale(inkWidth: crop.width, inkHeight: crop.height)
        let rgba = scale == 1 ? padded : scaleUp(padded, width: paddedWidth, height: paddedHeight, factor: scale)
        let lines = sourceLines.map { band in
            PreparedTextLine(
                top: (band.top + padding) * scale,
                bottom: (band.bottom + padding) * scale,
                left: (band.left + padding) * scale,
                right: (band.right + padding) * scale,
                isItalic: band.isItalic
            )
        }
        return PreparedSubtitleImage(
            width: paddedWidth * scale,
            height: paddedHeight * scale,
            rgba: rgba,
            scale: scale,
            lines: lines,
            background: background,
            isBlank: false
        )
    }

    /// Whole-number scale that brings the ink up to `minimumInkHeight` without
    /// passing `maximumScale` or making the padded picture wider than `maximumPixelWidth`.
    public func resolvedScale(inkWidth: Int, inkHeight: Int) -> Int {
        guard inkHeight > 0, inkWidth > 0 else { return 1 }
        let paddedWidth = inkWidth + padding * 2
        var scale = 1
        while scale < maximumScale && inkHeight * scale < minimumInkHeight {
            let next = scale + 1
            if paddedWidth * next > maximumPixelWidth { break }
            scale = next
        }
        return scale
    }

    private struct Crop {
        var minX: Int
        var minY: Int
        var maxX: Int
        var maxY: Int
        var width: Int { maxX - minX }
        var height: Int { maxY - minY }
    }

    private struct SourceLine {
        var top: Int
        var bottom: Int
        var left: Int
        var right: Int
        var isItalic: Bool
    }

    private func inkBounds(of image: SubtitleImage) -> Crop? {
        var minX = image.width
        var minY = image.height
        var maxX = 0
        var maxY = 0
        var found = false
        for y in 0..<image.height {
            for x in 0..<image.width {
                guard alpha(image, x, y) >= inkAlpha else { continue }
                found = true
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x + 1)
                maxY = max(maxY, y + 1)
            }
        }
        guard found else { return nil }
        return Crop(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    /// Black behind light fill, white behind dark fill.
    ///
    /// The sample is the middle of the ink, not an average of every opaque
    /// pixel. A dark outline around a light letter would pull that average
    /// down and the fill would be drawn on white, where it disappears. A pixel
    /// counts as fill only when its eight neighbors are ink too, so the outline
    /// (which touches transparency) is left out. The brightness used is the
    /// middle of those inner pixels. A stroke too thin to have an inside falls
    /// back to the middle of all of its ink.
    private func backgroundColor(of image: SubtitleImage, crop: Crop) -> RGBA {
        let brightness = fillLuminance(of: image, crop: crop)
        if brightness >= Double(lightInkLuminance) {
            return RGBA(r: 0, g: 0, b: 0, a: 255)
        }
        return RGBA(r: 255, g: 255, b: 255, a: 255)
    }

    private func fillLuminance(of image: SubtitleImage, crop: Crop) -> Double {
        var interior = [Int](repeating: 0, count: 256)
        var allInk = [Int](repeating: 0, count: 256)
        var interiorCount = 0
        var allCount = 0
        let threshold = UInt8(inkAlpha)
        for y in crop.minY..<crop.maxY {
            for x in crop.minX..<crop.maxX {
                let pixel = image.color(x: x, y: y)
                guard pixel.a >= threshold else { continue }
                let bin = luminanceBin(pixel)
                allInk[bin] += 1
                allCount += 1
                if isFill(image, x: x, y: y, threshold: threshold) {
                    interior[bin] += 1
                    interiorCount += 1
                }
            }
        }
        if interiorCount > 0 {
            return medianBin(interior, count: interiorCount)
        }
        if allCount > 0 {
            return medianBin(allInk, count: allCount)
        }
        return 255
    }

    /// True when this pixel is inside the stroke, not on the outline.
    private func isFill(_ image: SubtitleImage, x: Int, y: Int, threshold: UInt8) -> Bool {
        for dy in -1...1 {
            for dx in -1...1 {
                let nx = x + dx
                let ny = y + dy
                if nx < 0 || ny < 0 || nx >= image.width || ny >= image.height {
                    return false
                }
                if image.color(x: nx, y: ny).a < threshold {
                    return false
                }
            }
        }
        return true
    }

    private func luminanceBin(_ pixel: RGBA) -> Int {
        let value = Int(luminance(pixel).rounded())
        return min(255, max(0, value))
    }

    /// The middle value of a 0...255 histogram. `count` is the number of samples.
    private func medianBin(_ histogram: [Int], count: Int) -> Double {
        let lowerIndex = (count - 1) / 2
        let upperIndex = count / 2
        var seen = 0
        var lower: Double?
        var upper: Double?
        for bin in 0..<histogram.count {
            let next = seen + histogram[bin]
            if lower == nil && next > lowerIndex {
                lower = Double(bin)
            }
            if next > upperIndex {
                upper = Double(bin)
                break
            }
            seen = next
        }
        return ((lower ?? 255) + (upper ?? 255)) / 2
    }

    private func composite(_ image: SubtitleImage, crop: Crop, background: RGBA) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        for y in 0..<crop.height {
            for x in 0..<crop.width {
                let pixel = composite(image.color(x: crop.minX + x, y: crop.minY + y), over: background)
                let index = (y * crop.width + x) * 4
                buffer[index] = pixel.r
                buffer[index + 1] = pixel.g
                buffer[index + 2] = pixel.b
                buffer[index + 3] = pixel.a
            }
        }
        return buffer
    }

    private func lineBands(of image: SubtitleImage, crop: Crop) -> [SourceLine] {
        var inkRow = [Bool](repeating: false, count: crop.height)
        for y in 0..<crop.height {
            for x in 0..<crop.width where alpha(image, crop.minX + x, crop.minY + y) >= inkAlpha {
                inkRow[y] = true
                break
            }
        }
        var runs: [(top: Int, bottom: Int)] = []
        var y = 0
        while y < crop.height {
            if !inkRow[y] {
                y += 1
                continue
            }
            let top = y
            while y < crop.height && inkRow[y] { y += 1 }
            runs.append((top, y))
        }

        var merged: [(top: Int, bottom: Int)] = []
        var index = 0
        while index < runs.count {
            let top = runs[index].top
            var bottom = runs[index].bottom
            while index + 1 < runs.count {
                let next = runs[index + 1]
                let gap = next.top - bottom
                let upperHeight = bottom - top
                let lowerHeight = next.bottom - next.top
                let close = gap < lineGap
                let accent = upperHeight <= 2 && gap <= max(lineGap, lowerHeight / 2)
                if close || accent {
                    bottom = next.bottom
                    index += 1
                } else {
                    break
                }
            }
            merged.append((top, bottom))
            index += 1
        }

        return merged.map { band in
            var left = crop.width
            var right = 0
            for row in band.top..<band.bottom {
                for column in 0..<crop.width where alpha(image, crop.minX + column, crop.minY + row) >= inkAlpha {
                    left = min(left, column)
                    right = max(right, column + 1)
                }
            }
            if right <= left {
                left = 0
                right = crop.width
            }
            return SourceLine(
                top: band.top,
                bottom: band.bottom,
                left: left,
                right: right,
                isItalic: italic(image, crop: crop, top: band.top, bottom: band.bottom, left: left, right: right)
            )
        }
    }

    /// Right-leaning italics put the upper ink to the right of the lower ink.
    private func italic(
        _ image: SubtitleImage,
        crop: Crop,
        top: Int,
        bottom: Int,
        left: Int,
        right: Int
    ) -> Bool {
        let height = bottom - top
        guard height >= 4 else { return false }
        let mid = top + height / 2
        var topWeight = 0.0
        var topMoment = 0.0
        var bottomWeight = 0.0
        var bottomMoment = 0.0
        for row in top..<bottom {
            for column in left..<right {
                let pixel = image.color(x: crop.minX + column, y: crop.minY + row)
                guard pixel.a >= UInt8(inkAlpha) else { continue }
                let weight = Double(pixel.a)
                if row < mid {
                    topWeight += weight
                    topMoment += weight * Double(column)
                } else {
                    bottomWeight += weight
                    bottomMoment += weight * Double(column)
                }
            }
        }
        guard topWeight > 0, bottomWeight > 0 else { return false }
        let shift = (topMoment / topWeight) - (bottomMoment / bottomWeight)
        let threshold = max(2.0, Double(height) * 0.12)
        return shift > threshold
    }

    private func fill(_ buffer: inout [UInt8], width: Int, height: Int, with color: RGBA) {
        for pixel in 0..<(width * height) {
            let index = pixel * 4
            buffer[index] = color.r
            buffer[index + 1] = color.g
            buffer[index + 2] = color.b
            buffer[index + 3] = color.a
        }
    }

    private func blit(
        _ source: [UInt8],
        sourceWidth: Int,
        into destination: inout [UInt8],
        destinationWidth: Int,
        originX: Int,
        originY: Int
    ) {
        let sourceHeight = source.count / (sourceWidth * 4)
        for y in 0..<sourceHeight {
            for x in 0..<sourceWidth {
                let from = (y * sourceWidth + x) * 4
                let to = ((originY + y) * destinationWidth + (originX + x)) * 4
                destination[to] = source[from]
                destination[to + 1] = source[from + 1]
                destination[to + 2] = source[from + 2]
                destination[to + 3] = source[from + 3]
            }
        }
    }

    private func scaleUp(_ source: [UInt8], width: Int, height: Int, factor: Int) -> [UInt8] {
        let outWidth = width * factor
        let outHeight = height * factor
        var output = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        for y in 0..<outHeight {
            let sourceY = (Double(y) + 0.5) / Double(factor) - 0.5
            let y0 = Int(sourceY.rounded(.down))
            let y1 = y0 + 1
            let fy = sourceY - Double(y0)
            for x in 0..<outWidth {
                let sourceX = (Double(x) + 0.5) / Double(factor) - 0.5
                let x0 = Int(sourceX.rounded(.down))
                let x1 = x0 + 1
                let fx = sourceX - Double(x0)
                for channel in 0..<4 {
                    let c00 = Double(sample(source, width: width, height: height, x: x0, y: y0, channel: channel))
                    let c10 = Double(sample(source, width: width, height: height, x: x1, y: y0, channel: channel))
                    let c01 = Double(sample(source, width: width, height: height, x: x0, y: y1, channel: channel))
                    let c11 = Double(sample(source, width: width, height: height, x: x1, y: y1, channel: channel))
                    let top = c00 + (c10 - c00) * fx
                    let bottom = c01 + (c11 - c01) * fx
                    let value = top + (bottom - top) * fy
                    output[(y * outWidth + x) * 4 + channel] = UInt8(clamping: Int(value.rounded()))
                }
            }
        }
        return output
    }

    private func sample(_ buffer: [UInt8], width: Int, height: Int, x: Int, y: Int, channel: Int) -> UInt8 {
        let clampedX = min(max(x, 0), width - 1)
        let clampedY = min(max(y, 0), height - 1)
        return buffer[(clampedY * width + clampedX) * 4 + channel]
    }

    private func composite(_ foreground: RGBA, over background: RGBA) -> RGBA {
        let alpha = Double(foreground.a) / 255.0
        func channel(_ source: UInt8, _ behind: UInt8) -> UInt8 {
            let value = Double(source) * alpha + Double(behind) * (1 - alpha)
            return UInt8(clamping: Int(value.rounded()))
        }
        return RGBA(
            r: channel(foreground.r, background.r),
            g: channel(foreground.g, background.g),
            b: channel(foreground.b, background.b),
            a: 255
        )
    }

    private func luminance(_ pixel: RGBA) -> Double {
        0.2126 * Double(pixel.r) + 0.7152 * Double(pixel.g) + 0.0722 * Double(pixel.b)
    }

    private func alpha(_ image: SubtitleImage, _ x: Int, _ y: Int) -> Int {
        Int(image.color(x: x, y: y).a)
    }
}
