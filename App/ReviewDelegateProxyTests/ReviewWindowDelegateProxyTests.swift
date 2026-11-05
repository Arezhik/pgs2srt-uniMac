import AppKit
import ReviewDelegateProxy
import XCTest

/// The minimize crash was `windowDidOrderOffScreen:` landing on a Swift proxy
/// that had answered `responds(to:)` and then had no Objective-C forwarder.
@MainActor
final class ReviewWindowDelegateProxyTests: XCTestCase {
    func testProxyDoesNotClaimOptionalDelegateMethodsItDoesNotImplement() {
        let proxy = ReviewWindowDelegateProxy()
        let optionalAndUnimplemented: [Selector] = [
            #selector(NSWindowDelegate.windowDidResize(_:)),
            #selector(NSWindowDelegate.windowDidMove(_:)),
            #selector(NSWindowDelegate.windowWillResize(_:to:)),
            #selector(NSWindowDelegate.windowDidEndLiveResize(_:)),
            NSSelectorFromString("windowDidChangeSpace:"),
            NSSelectorFromString("reviewProxyAbsent:")
        ]
        for selector in optionalAndUnimplemented {
            XCTAssertFalse(proxy.responds(to: selector), String(describing: selector))
            XCTAssertNil(proxy.forwardingTarget(for: selector))
        }
        // Real IMPs, including the private order-off/on selectors AppKit sends
        // around minimize. They answer yes because this class implements them.
        XCTAssertTrue(proxy.responds(to: #selector(NSWindowDelegate.windowDidMiniaturize(_:))))
        XCTAssertTrue(proxy.responds(to: NSSelectorFromString("windowDidOrderOffScreen:")))
        XCTAssertTrue(proxy.responds(to: NSSelectorFromString("windowDidOrderOnScreen:")))
        XCTAssertNil(proxy.forwardingTarget(for: #selector(NSWindowDelegate.windowDidMiniaturize(_:))))
    }

    func testPrivateAndPublicWindowEventsAreLoggedAndForwarded() {
        let proxy = ReviewWindowDelegateProxy()
        let recorder = RecordingDelegate()
        let lines = Lines()
        let flags = Flags()
        proxy.forwardingDelegate = recorder
        proxy.logEvent = { event, title in
            lines.values.append("Review window \(event): \(title)")
        }
        proxy.didBecomeKey = { flags.becameKey = true }
        proxy.willClose = { flags.willClose = true }

        let window = makeWindow(title: "pgs1")
        let note = Notification(name: Notification.Name("review-proxy-test"), object: window)
        let events: [(Selector, String)] = [
            (#selector(NSWindowDelegate.windowWillMiniaturize(_:)), "will minimize"),
            (#selector(NSWindowDelegate.windowDidResignKey(_:)), "resigned key"),
            (#selector(NSWindowDelegate.windowDidMiniaturize(_:)), "minimized"),
            (NSSelectorFromString("windowDidOrderOffScreen:"), "ordered off screen"),
            (NSSelectorFromString("windowDidOrderOnScreen:"), "ordered on screen"),
            (#selector(NSWindowDelegate.windowDidDeminiaturize(_:)), "restored"),
            (#selector(NSWindowDelegate.windowDidBecomeKey(_:)), "became key"),
            (#selector(NSWindowDelegate.windowWillEnterFullScreen(_:)), "will enter full screen"),
            (#selector(NSWindowDelegate.windowDidEnterFullScreen(_:)), "entered full screen"),
            (#selector(NSWindowDelegate.windowWillExitFullScreen(_:)), "will exit full screen"),
            (#selector(NSWindowDelegate.windowDidExitFullScreen(_:)), "exited full screen"),
            (#selector(NSWindowDelegate.windowDidChangeOcclusionState(_:)), "occlusion changed"),
            (#selector(NSWindowDelegate.windowDidChangeScreen(_:)), "screen changed"),
            (#selector(NSWindowDelegate.windowWillClose(_:)), "will close")
        ]

        for (selector, event) in events {
            XCTAssertTrue(proxy.responds(to: selector), event)
            XCTAssertNil(proxy.forwardingTarget(for: selector), event)
            proxy.perform(selector, with: note)
            XCTAssertEqual(lines.values.last, "Review window \(event): pgs1", event)
            XCTAssertEqual(recorder.calls.last, event, event)
        }
        XCTAssertTrue(flags.becameKey)
        XCTAssertTrue(flags.willClose)

        // A private selector this proxy does not implement still has to move,
        // unchanged, to the wrapped delegate. That is what keeps a future
        // AppKit callback from raising unrecognized selector here.
        let space = NSSelectorFromString("windowDidChangeSpace:")
        XCTAssertFalse(ReviewWindowDelegateProxy().responds(to: space))
        XCTAssertTrue(proxy.responds(to: space))
        let forwarded = object(proxy.forwardingTarget(for: space))
        XCTAssertTrue(forwarded === recorder)
        proxy.perform(space, with: note)
        XCTAssertEqual(recorder.calls.last, "space")
        XCTAssertEqual(lines.values.last, "Review window will close: pgs1")

        let absent = NSSelectorFromString("reviewProxyAbsent:")
        XCTAssertFalse(recorder.responds(to: absent))
        XCTAssertFalse(proxy.responds(to: absent))
        XCTAssertNil(proxy.forwardingTarget(for: absent))
    }

    func testOrderOffScreenAcceptsANotificationOrTheWindow() {
        let proxy = ReviewWindowDelegateProxy()
        let recorder = RecordingDelegate()
        let lines = Lines()
        proxy.forwardingDelegate = recorder
        proxy.logEvent = { event, title in
            lines.values.append("Review window \(event): \(title)")
        }
        let window = makeWindow(title: "pgs1")
        let off = NSSelectorFromString("windowDidOrderOffScreen:")
        proxy.perform(off, with: window)
        XCTAssertEqual(lines.values, ["Review window ordered off screen: pgs1"])
        XCTAssertEqual(recorder.calls, ["ordered off screen"])

        let on = NSSelectorFromString("windowDidOrderOnScreen:")
        let note = Notification(name: Notification.Name("ordered-on"), object: window)
        proxy.perform(on, with: note)
        XCTAssertEqual(lines.values.last, "Review window ordered on screen: pgs1")
        XCTAssertEqual(recorder.calls.last, "ordered on screen")
    }

    func testWrappedSwiftDelegateIsForwardedOnlyWhenItResponds() {
        let proxy = ReviewWindowDelegateProxy()
        let empty = EmptySwiftWindowDelegate()
        let resize = #selector(NSWindowDelegate.windowDidResize(_:))
        XCTAssertFalse(proxy.responds(to: resize))
        proxy.forwardingDelegate = empty
        XCTAssertEqual(proxy.responds(to: resize), empty.responds(to: resize))
        if empty.responds(to: resize) {
            let forwarded = object(proxy.forwardingTarget(for: resize))
            XCTAssertTrue(forwarded === empty)
        } else {
            XCTAssertNil(proxy.forwardingTarget(for: resize))
        }
    }

    func testClosePromptAllowsACleanWindowAndDefersADirtyOne() {
        let proxy = ReviewWindowDelegateProxy()
        let lines = Lines()
        let flags = Flags()
        proxy.logEvent = { event, title in
            lines.values.append("Review window \(event): \(title)")
        }
        let window = makeWindow(title: "realtestduoBAK")
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
        XCTAssertFalse(proxy.windowShouldClose(window))
        XCTAssertTrue(flags.willClose)
        XCTAssertEqual(
            matching(lines.values, prefix: "Review window close"),
            [
                "Review window close allowed: realtestduoBAK",
                "Review window close asked: realtestduoBAK",
                "Review window close asked: realtestduoBAK",
                "Review window close allowed: realtestduoBAK"
            ]
        )
        XCTAssertTrue(lines.values.contains("Review window will close: realtestduoBAK"))
    }
}

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

    func windowDidBecomeKey(_ notification: Notification) { calls.append("became key") }
    func windowDidResignKey(_ notification: Notification) { calls.append("resigned key") }
    func windowWillMiniaturize(_ notification: Notification) { calls.append("will minimize") }
    func windowDidMiniaturize(_ notification: Notification) { calls.append("minimized") }
    func windowDidDeminiaturize(_ notification: Notification) { calls.append("restored") }
    func windowWillClose(_ notification: Notification) { calls.append("will close") }
    func windowWillEnterFullScreen(_ notification: Notification) { calls.append("will enter full screen") }
    func windowDidEnterFullScreen(_ notification: Notification) { calls.append("entered full screen") }
    func windowWillExitFullScreen(_ notification: Notification) { calls.append("will exit full screen") }
    func windowDidExitFullScreen(_ notification: Notification) { calls.append("exited full screen") }
    func windowDidChangeOcclusionState(_ notification: Notification) { calls.append("occlusion changed") }
    func windowDidChangeScreen(_ notification: Notification) { calls.append("screen changed") }

    @objc(windowDidOrderOffScreen:)
    func windowDidOrderOffScreen(_ argument: Any) { calls.append("ordered off screen") }

    @objc(windowDidOrderOnScreen:)
    func windowDidOrderOnScreen(_ argument: Any) { calls.append("ordered on screen") }

    @objc(windowDidChangeSpace:)
    func windowDidChangeSpace(_ argument: Any) { calls.append("space") }
}
