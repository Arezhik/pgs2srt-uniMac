import AppKit
import SwiftUI

/// Multiline cue editor.
///
/// SwiftUI's `TextField(axis: .vertical)` is an `NSTextField`. On macOS 13 its
/// field editor does not reliably insert a newline for Option-Return (Return
/// ends editing instead). This view is an `NSTextView`, which is the stock
/// multiline control, and it inserts the line break itself on Option-Return.
/// Return commits and moves to the next cue. Escape reverts the current burst.
/// Command-Delete deletes the cue, including while the field is focused.
struct CueTextEditor: NSViewRepresentable {
    var cueID: UUID
    var text: String
    var focusRequest: Int
    var onTextChange: (String) -> Void
    var onCommit: () -> Void
    var onRevert: () -> Void
    var onDeleteCue: () -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onFocus: (Bool) -> Void
    var onEndCoalescing: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CueNSTextView()
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.string = text
        textView.setAccessibilityLabel("Cue text")

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? CueNSTextView else { return }
        if context.coordinator.cueID != cueID {
            context.coordinator.cueID = cueID
            textView.string = text
            let end = (text as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
        } else if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let location = min(selected.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
        }
        if context.coordinator.lastFocusRequest == nil {
            context.coordinator.lastFocusRequest = focusRequest
        } else if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            scroll.window?.makeFirstResponder(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CueTextEditor
        var cueID: UUID?
        var lastFocusRequest: Int?

        init(_ parent: CueTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.onTextChange(textView.string)
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocus(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocus(false)
            parent.onEndCoalescing()
        }
    }
}

final class CueNSTextView: NSTextView {
    weak var coordinator: CueTextEditor.Coordinator?

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers ?? ""
        if characters == "\r" || characters == "\n" {
            if event.modifierFlags.contains(.option) {
                insertNewline(nil)
                return
            }
            if event.modifierFlags.contains(.command) {
                super.keyDown(with: event)
                return
            }
            coordinator?.parent.onCommit()
            return
        }
        if characters == "\u{1b}" {
            coordinator?.parent.onRevert()
            return
        }
        if event.modifierFlags.contains(.command), characters == "z" || characters == "Z" {
            if event.modifierFlags.contains(.shift) {
                coordinator?.parent.onRedo()
            } else {
                coordinator?.parent.onUndo()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func deleteToBeginningOfLine(_ sender: Any?) {
        coordinator?.parent.onDeleteCue()
    }
}
