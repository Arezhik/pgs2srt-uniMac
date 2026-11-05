import AppKit
import ReviewDelegateProxy
import XCTest

/// Unknown window-delegate messages used to raise `unrecognized selector` on
/// the proxy. AppKit can send one after it has already decided the delegate
/// responds, which is the #36 crash on `window:willEncodeRestorableState:`.
@MainActor
final class ReviewWindowDelegateProxyTests: XCTestCase {
    func testUnknownAndMultiArgumentSelectorsDoNotThrow() {
        let proxy = ReviewWindowDelegateProxy()
        let window = makeWindow(title: "pgs2")
        let coder = NSKeyedArchiver(requiringSecureCoding: false)
        let encode = #selector(NSWindowDelegate.window(_:willEncodeRestorableState:))
        let decode = #selector(NSWindowDelegate.window(_:didDecodeRestorableState:))
        let resize = #selector(NSWindowDelegate.windowWillResize(_:to:))
        let unknown = NSSelectorFromString("reviewProxyAbsent:")
        let unknownTwo = NSSelectorFromString("reviewProxyAbsent::")

        XCTAssertFalse(proxy.responds(to: encode))
        XCTAssertFalse(proxy.responds(to: unknown))
        let encodeSignature = ReviewWindowDelegateProxyDescribe(proxy, encode)
        let unknownSignature = ReviewWindowDelegateProxyDescribe(proxy, unknown)
        let unknownTwoSignature = ReviewWindowDelegateProxyDescribe(proxy, unknownTwo)
        XCTAssertGreaterThan(encodeSignature.argumentCount, 0)
        XCTAssertGreaterThan(unknownSignature.argumentCount, 0)
        XCTAssertGreaterThan(unknownTwoSignature.argumentCount, 0)
        XCTAssertEqual(encodeSignature.argumentCount, 4)
        XCTAssertEqual(encodeSignature.returnLength, 0)

        ReviewWindowDelegateProxyProbeEncode(proxy, window, coder)
        _ = proxy.perform(encode, with: window, with: coder)
        _ = proxy.perform(decode, with: window, with: coder)
        _ = proxy.perform(unknown, with: window)
        _ = proxy.perform(unknownTwo, with: window, with: coder)
        assertResizeSinks(proxy, window, resize)

        let recorder = RecordingDelegate()
        proxy.forwardingDelegate = recorder
        XCTAssertTrue(proxy.responds(to: encode))
        XCTAssertTrue(proxy.responds(to: resize))
        let forwarded = object(proxy.forwardingTarget(for: encode))
        XCTAssertTrue(forwarded === recorder)

        ReviewWindowDelegateProxyProbeEncode(proxy, window, coder)
        XCTAssertEqual(recorder.calls.last, "encode")
        XCTAssertTrue(recorder.lastCoder === coder)
        let resized = ReviewWindowDelegateProxyProbeResize(proxy, window, NSSize(width: 800, height: 600))
        XCTAssertEqual(resized.width, 11, accuracy: 0.001)
        XCTAssertEqual(resized.height, 22, accuracy: 0.001)
        XCTAssertEqual(recorder.calls.last, "resize")

        // The cache said yes. The wrapped delegate is gone. Sending must sink.
        proxy.forwardingDelegate = nil
        XCTAssertFalse(proxy.responds(to: encode))
        XCTAssertFalse(proxy.responds(to: resize))
        XCTAssertNil(proxy.forwardingTarget(for: encode))
        ReviewWindowDelegateProxyProbeEncode(proxy, window, coder)
        _ = proxy.perform(encode, with: window, with: coder)
        _ = proxy.perform(#selector(NSWindowDelegate.windowDidResize(_:)), with: window)
        assertResizeSinks(proxy, window, resize)
        XCTAssertEqual(recorder.calls, ["encode", "resize"])
    }

    func testSelectorTableNeverThrowsWhenNothingHandlesIt() {
        let window = makeWindow(title: "pgs2")
        let coder = NSKeyedArchiver(requiringSecureCoding: false)
        let names = delegateSelectors

        let bare = ReviewWindowDelegateProxy()
        for name in names {
            assertUnsignedSelectorCanBeSent(bare, name, window, coder)
        }

        let proxy = ReviewWindowDelegateProxy()
        proxy.forwardingDelegate = EmptySwiftWindowDelegate()
        for name in names {
            assertUnsignedSelectorCanBeSent(proxy, name, window, coder)
        }

        proxy.forwardingDelegate = nil
        for name in names {
            assertUnsignedSelectorCanBeSent(proxy, name, window, coder)
        }
    }

    func testForwardingDelegateIsKeptAndPrivateSelectorsStillForward() {
        let proxy = ReviewWindowDelegateProxy()
        let window = makeWindow(title: "pgs1")
        var recorder: RecordingDelegate? = RecordingDelegate()
        window.delegate = recorder
        proxy.attach(to: window)
        recorder = nil

        guard let kept = proxy.forwardingDelegate as? RecordingDelegate else {
            XCTFail("forwarding delegate was released")
            return
        }
        XCTAssertFalse(window.isRestorable)
        XCTAssertTrue(window.delegate === proxy)

        let space = NSSelectorFromString("windowDidChangeSpace:")
        let off = NSSelectorFromString("windowDidOrderOffScreen:")
        XCTAssertTrue(proxy.responds(to: space))
        XCTAssertTrue(object(proxy.forwardingTarget(for: space)) === kept)
        _ = proxy.perform(space, with: window)
        _ = proxy.perform(off, with: window)
        XCTAssertEqual(kept.calls, ["space", "ordered off screen"])

        proxy.forwardingDelegate = nil
        XCTAssertFalse(proxy.responds(to: space))
        _ = proxy.perform(space, with: window)
        _ = proxy.perform(off, with: window)
        XCTAssertEqual(kept.calls, ["space", "ordered off screen"])

        proxy.detach()
        XCTAssertNil(proxy.forwardingDelegate)
    }

    func testWindowNotificationsAreLogged() {
        let proxy = ReviewWindowDelegateProxy()
        let lines = Lines()
        let flags = Flags()
        proxy.logEvent = { event, title in
            lines.values.append("Review window \(event): \(title)")
        }
        proxy.didBecomeKey = { flags.becameKey = true }
        proxy.willClose = { flags.willClose = true }
        let window = makeWindow(title: "pgs1")
        proxy.attach(to: window)

        let events: [(Notification.Name, String)] = [
            (NSWindow.willMiniaturizeNotification, "will minimize"),
            (NSWindow.didResignKeyNotification, "resigned key"),
            (NSWindow.didMiniaturizeNotification, "minimized"),
            (NSNotification.Name.ReviewWindowWillOrderOffScreen, "will order off screen"),
            (NSNotification.Name.ReviewWindowDidOrderOffScreen, "ordered off screen"),
            (NSNotification.Name.ReviewWindowWillOrderOnScreen, "will order on screen"),
            (NSNotification.Name.ReviewWindowDidOrderOnScreen, "ordered on screen"),
            (NSWindow.didDeminiaturizeNotification, "restored"),
            (NSWindow.didBecomeKeyNotification, "became key"),
            (NSWindow.willEnterFullScreenNotification, "will enter full screen"),
            (NSWindow.didEnterFullScreenNotification, "entered full screen"),
            (NSWindow.willExitFullScreenNotification, "will exit full screen"),
            (NSWindow.didExitFullScreenNotification, "exited full screen"),
            (NSWindow.didChangeOcclusionStateNotification, "occlusion changed"),
            (NSWindow.didChangeScreenNotification, "screen changed"),
            (NSWindow.willCloseNotification, "will close")
        ]
        for (name, event) in events {
            NotificationCenter.default.post(name: name, object: window)
            XCTAssertEqual(lines.values.last, "Review window \(event): pgs1", event)
        }
        XCTAssertTrue(flags.becameKey)
        XCTAssertTrue(flags.willClose)

        let other = makeWindow(title: "other")
        let count = lines.values.count
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: other)
        XCTAssertEqual(lines.values.count, count)

        let blank = makeWindow(title: "")
        proxy.attach(to: blank)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: blank)
        XCTAssertEqual(lines.values.last, "Review window resigned key: review")
    }

    func testAttachDisablesRestorationAndSurvivesMiniaturizeAndEncode() {
        let proxy = ReviewWindowDelegateProxy()
        let lines = Lines()
        proxy.logEvent = { event, title in
            lines.values.append("Review window \(event): \(title)")
        }
        let window = makeWindow(title: "pgs2")
        window.isRestorable = true
        let recorder = RecordingDelegate()
        window.delegate = recorder
        proxy.attach(to: window)
        XCTAssertFalse(window.isRestorable)
        XCTAssertTrue(window.delegate === proxy)

        window.animationBehavior = .none
        window.orderFrontRegardless()
        window.miniaturize(nil)
        window.deminiaturize(nil)
        window.orderFrontRegardless()

        window.isRestorable = true
        window.invalidateRestorableState()
        let coder = NSKeyedArchiver(requiringSecureCoding: false)
        window.encodeRestorableState(with: coder)
        ReviewWindowDelegateProxyProbeEncode(proxy, window, coder)
        XCTAssertEqual(recorder.calls.last, "encode")
        XCTAssertTrue(recorder.lastCoder === coder)

        proxy.forwardingDelegate = nil
        window.invalidateRestorableState()
        window.encodeRestorableState(with: coder)
        ReviewWindowDelegateProxyProbeEncode(proxy, window, coder)
        assertResizeSinks(proxy, window, #selector(NSWindowDelegate.windowWillResize(_:to:)))

        for line in lines.values {
            XCTAssertTrue(line.hasPrefix("Review window "), line)
        }
    }

    func testClosePromptAllowsACleanWindowAndDefersADirtyOne() {
        let proxy = ReviewWindowDelegateProxy()
        let lines = Lines()
        let flags = Flags()
        proxy.logEvent = { event, title in
            lines.values.append("Review window \(event): \(title)")
        }
        let window = CloseRecordingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = "realtestduoBAK"
        window.delegate = proxy

        XCTAssertTrue(proxy.windowShouldClose(window))
        XCTAssertEqual(lines.values, ["Review window close allowed: realtestduoBAK"])

        proxy.isDirty = { true }
        proxy.attemptClose = { decision in
            flags.asked = true
            decision(false)
        }
        XCTAssertFalse(proxy.windowShouldClose(window))
        XCTAssertTrue(flags.asked)
        XCTAssertEqual(lines.values.last, "Review window close asked: realtestduoBAK")

        proxy.willClose = { flags.willClose = true }
        proxy.attemptClose = { decision in
            decision(true)
        }
        // AppKit does not re-enter windowShouldClose: from inside that call,
        // and -[NSWindow close] segfaults in this headless test process.
        // Record the close instead, then prove the allow flag lets the next
        // ask through.
        XCTAssertFalse(proxy.windowShouldClose(window))
        XCTAssertEqual(window.closeCount, 1)
        XCTAssertFalse(flags.willClose)
        XCTAssertTrue(proxy.windowShouldClose(window))
        XCTAssertEqual(
            matching(lines.values, prefix: "Review window close"),
            [
                "Review window close allowed: realtestduoBAK",
                "Review window close asked: realtestduoBAK",
                "Review window close asked: realtestduoBAK",
                "Review window close allowed: realtestduoBAK"
            ]
        )
    }
}

/// Selectors AppKit can ask a window delegate about, plus the private order
/// messages this app has already crashed on, plus names that do not exist.
private let delegateSelectors = [
    "windowShouldClose:",
    "windowWillResize:toSize:",
    "windowDidResize:",
    "windowWillStartLiveResize:",
    "windowDidEndLiveResize:",
    "windowWillMiniaturize:",
    "windowDidMiniaturize:",
    "windowDidDeminiaturize:",
    "windowWillClose:",
    "windowDidBecomeKey:",
    "windowDidResignKey:",
    "windowDidBecomeMain:",
    "windowDidResignMain:",
    "windowWillMove:",
    "windowDidMove:",
    "windowDidExpose:",
    "windowDidChangeScreen:",
    "windowDidChangeScreenProfile:",
    "windowDidChangeBackingProperties:",
    "windowDidUpdate:",
    "windowWillBeginSheet:",
    "windowDidEndSheet:",
    "window:willPositionSheet:usingRect:",
    "windowWillUseStandardFrame:defaultFrame:",
    "windowShouldZoom:toFrame:",
    "window:willEncodeRestorableState:",
    "window:didDecodeRestorableState:",
    "windowWillReturnFieldEditor:toObject:",
    "windowWillReturnUndoManager:",
    "window:shouldPopUpDocumentPathMenu:",
    "window:shouldDragDocumentWithEvent:from:withPasteboard:",
    "windowWillEnterFullScreen:",
    "windowDidEnterFullScreen:",
    "windowWillExitFullScreen:",
    "windowDidExitFullScreen:",
    "window:willUseFullScreenContentSize:",
    "window:willUseFullScreenPresentationOptions:",
    "customWindowsToEnterFullScreenForWindow:",
    "customWindowsToEnterFullScreenForWindow:onScreen:",
    "window:startCustomAnimationToEnterFullScreenWithDuration:",
    "window:startCustomAnimationToEnterFullScreenOnScreen:withDuration:",
    "customWindowsToExitFullScreenForWindow:",
    "window:startCustomAnimationToExitFullScreenWithDuration:",
    "windowDidFailToEnterFullScreen:",
    "windowDidFailToExitFullScreen:",
    "windowWillEnterVersionBrowser:",
    "windowDidEnterVersionBrowser:",
    "windowWillExitVersionBrowser:",
    "windowDidExitVersionBrowser:",
    "window:willResizeForVersionBrowserWithMaxPreferredSize:maxAllowedSize:",
    "windowDidChangeOcclusionState:",
    "previewRepresentableActivityItemsForWindow:",
    "windowForSharingRequestFromWindow:",
    "windowWillOrderOffScreen:",
    "windowDidOrderOffScreen:",
    "windowWillOrderOnScreen:",
    "windowDidOrderOnScreen:",
    "windowDidChangeSpace:",
    "reviewProxyAbsent:",
    "reviewProxyAbsent::"
]

/// `forwardingTarget(for:)` is `Any?`. Unwrap before the object cast.
private func object(_ value: Any?) -> AnyObject? {
    guard let value else { return nil }
    return value as AnyObject
}

/// Close also orders the window out, which can log between these lines.
private func matching(_ lines: [String], prefix: String) -> [String] {
    lines.filter { $0.hasPrefix(prefix) }
}

@MainActor
private func assertResizeSinks(_ proxy: ReviewWindowDelegateProxy, _ window: NSWindow, _ selector: Selector) {
    let signature = ReviewWindowDelegateProxyDescribe(proxy, selector)
    XCTAssertEqual(Int(signature.argumentCount), 4)
    XCTAssertEqual(Int(signature.returnLength), MemoryLayout<NSSize>.size)
    guard signature.argumentCount == 4,
          Int(signature.returnLength) == MemoryLayout<NSSize>.size else {
        return
    }
    let result = ReviewWindowDelegateProxyProbeResize(proxy, window, NSSize(width: 800, height: 600))
    XCTAssertEqual(result.width, 0, accuracy: 0.001)
    XCTAssertEqual(result.height, 0, accuracy: 0.001)
}

/// Sends a selector the proxy does not claim. Object arguments go through
/// `perform`; struct arguments still need a signature so the sink can run.
@MainActor
private func assertUnsignedSelectorCanBeSent(
    _ proxy: ReviewWindowDelegateProxy,
    _ name: String,
    _ window: NSWindow,
    _ coder: NSCoder
) {
    let selector = NSSelectorFromString(name)
    let signature = ReviewWindowDelegateProxyDescribe(proxy, selector)
    XCTAssertGreaterThan(signature.argumentCount, 0, name)
    guard signature.argumentCount > 2 else { return }
    if name == "windowShouldClose:" {
        XCTAssertTrue(proxy.responds(to: selector), name)
        _ = proxy.perform(selector, with: window)
        return
    }
    guard !proxy.responds(to: selector) else {
        XCTAssertNotNil(proxy.forwardingTarget(for: selector), name)
        return
    }
    XCTAssertNil(proxy.forwardingTarget(for: selector), name)
    let extras = Int(signature.argumentCount) - 2
    guard signature.objectArguments, extras > 0, extras <= 2 else { return }
    if extras == 1 {
        _ = proxy.perform(selector, with: window)
    } else if signature.returnLength == 0 {
        _ = proxy.perform(selector, with: window, with: coder)
    }
}

@MainActor
private final class CloseRecordingWindow: NSWindow {
    var closeCount = 0
    override func close() {
        closeCount += 1
    }
}

@MainActor
private func makeWindow(title: String) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: true
    )
    window.title = title
    return window
}

private final class Lines: @unchecked Sendable {
    var values: [String] = []
}

private final class Flags: @unchecked Sendable {
    var becameKey = false
    var willClose = false
    var asked = false
}

private final class EmptySwiftWindowDelegate: NSObject, NSWindowDelegate {}

private final class RecordingDelegate: NSObject, NSWindowDelegate {
    var calls: [String] = []
    var lastCoder: NSCoder?

    func windowDidResize(_ notification: Notification) { calls.append("resized") }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        calls.append("resize")
        return NSSize(width: 11, height: 22)
    }

    @objc(window:willEncodeRestorableState:)
    func window(_ window: NSWindow, willEncodeRestorableState coder: NSCoder) {
        calls.append("encode")
        lastCoder = coder
    }

    @objc(window:didDecodeRestorableState:)
    func window(_ window: NSWindow, didDecodeRestorableState coder: NSCoder) {
        calls.append("decode")
        lastCoder = coder
    }
}

/// Private selectors live outside the `NSWindowDelegate` conformance.
/// `windowDidChangeSpace` is close enough to `windowDidChangeScreen` that
/// Swift treats the in-class method as a mistaken protocol witness.
private extension RecordingDelegate {
    @objc(windowDidOrderOffScreen:)
    func windowDidOrderOffScreen(_ argument: Any) { calls.append("ordered off screen") }

    @objc(windowWillOrderOnScreen:)
    func windowWillOrderOnScreen(_ argument: Any) { calls.append("will order on screen") }

    @objc(windowDidChangeSpace:)
    func windowDidChangeSpace(_ argument: Any) { calls.append("space") }
}
