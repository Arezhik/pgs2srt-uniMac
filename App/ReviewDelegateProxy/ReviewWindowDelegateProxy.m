#import "ReviewWindowDelegateProxy.h"
#import <objc/runtime.h>

NSNotificationName const ReviewWindowWillOrderOffScreenNotification = @"NSWindowWillOrderOffScreenNotification";
NSNotificationName const ReviewWindowDidOrderOffScreenNotification = @"NSWindowDidOrderOffScreenNotification";
NSNotificationName const ReviewWindowWillOrderOnScreenNotification = @"NSWindowWillOrderOnScreenNotification";
NSNotificationName const ReviewWindowDidOrderOnScreenNotification = @"NSWindowDidOrderOnScreenNotification";

static BOOL ReviewProxyImplementsSelector(id self, SEL selector) {
    if (selector == NULL) {
        return NO;
    }
    // Real methods only. NSObject's own respondsToSelector: walks forwarding
    // and can answer yes for a selector this object cannot run.
    return class_respondsToSelector(object_getClass(self), selector);
}

static NSMethodSignature *ReviewProtocolSignature(SEL selector) {
    Protocol *protocol = @protocol(NSWindowDelegate);
    struct objc_method_description description = protocol_getMethodDescription(protocol, selector, NO, YES);
    if (description.types == NULL) {
        description = protocol_getMethodDescription(protocol, selector, YES, YES);
    }
    if (description.types == NULL) {
        return nil;
    }
    return [NSMethodSignature signatureWithObjCTypes:description.types];
}

/// Object arguments, one per colon. Public methods with struct arguments get
/// their real encoding from `NSWindowDelegate` instead. This fallback is for
/// private callbacks such as `windowWillOrderOnScreen:`.
static NSMethodSignature *ReviewFallbackSignature(SEL selector) {
    NSString *name = NSStringFromSelector(selector);
    NSUInteger colons = 0;
    for (NSUInteger index = 0; index < name.length; index++) {
        if ([name characterAtIndex:index] == ':') {
            colons++;
        }
    }
    if (colons > 12) {
        colons = 12;
    }
    char types[16];
    types[0] = 'v';
    types[1] = '@';
    types[2] = ':';
    for (NSUInteger index = 0; index < colons; index++) {
        types[3 + index] = '@';
    }
    types[3 + colons] = '\0';
    return [NSMethodSignature signatureWithObjCTypes:types];
}

static NSArray<NSNotificationName> *ReviewObservedNames(void) {
    static NSArray<NSNotificationName> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[
            NSWindowWillMiniaturizeNotification,
            NSWindowDidMiniaturizeNotification,
            NSWindowDidDeminiaturizeNotification,
            NSWindowDidBecomeKeyNotification,
            NSWindowDidResignKeyNotification,
            NSWindowWillCloseNotification,
            NSWindowWillEnterFullScreenNotification,
            NSWindowDidEnterFullScreenNotification,
            NSWindowWillExitFullScreenNotification,
            NSWindowDidExitFullScreenNotification,
            NSWindowDidChangeOcclusionStateNotification,
            NSWindowDidChangeScreenNotification,
            ReviewWindowWillOrderOffScreenNotification,
            ReviewWindowDidOrderOffScreenNotification,
            ReviewWindowWillOrderOnScreenNotification,
            ReviewWindowDidOrderOnScreenNotification
        ];
    });
    return names;
}

static NSString *ReviewEventForNotification(NSNotificationName name) {
    if ([name isEqualToString:NSWindowWillMiniaturizeNotification]) return @"will minimize";
    if ([name isEqualToString:NSWindowDidMiniaturizeNotification]) return @"minimized";
    if ([name isEqualToString:NSWindowDidDeminiaturizeNotification]) return @"restored";
    if ([name isEqualToString:NSWindowDidBecomeKeyNotification]) return @"became key";
    if ([name isEqualToString:NSWindowDidResignKeyNotification]) return @"resigned key";
    if ([name isEqualToString:NSWindowWillCloseNotification]) return @"will close";
    if ([name isEqualToString:NSWindowWillEnterFullScreenNotification]) return @"will enter full screen";
    if ([name isEqualToString:NSWindowDidEnterFullScreenNotification]) return @"entered full screen";
    if ([name isEqualToString:NSWindowWillExitFullScreenNotification]) return @"will exit full screen";
    if ([name isEqualToString:NSWindowDidExitFullScreenNotification]) return @"exited full screen";
    if ([name isEqualToString:NSWindowDidChangeOcclusionStateNotification]) return @"occlusion changed";
    if ([name isEqualToString:NSWindowDidChangeScreenNotification]) return @"screen changed";
    if ([name isEqualToString:ReviewWindowWillOrderOffScreenNotification]) return @"will order off screen";
    if ([name isEqualToString:ReviewWindowDidOrderOffScreenNotification]) return @"ordered off screen";
    if ([name isEqualToString:ReviewWindowWillOrderOnScreenNotification]) return @"will order on screen";
    if ([name isEqualToString:ReviewWindowDidOrderOnScreenNotification]) return @"ordered on screen";
    return nil;
}

@interface NSObject (ReviewWindowDelegateProxyProbe)
- (void)window:(NSWindow *)window willEncodeRestorableState:(NSCoder *)coder;
- (NSSize)windowWillResize:(NSWindow *)window toSize:(NSSize)proposed;
@end

void ReviewWindowDelegateProxyProbeEncode(id target, NSWindow *window, NSCoder *coder) {
    [target window:window willEncodeRestorableState:coder];
}

NSSize ReviewWindowDelegateProxyProbeResize(id target, NSWindow *window, NSSize proposed) {
    return [target windowWillResize:window toSize:proposed];
}

@implementation ReviewWindowDelegateProxy {
    BOOL _allowClose;
    NSUInteger _observationGeneration;
    NSMutableArray *_observationTokens;
    __weak NSWindow *_observingWindow;
}

- (id)liveWrappedDelegate {
    id wrapped = self.forwardingDelegate;
    if (wrapped == nil || wrapped == self) {
        return nil;
    }
    return wrapped;
}

/// Nil when this class implements `selector` or the wrapped delegate cannot take it.
- (id)wrappedTargetForSelector:(SEL)selector {
    if (selector == NULL || ReviewProxyImplementsSelector(self, selector)) {
        return nil;
    }
    id wrapped = [self liveWrappedDelegate];
    if (wrapped == nil || ![wrapped respondsToSelector:selector]) {
        return nil;
    }
    if ([wrapped methodSignatureForSelector:selector] == nil) {
        return nil;
    }
    return wrapped;
}

- (BOOL)respondsToSelector:(SEL)selector {
    if (selector == NULL) {
        return NO;
    }
    if (ReviewProxyImplementsSelector(self, selector)) {
        return YES;
    }
    return [self wrappedTargetForSelector:selector] != nil;
}

- (id)forwardingTargetForSelector:(SEL)selector {
    return [self wrappedTargetForSelector:selector];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if (selector == NULL) {
        return nil;
    }
    if (ReviewProxyImplementsSelector(self, selector)) {
        return [super methodSignatureForSelector:selector];
    }
    id wrapped = [self wrappedTargetForSelector:selector];
    if (wrapped != nil) {
        NSMethodSignature *signature = [wrapped methodSignatureForSelector:selector];
        if (signature != nil) {
            return signature;
        }
    }
    // A cached "yes" from setDelegate: can arrive after the wrapped delegate
    // is gone. Returning nil here is the unrecognized-selector crash.
    NSMethodSignature *signature = ReviewProtocolSignature(selector);
    if (signature != nil) {
        return signature;
    }
    return ReviewFallbackSignature(selector);
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    id wrapped = [self wrappedTargetForSelector:invocation.selector];
    if (wrapped != nil) {
        [invocation invokeWithTarget:wrapped];
        return;
    }
    NSUInteger length = invocation.methodSignature.methodReturnLength;
    if (length == 0) {
        return;
    }
    // Zero the return. A stale caller may read it; garbage is worse.
    char stack[128];
    void *buffer = stack;
    void *heap = NULL;
    if (length > sizeof(stack)) {
        heap = calloc(1, length);
        if (heap == NULL) {
            return;
        }
        buffer = heap;
    } else {
        memset(stack, 0, length);
    }
    [invocation setReturnValue:buffer];
    free(heap);
}

- (void)attachToWindow:(NSWindow *)window {
    if (window == nil) {
        return;
    }
    // Review state is not a document to resume. Leaving this on makes AppKit
    // call window:willEncodeRestorableState: on a delay after minimize.
    // Skip a redundant write; the edited-dot flag has the same constraint.
    if (window.isRestorable) {
        window.restorable = NO;
    }
    // Remember SwiftUI's delegate before setDelegate:. AppKit caches the
    // answers it gets during that call, and may post notes before it returns.
    if (window.delegate != self) {
        id previous = window.delegate;
        if (previous != nil) {
            self.forwardingDelegate = previous;
        }
    }
    if (_observingWindow != window || _observationTokens.count == 0) {
        [self startObservingWindow:window];
    }
    if (window.delegate != self) {
        window.delegate = self;
    }
}

- (void)detach {
    [self stopObserving];
    self.forwardingDelegate = nil;
}

- (void)startObservingWindow:(NSWindow *)window {
    _observationGeneration += 1;
    NSUInteger generation = _observationGeneration;
    NSArray *previous = _observationTokens;
    _observationTokens = [NSMutableArray array];
    _observingWindow = window;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (NSNotificationName name in ReviewObservedNames()) {
        __weak typeof(self) weakSelf = self;
        id token = [center addObserverForName:name object:window queue:nil usingBlock:^(NSNotification *note) {
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf->_observationGeneration != generation) {
                return;
            }
            [strongSelf reviewNote:note];
        }];
        if (token != nil) {
            [_observationTokens addObject:token];
        }
    }
    [self retireObservationTokens:previous];
}

- (void)stopObserving {
    _observationGeneration += 1;
    _observingWindow = nil;
    NSArray *previous = _observationTokens;
    _observationTokens = [NSMutableArray array];
    [self retireObservationTokens:previous];
}

/// Drops tokens on the next turn. Removing them inside the note they just
/// delivered mutates the center while it is still posting.
- (void)retireObservationTokens:(NSArray *)tokens {
    if (tokens.count == 0) {
        return;
    }
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    dispatch_async(dispatch_get_main_queue(), ^{
        for (id token in tokens) {
            [center removeObserver:token];
        }
    });
}

- (void)dealloc {
    _observationGeneration += 1;
    NSArray *tokens = _observationTokens;
    _observationTokens = nil;
    if (tokens.count == 0) {
        return;
    }
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    dispatch_async(dispatch_get_main_queue(), ^{
        for (id token in tokens) {
            [center removeObserver:token];
        }
    });
}

- (void)reviewNote:(NSNotification *)note {
    NSString *event = ReviewEventForNotification(note.name);
    NSWindow *window = [note.object isKindOfClass:[NSWindow class]] ? note.object : nil;
    if (event != nil) {
        [self emit:event window:window];
    }
    if ([note.name isEqualToString:NSWindowDidBecomeKeyNotification] && self.didBecomeKey != nil) {
        self.didBecomeKey();
    }
    if ([note.name isEqualToString:NSWindowWillCloseNotification]) {
        if (self.willClose != nil) {
            self.willClose();
        }
        // The close callbacks on this turn still need the forwarded delegate.
        // Dropping it afterward breaks a cycle if that delegate holds the window.
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.forwardingDelegate = nil;
        });
    }
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (_allowClose) {
        _allowClose = NO;
        [self emit:@"close allowed" window:sender];
        return YES;
    }
    if (self.isDirty == nil || !self.isDirty()) {
        [self emit:@"close allowed" window:sender];
        return YES;
    }
    [self emit:@"close asked" window:sender];
    void (^attempt)(void (^)(BOOL)) = self.attemptClose;
    if (attempt == nil) {
        return NO;
    }
    __weak typeof(self) weakSelf = self;
    __weak NSWindow *weakWindow = sender;
    attempt(^(BOOL allow) {
        if (!allow) {
            return;
        }
        typeof(self) strongSelf = weakSelf;
        NSWindow *window = weakWindow;
        if (strongSelf == nil || window == nil) {
            return;
        }
        strongSelf->_allowClose = YES;
        [window close];
    });
    return NO;
}

- (void)emit:(NSString *)event window:(NSWindow *)window {
    if (self.logEvent == nil) {
        return;
    }
    NSString *title = window.title;
    if (title.length == 0) {
        title = @"review";
    }
    self.logEvent(event, title);
}

@end
