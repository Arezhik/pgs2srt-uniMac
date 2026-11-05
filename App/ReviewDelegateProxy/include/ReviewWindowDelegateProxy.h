#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Window delegate that owns the close prompt and forwards every other message.
///
/// Implemented in Objective-C on purpose. A Swift `NSWindowDelegate` reports
/// that it responds to selectors it cannot run, and Swift's
/// `forwardingTarget(for:)` is not the hook the Objective-C runtime calls.
/// Minimize then sends the private `windowDidOrderOffScreen:` and AppKit
/// raises NSInvalidArgumentException.
@interface ReviewWindowDelegateProxy : NSObject <NSWindowDelegate>

/// The SwiftUI delegate that was on the window before this proxy.
@property (nonatomic, weak, nullable) id<NSWindowDelegate> forwardingDelegate;

@property (nonatomic, copy, nullable) void (^logEvent)(NSString *event, NSString *title);
@property (nonatomic, copy, nullable) BOOL (^isDirty)(void);
/// Shows the save prompt. Call `decision(YES)` to close.
@property (nonatomic, copy, nullable) void (^attemptClose)(void (^decision)(BOOL allow));
@property (nonatomic, copy, nullable) void (^didBecomeKey)(void);
@property (nonatomic, copy, nullable) void (^willClose)(void);

@end

NS_ASSUME_NONNULL_END
