import AppKit
import PGSCore

/// One main-actor owner for the Dock badge and the thin progress bar.
@MainActor
final class DockProgressController {
    private var progressView: DockProgressView?
    private var highWater: Double = 0
    private var lastDisplay = Date.distantPast

    func beginBatch() {
        highWater = 0
        lastDisplay = .distantPast
        clearTile()
    }

    func update(_ meter: BatchMeter) {
        guard meter.active else {
            clearTile()
            return
        }
        let fraction = max(highWater, min(1, meter.fraction))
        highWater = fraction
        let badge = meter.remaining > 0 ? String(meter.remaining) : nil
        let badgeChanged = NSApp.dockTile.badgeLabel != badge
        NSApp.dockTile.badgeLabel = badge
        let tile = progressView ?? DockProgressView(frame: NSRect(origin: .zero, size: NSApp.dockTile.size))
        if progressView == nil {
            progressView = tile
            NSApp.dockTile.contentView = tile
        }
        tile.fraction = CGFloat(fraction)
        tile.needsDisplay = true
        let now = Date()
        if badgeChanged || now.timeIntervalSince(lastDisplay) >= 0.2 {
            lastDisplay = now
            NSApp.dockTile.display()
        }
    }

    func finishBatch(failed: Int, notifications: BatchNotificationPolicy) {
        clearTile()
        guard failed > 0, !NSApp.isActive, notifications != .never else { return }
        NSApp.requestUserAttention(.informationalRequest)
    }

    private func clearTile() {
        highWater = 0
        progressView = nil
        NSApp.dockTile.badgeLabel = nil
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }
}

/// The app icon with a capsule bar along the bottom. The system badge stays at the top.
final class DockProgressView: NSView {
    var fraction: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        let scale = bounds.width > 0 ? bounds.width / 128 : 1
        let inset = 14 * scale
        let barHeight = 10 * scale
        let bottom = 12 * scale
        let bar = NSRect(
            x: inset,
            y: bottom,
            width: max(0, bounds.width - inset * 2),
            height: barHeight
        )
        let track = NSBezierPath(roundedRect: bar, xRadius: barHeight / 2, yRadius: barHeight / 2)
        NSColor.white.setFill()
        track.fill()
        NSColor.black.withAlphaComponent(0.55).setStroke()
        track.lineWidth = 0.5 * scale
        track.stroke()
        guard fraction > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        NSColor.controlAccentColor.setFill()
        NSRect(x: bar.minX, y: bar.minY, width: bar.width * fraction, height: bar.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

enum NotificationSettingsLink {
    /// Opens System Settings at Notifications. If that URL is refused, opens System Settings.
    static func open() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
        if let url = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(url)
        }
    }
}
