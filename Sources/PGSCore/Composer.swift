import Foundation

/// Turns display sets into timed images.
///
/// A cue starts when a display set draws one or more objects. It stays open
/// across palette fades and repeated acquisition points that draw the same
/// indexed image, keeping the most opaque rendering for later OCR. It ends at
/// the next clearing display set (no composition objects). A different image
/// ends it early, and an epoch start discards whatever the previous epoch showed.
struct DisplaySetComposer {
    var colorMatrix: ColorMatrix?

    func compose(_ sets: [DisplaySet]) throws -> [SubtitleCue] {
        var epoch = Epoch()
        var open: OpenCue?
        var cues: [SubtitleCue] = []

        for set in sets {
            if set.pcs.state == .epochStart, let current = open {
                cues.append(try close(current, at: set.pts, reason: .epochStart))
                open = nil
            }
            if set.pcs.state != .normal {
                epoch = Epoch()
            }
            apply(set, to: &epoch)

            if set.pcs.objects.isEmpty {
                if let current = open {
                    cues.append(try close(current, at: set.pts, reason: .clearingDisplaySet))
                    open = nil
                }
                continue
            }

            let rendered = try render(set, epoch: epoch)
            if let current = open {
                if current.matches(rendered) {
                    var updated = current
                    if rendered.opacity > updated.opacity {
                        updated.image = rendered.image
                        updated.opacity = rendered.opacity
                    }
                    updated.forced = updated.forced || rendered.forced
                    open = updated
                } else {
                    cues.append(try close(current, at: set.pts, reason: .replaced))
                    open = OpenCue(startPTS: set.pts, rendered: rendered)
                }
            } else {
                open = OpenCue(startPTS: set.pts, rendered: rendered)
            }
        }

        if let current = open {
            cues.append(SubtitleCue(
                startPTS: current.startPTS,
                endPTS: current.startPTS,
                image: current.image,
                forced: current.forced,
                endReason: .endOfFile
            ))
        }
        return cues
    }

    private func close(_ cue: OpenCue, at endPTS: UInt32, reason: CueEndReason) throws -> SubtitleCue {
        if endPTS < cue.startPTS {
            throw PGSError.nonMonotonicPTS(previous: cue.startPTS, next: endPTS)
        }
        return SubtitleCue(
            startPTS: cue.startPTS,
            endPTS: endPTS,
            image: cue.image,
            forced: cue.forced,
            endReason: reason
        )
    }

    private func apply(_ set: DisplaySet, to epoch: inout Epoch) {
        for window in set.windows {
            epoch.windows[window.id] = window
        }
        for segment in set.palettes {
            var palette = epoch.palettes[segment.id] ?? Palette()
            palette.version = segment.version
            for entry in segment.entries {
                palette.entries[Int(entry.id)] = YCbCrColor(y: entry.y, cr: entry.cr, cb: entry.cb, a: entry.a)
            }
            epoch.palettes[segment.id] = palette
        }
        for object in set.objects {
            epoch.objects[object.id] = object
        }
    }

    private func render(_ set: DisplaySet, epoch: Epoch) throws -> Rendered {
        let matrix = colorMatrix ?? ColorMatrix.automatic(videoHeight: set.pcs.height)
        guard let palette = epoch.palettes[set.pcs.paletteID] else {
            throw PGSError.missingPalette(paletteID: set.pcs.paletteID)
        }
        let colors = palette.rgba(matrix: matrix)
        var blits: [Blit] = []
        var forced = false
        for composition in set.pcs.objects {
            guard let bitmap = epoch.objects[composition.objectID] else {
                throw PGSError.missingObject(objectID: composition.objectID)
            }
            let window: WindowSegment?
            if epoch.windows.isEmpty {
                window = nil
            } else if let defined = epoch.windows[composition.windowID] {
                window = defined
            } else {
                throw PGSError.missingWindow(windowID: composition.windowID)
            }
            if let blit = try visibleBlit(
                bitmap: bitmap,
                composition: composition,
                window: window,
                videoWidth: set.pcs.width,
                videoHeight: set.pcs.height
            ) {
                blits.append(blit)
            }
            forced = forced || composition.forced
        }

        guard let bounds = union(of: blits) else {
            return Rendered(
                image: SubtitleImage(
                    width: 0,
                    height: 0,
                    rgba: [],
                    originX: 0,
                    originY: 0,
                    videoWidth: set.pcs.width,
                    videoHeight: set.pcs.height
                ),
                indices: [],
                opacity: 0,
                forced: forced
            )
        }

        var rgba = [UInt8](repeating: 0, count: bounds.width * bounds.height * 4)
        var indices = [UInt8](repeating: 0, count: bounds.width * bounds.height)
        var opacity: UInt64 = 0
        for blit in blits {
            for row in 0..<blit.height {
                for column in 0..<blit.width {
                    let sourceIndex = (blit.sourceY + row) * blit.sourceWidth + (blit.sourceX + column)
                    let paletteIndex = blit.indices[sourceIndex]
                    let destination = (blit.destY - bounds.y + row) * bounds.width + (blit.destX - bounds.x + column)
                    indices[destination] = paletteIndex
                    var pixel = RGBA(
                        r: rgba[destination * 4],
                        g: rgba[destination * 4 + 1],
                        b: rgba[destination * 4 + 2],
                        a: rgba[destination * 4 + 3]
                    )
                    blend(dst: &pixel, src: colors[Int(paletteIndex)])
                    rgba[destination * 4] = pixel.r
                    rgba[destination * 4 + 1] = pixel.g
                    rgba[destination * 4 + 2] = pixel.b
                    rgba[destination * 4 + 3] = pixel.a
                }
            }
        }
        for pixel in stride(from: 3, to: rgba.count, by: 4) {
            opacity += UInt64(rgba[pixel])
        }
        return Rendered(
            image: SubtitleImage(
                width: bounds.width,
                height: bounds.height,
                rgba: rgba,
                originX: bounds.x,
                originY: bounds.y,
                videoWidth: set.pcs.width,
                videoHeight: set.pcs.height
            ),
            indices: indices,
            opacity: opacity,
            forced: forced
        )
    }
}

private struct Epoch {
    var palettes: [UInt8: Palette] = [:]
    var objects: [UInt16: ObjectBitmap] = [:]
    var windows: [UInt8: WindowSegment] = [:]
}

private struct Palette {
    var version: UInt8 = 0
    var entries: [YCbCrColor?] = Array(repeating: nil, count: 256)

    func rgba(matrix: ColorMatrix) -> [RGBA] {
        entries.map { entry in
            guard let entry else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
            return ColorConversion.rgba(entry, matrix: matrix)
        }
    }
}

private struct Blit {
    var indices: [UInt8]
    var sourceWidth: Int
    var sourceX: Int
    var sourceY: Int
    var width: Int
    var height: Int
    var destX: Int
    var destY: Int
}

private struct Bounds {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

private struct Rendered {
    var image: SubtitleImage
    var indices: [UInt8]
    var opacity: UInt64
    var forced: Bool
}

private struct OpenCue {
    var startPTS: UInt32
    var image: SubtitleImage
    var indices: [UInt8]
    var opacity: UInt64
    var forced: Bool

    init(startPTS: UInt32, rendered: Rendered) {
        self.startPTS = startPTS
        self.image = rendered.image
        self.indices = rendered.indices
        self.opacity = rendered.opacity
        self.forced = rendered.forced
    }

    func matches(_ rendered: Rendered) -> Bool {
        indices == rendered.indices
            && image.width == rendered.image.width
            && image.height == rendered.image.height
            && image.originX == rendered.image.originX
            && image.originY == rendered.image.originY
    }
}

private func visibleBlit(
    bitmap: ObjectBitmap,
    composition: CompositionObject,
    window: WindowSegment?,
    videoWidth: Int,
    videoHeight: Int
) throws -> Blit? {
    var sourceX = 0
    var sourceY = 0
    var width = bitmap.width
    var height = bitmap.height
    if composition.cropped {
        guard composition.cropWidth > 0, composition.cropHeight > 0 else {
            throw PGSError.invalidCrop(
                objectID: composition.objectID,
                message: "the crop size is \(composition.cropWidth)x\(composition.cropHeight)."
            )
        }
        let cropRight = composition.cropX + composition.cropWidth
        let cropBottom = composition.cropY + composition.cropHeight
        guard composition.cropX >= 0, composition.cropY >= 0,
              cropRight <= bitmap.width, cropBottom <= bitmap.height else {
            throw PGSError.invalidCrop(
                objectID: composition.objectID,
                message: "crop (\(composition.cropX), \(composition.cropY)) \(composition.cropWidth)x\(composition.cropHeight) is outside the \(bitmap.width)x\(bitmap.height) image."
            )
        }
        sourceX = composition.cropX
        sourceY = composition.cropY
        width = composition.cropWidth
        height = composition.cropHeight
    }

    var destX = composition.x
    var destY = composition.y
    if let window {
        guard let clipped = clip(
            destX: destX,
            destY: destY,
            width: width,
            height: height,
            sourceX: sourceX,
            sourceY: sourceY,
            toX: window.x,
            toY: window.y,
            toWidth: window.width,
            toHeight: window.height
        ) else {
            return nil
        }
        destX = clipped.destX
        destY = clipped.destY
        width = clipped.width
        height = clipped.height
        sourceX = clipped.sourceX
        sourceY = clipped.sourceY
    }
    guard let clipped = clip(
        destX: destX,
        destY: destY,
        width: width,
        height: height,
        sourceX: sourceX,
        sourceY: sourceY,
        toX: 0,
        toY: 0,
        toWidth: videoWidth,
        toHeight: videoHeight
    ) else {
        return nil
    }
    return Blit(
        indices: bitmap.indices,
        sourceWidth: bitmap.width,
        sourceX: clipped.sourceX,
        sourceY: clipped.sourceY,
        width: clipped.width,
        height: clipped.height,
        destX: clipped.destX,
        destY: clipped.destY
    )
}

private struct ClipResult {
    var destX: Int
    var destY: Int
    var width: Int
    var height: Int
    var sourceX: Int
    var sourceY: Int
}

private func clip(
    destX: Int,
    destY: Int,
    width: Int,
    height: Int,
    sourceX: Int,
    sourceY: Int,
    toX: Int,
    toY: Int,
    toWidth: Int,
    toHeight: Int
) -> ClipResult? {
    let x0 = max(destX, toX)
    let y0 = max(destY, toY)
    let x1 = min(destX + width, toX + toWidth)
    let y1 = min(destY + height, toY + toHeight)
    guard x1 > x0, y1 > y0 else { return nil }
    return ClipResult(
        destX: x0,
        destY: y0,
        width: x1 - x0,
        height: y1 - y0,
        sourceX: sourceX + (x0 - destX),
        sourceY: sourceY + (y0 - destY)
    )
}

private func union(of blits: [Blit]) -> Bounds? {
    guard let first = blits.first else { return nil }
    var minX = first.destX
    var minY = first.destY
    var maxX = first.destX + first.width
    var maxY = first.destY + first.height
    for blit in blits.dropFirst() {
        minX = min(minX, blit.destX)
        minY = min(minY, blit.destY)
        maxX = max(maxX, blit.destX + blit.width)
        maxY = max(maxY, blit.destY + blit.height)
    }
    guard maxX > minX, maxY > minY else { return nil }
    return Bounds(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

private func blend(dst: inout RGBA, src: RGBA) {
    let sourceAlpha = Int(src.a)
    if sourceAlpha == 0 { return }
    if sourceAlpha == 255 || dst.a == 0 {
        dst = src
        return
    }
    let destinationAlpha = Int(dst.a)
    let inverse = 255 - sourceAlpha
    let outAlpha = sourceAlpha + destinationAlpha * inverse / 255
    if outAlpha == 0 {
        dst = RGBA(r: 0, g: 0, b: 0, a: 0)
        return
    }
    func channel(_ source: UInt8, _ destination: UInt8) -> UInt8 {
        let value = (Int(source) * sourceAlpha + Int(destination) * destinationAlpha * inverse / 255) / outAlpha
        return UInt8(min(255, max(0, value)))
    }
    dst = RGBA(
        r: channel(src.r, dst.r),
        g: channel(src.g, dst.g),
        b: channel(src.b, dst.b),
        a: UInt8(min(255, outAlpha))
    )
}
