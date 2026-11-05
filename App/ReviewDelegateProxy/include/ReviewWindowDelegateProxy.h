#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Window delegate that owns the close prompt and forwards every other message.
///
/// Implemented in Objective-C on purpose. `respondsToSelector:` is true only
/// when this class has a real method, or the wrapped delegate currently
/// responds and can supply a method signature. Forwarding reads that same
/// delegate again at call time. A nil delegate is a no, never a yes.
/// Dock restore sends the private `windowWillOrderOnScreen:`.
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
