import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PGSCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.banners.isEmpty {
                bannerList
            }
            // No rows left, including after Clear Finished or the last remove, is the drop screen.
            if model.items.isEmpty {
                emptyDrop
            } else {
                queueList
            }
            footer
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $targeted, perform: handleDrop)
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Open…") { model.showOpenPanel() }
                Button("Cancel All") { model.cancelAll() }
                    .disabled(!model.hasCancellableWork)
                Button("Clear Finished") { model.clearFinished() }
                    .disabled(!model.canClearFinished)
                SettingsToolbarButton()
            }
        }
        .background {
            QueueWindowMarker().allowsHitTesting(false)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PGS2SRT")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Drop Blu-ray .sup files or a folder. Each file becomes an .srt subtitle.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var bannerList: some View {
        VStack(spacing: 8) {
            ForEach(Array(model.banners.enumerated()), id: \.offset) { index, banner in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(banner)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Dismiss") { model.dismissBanner(at: index) }
                        .buttonStyle(.borderless)
                }
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var emptyDrop: some View {
        VStack(spacing: 12) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 42))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
            Text(targeted ? "Drop to convert" : "Drop .sup files or a folder")
                .font(.title3)
            Text("You can also click Open…. An .mkv is left as it is, with a note that MKV support is coming.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.45))
                .padding(20)
        }
    }

    private var queueList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.items) { item in
                    QueueRow(
                        item: item,
                        onCancel: { model.cancel(id: item.id) },
                        onReveal: { model.reveal(item) },
                        onRemove: { model.remove(id: item.id) }
                    )
                    Divider()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.settingsSummary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(model.items.isEmpty ? "The .srt is written next to the file unless Settings says otherwise." : "Drop more files to add them.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await Self.loadURL(from: provider) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                await MainActor.run {
                    model.importURLs(urls)
                }
            }
        }
        return true
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                once.run {
                    continuation.resume(returning: url(from: item))
                }
            }
        }
    }

    /// Pure path parsing. The drop callback is not on the main actor.
    private nonisolated static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil) { return url }
            if let string = String(data: data, encoding: .utf8) {
                return url(fromPathOrFileURL: string)
            }
        }
        if let string = item as? NSString {
            return url(fromPathOrFileURL: string as String)
        }
        return nil
    }

    private nonisolated static func url(fromPathOrFileURL string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("file:") { return URL(string: trimmed) }
        if trimmed.isEmpty { return nil }
        return URL(fileURLWithPath: trimmed)
    }
}

/// The Settings toolbar button, drawn the same way as Open…, Cancel All, and Clear Finished.
///
/// macOS 14 and later open the Settings scene with `openSettings`. The older
/// `showSettingsWindow:` action no longer does that, and macOS asks for
/// SettingsLink instead. macOS 13 still opens Settings with that action.
private struct SettingsToolbarButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsToolbarButtonMacOS14()
        } else {
            Button("Settings…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }
}

@available(macOS 14.0, *)
private struct SettingsToolbarButtonMacOS14: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            openSettings()
        }
    }
}

/// Tags the queue window so a Dock or Open With drop can tell it from Settings.
private struct QueueWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        QueueWindowClaim()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? QueueWindowClaim)?.claim()
    }
}

private final class QueueWindowClaim: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claim()
    }

    func claim() {
        window?.identifier = QueueWindow.marker
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let shouldRun = !done
        done = true
        lock.unlock()
        if shouldRun { body() }
    }
}

private struct QueueRow: View {
    let item: ConversionItem
    var onCancel: () -> Void
    var onReveal: () -> Void
    var onRemove: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.headline)
                    if !item.folder.isEmpty {
                        Text(item.folder)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if item.status.isActive {
                    Button("Cancel", action: onCancel)
                        .controlSize(.small)
                } else if case .done = item.status {
                    Button("Reveal in Finder", action: onReveal)
                        .controlSize(.small)
                }
                if item.status.isRemovable {
                    removeButton
                }
            }
            statusLine
            if case let .converting(completed, total) = item.status {
                progress(completed: completed, total: total)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovered ? Color.primary.opacity(0.08) : Color.clear)
        .background {
            RowHover(setHovered: { hovered = $0 })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .contextMenu {
            if case .done = item.status {
                Button("Reveal in Finder", action: onReveal)
            }
            if item.status.isActive {
                Button("Cancel", action: onCancel)
            }
        }
    }

    /// The slot stays in the row while the pointer is elsewhere, so Reveal in Finder does not move.
    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .opacity(hovered ? 1 : 0)
        .accessibilityLabel("Remove")
        .accessibilityHidden(!hovered)
        .allowsHitTesting(hovered)
    }

    private var statusLine: some View {
        Text(detail)
            .font(.callout)
            .foregroundStyle(detailColor)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var detail: String {
        switch item.status {
        case .waiting:
            return "Waiting"
        case let .converting(completed, total):
            if total > 0 { return "Converting" }
            return completed > 0 ? "Converting" : "Reading…"
        case let .done(cues, unrecognized, path):
            let name = (path as NSString).lastPathComponent
            let cueText = cues == 1 ? "1 cue" : "\(cues) cues"
            if unrecognized > 0 {
                let failed = unrecognized == 1 ? "1 [OCR failed]" : "\(unrecognized) [OCR failed]"
                return "Done · \(cueText) · \(failed) · \(name)"
            }
            return "Done · \(cueText) · \(name)"
        case let .failed(message):
            return message
        case .cancelled:
            return "Cancelled"
        case let .skipped(message):
            return message
        }
    }

    private var detailColor: Color {
        switch item.status {
        case .failed:
            return .red
        case .done:
            return Color(nsColor: .systemGreen)
        default:
            return .secondary
        }
    }

    @ViewBuilder
    private func progress(completed: Int, total: Int) -> some View {
        HStack(spacing: 8) {
            if total > 0 {
                ProgressView(value: Double(completed), total: Double(total))
                    .accessibilityLabel("Progress")
                    .accessibilityValue("\(completed) of \(total)")
                Text("\(completed)/\(total)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72, alignment: .trailing)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Reading")
            }
        }
    }
}

/// Pointer tracking for the row highlight and the remove button.
///
/// SwiftUI's `onHover` says the pointer left when it moves onto the button,
/// which hides that button before it can be clicked. A tracking area follows
/// the row's rectangle instead, including the button.
private struct RowHover: NSViewRepresentable {
    var setHovered: (Bool) -> Void

    func makeNSView(context: Context) -> RowHoverView {
        let view = RowHoverView()
        view.setHovered = setHovered
        return view
    }

    func updateNSView(_ view: RowHoverView, context: Context) {
        view.setHovered = setHovered
    }
}

private final class RowHoverView: NSView {
    var setHovered: (Bool) -> Void = { _ in }
    private var inside = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
        syncFromPointer(async: true)
    }

    override func mouseEntered(with event: NSEvent) {
        setInside(true, async: false)
    }

    override func mouseExited(with event: NSEvent) {
        setInside(false, async: false)
    }

    /// Scrolling moves the row under a still pointer, so check again after layout.
    /// The callback waits a turn so it does not change SwiftUI state during a view update.
    private func syncFromPointer(async: Bool) {
        guard let window, bounds.width > 0, bounds.height > 0 else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setInside(bounds.contains(point), async: async)
    }

    private func setInside(_ now: Bool, async: Bool) {
        guard now != inside else { return }
        inside = now
        if async {
            let setHovered = self.setHovered
            DispatchQueue.main.async {
                setHovered(now)
            }
        } else {
            setHovered(now)
        }
    }
}
