#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Close interceptor for the review window.
///
/// The window keeps its delegate weakly, and AppKit remembers which selectors
/// that delegate answered at `setDelegate:` time. This object therefore keeps
/// SwiftUI's original delegate for its own lifetime and answers `windowShouldClose:`.
/// Every other message is handed to that delegate. A message AppKit still sends
/// after the original delegate is gone gets a real method signature and is ignored,
/// so it cannot raise `doesNotRecognizeSelector:`.
///
/// Logging does not go through delegate methods. `attachToWindow:` watches the
/// window's notifications, including the private order-on and order-off names.
@interface ReviewWindowDelegateProxy : NSObject <NSWindowDelegate>

/// SwiftUI's delegate from before this interceptor took the window.
/// Strong on purpose: a weak reference is what made later AppKit callbacks crash.
@property (nonatomic, strong, nullable) id<NSWindowDelegate> forwardingDelegate;

@property (nonatomic, copy, nullable) void (^logEvent)(NSString *event, NSString *title);
@property (nonatomic, copy, nullable) BOOL (^isDirty)(void);
/// Shows the save prompt. Call `decision(YES)` to close.
@property (nonatomic, copy, nullable) void (^attemptClose)(void (^decision)(BOOL allow));
@property (nonatomic, copy, nullable) void (^didBecomeKey)(void);
@property (nonatomic, copy, nullable) void (^willClose)(void);

/// Installs this interceptor, turns restoration off, and starts logging.
- (void)attachToWindow:(NSWindow *)window NS_SWIFT_NAME(attach(to:));

/// Stops logging and releases the forwarded delegate.
- (void)detach;

@end

/// Private AppKit notification names. Observed as strings so the app does not
/// link the SPI symbols. The string values match those symbols.
FOUNDATION_EXPORT NSNotificationName const ReviewWindowWillOrderOffScreenNotification;
FOUNDATION_EXPORT NSNotificationName const ReviewWindowDidOrderOffScreenNotification;
FOUNDATION_EXPORT NSNotificationName const ReviewWindowWillOrderOnScreenNotification;
FOUNDATION_EXPORT NSNotificationName const ReviewWindowDidOrderOnScreenNotification;

/// Test support. Sends the selector through the normal message path, including
/// when `respondsToSelector:` is NO, which is what a stale AppKit cache does.
void ReviewWindowDelegateProxyProbeEncode(id target, NSWindow *window, NSCoder *coder);
NSSize ReviewWindowDelegateProxyProbeResize(id target, NSWindow *window, NSSize proposed);

NS_ASSUME_NONNULL_END
