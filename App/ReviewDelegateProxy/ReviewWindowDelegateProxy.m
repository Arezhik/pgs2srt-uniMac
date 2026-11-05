#import "ReviewWindowDelegateProxy.h"
#import <objc/runtime.h>

static BOOL ReviewProxyImplementsSelector(id self, SEL selector) {
    if (selector == NULL) {
        return NO;
    }
    // The method list only. NSObject's respondsToSelector: is the wrong
    // question once this object forwards: it can answer yes, then
    // forwardingTargetForSelector: returns nil and AppKit raises
    // doesNotRecognizeSelector: on this proxy. That is the Dock-restore
    // crash on windowWillOrderOnScreen:.
    return class_respondsToSelector(object_getClass(self), selector);
}

@implementation ReviewWindowDelegateProxy {
    BOOL _allowClose;
}

/// The wrapped delegate right now. Nil if it was released or points at us.
- (id)liveWrappedDelegate {
    id wrapped = self.forwardingDelegate;
    if (wrapped == nil || wrapped == self) {
        return nil;
    }
    return wrapped;
}

/// Nil when this class implements `selector` or the wrapped delegate cannot take it.
- (id)targetForSelector:(SEL)selector {
    if (ReviewProxyImplementsSelector(self, selector)) {
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
    if (ReviewProxyImplementsSelector(self, selector)) {
        return YES;
    }
    // Same object forwarding will use. A gone or unsigned target is NO.
    return [self targetForSelector:selector] != nil;
}

- (id)forwardingTargetForSelector:(SEL)selector {
    return [self targetForSelector:selector];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if (ReviewProxyImplementsSelector(self, selector)) {
        return [super methodSignatureForSelector:selector];
    }
    id wrapped = [self targetForSelector:selector];
    if (wrapped == nil) {
        return nil;
    }
    return [wrapped methodSignatureForSelector:selector];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    // Slow path. Do not call super: that raises doesNotRecognizeSelector:.
    id wrapped = [self targetForSelector:invocation.selector];
    if (wrapped != nil) {
        [invocation invokeWithTarget:wrapped];
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

- (void)windowDidBecomeKey:(NSNotification *)notification {
    [self emit:@"became key" notification:notification];
    if (self.didBecomeKey != nil) {
        self.didBecomeKey();
    }
    [self forwardSelector:@selector(windowDidBecomeKey:) argument:notification];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    [self emit:@"resigned key" notification:notification];
    [self forwardSelector:@selector(windowDidResignKey:) argument:notification];
}

- (void)windowWillMiniaturize:(NSNotification *)notification {
    [self emit:@"will minimize" notification:notification];
    [self forwardSelector:@selector(windowWillMiniaturize:) argument:notification];
}

- (void)windowDidMiniaturize:(NSNotification *)notification {
    [self emit:@"minimized" notification:notification];
    [self forwardSelector:@selector(windowDidMiniaturize:) argument:notification];
}

- (void)windowDidDeminiaturize:(NSNotification *)notification {
    [self emit:@"restored" notification:notification];
    [self forwardSelector:@selector(windowDidDeminiaturize:) argument:notification];
}

- (void)windowWillOrderOffScreen:(id)argument {
    [self emit:@"will order off screen" window:[self windowFromArgument:argument]];
    [self forwardSelector:@selector(windowWillOrderOffScreen:) argument:argument];
}

- (void)windowDidOrderOffScreen:(id)argument {
    [self emit:@"ordered off screen" window:[self windowFromArgument:argument]];
    [self forwardSelector:@selector(windowDidOrderOffScreen:) argument:argument];
}

- (void)windowWillOrderOnScreen:(id)argument {
    [self emit:@"will order on screen" window:[self windowFromArgument:argument]];
    [self forwardSelector:@selector(windowWillOrderOnScreen:) argument:argument];
}

- (void)windowDidOrderOnScreen:(id)argument {
    [self emit:@"ordered on screen" window:[self windowFromArgument:argument]];
    [self forwardSelector:@selector(windowDidOrderOnScreen:) argument:argument];
}

- (void)windowWillClose:(NSNotification *)notification {
    [self emit:@"will close" notification:notification];
    if (self.willClose != nil) {
        self.willClose();
    }
    [self forwardSelector:@selector(windowWillClose:) argument:notification];
}

- (void)windowWillEnterFullScreen:(NSNotification *)notification {
    [self emit:@"will enter full screen" notification:notification];
    [self forwardSelector:@selector(windowWillEnterFullScreen:) argument:notification];
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification {
    [self emit:@"entered full screen" notification:notification];
    [self forwardSelector:@selector(windowDidEnterFullScreen:) argument:notification];
}

- (void)windowWillExitFullScreen:(NSNotification *)notification {
    [self emit:@"will exit full screen" notification:notification];
    [self forwardSelector:@selector(windowWillExitFullScreen:) argument:notification];
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
    [self emit:@"exited full screen" notification:notification];
    [self forwardSelector:@selector(windowDidExitFullScreen:) argument:notification];
}

- (void)windowDidChangeOcclusionState:(NSNotification *)notification {
    [self emit:@"occlusion changed" notification:notification];
    [self forwardSelector:@selector(windowDidChangeOcclusionState:) argument:notification];
}

- (void)windowDidChangeScreen:(NSNotification *)notification {
    [self emit:@"screen changed" notification:notification];
    [self forwardSelector:@selector(windowDidChangeScreen:) argument:notification];
}

- (NSWindow *)windowFromArgument:(id)argument {
    if ([argument isKindOfClass:[NSNotification class]]) {
        id object = [(NSNotification *)argument object];
        if ([object isKindOfClass:[NSWindow class]]) {
            return object;
        }
        return nil;
    }
    if ([argument isKindOfClass:[NSWindow class]]) {
        return argument;
    }
    return nil;
}

- (void)emit:(NSString *)event notification:(NSNotification *)notification {
    NSWindow *window = [self windowFromArgument:notification];
    [self emit:event window:window];
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

- (void)forwardSelector:(SEL)selector argument:(id)argument {
    // Our IMP is running, so targetForSelector: would refuse to forward it.
    id wrapped = [self liveWrappedDelegate];
    if (wrapped == nil || ![wrapped respondsToSelector:selector]) {
        return;
    }
    if ([wrapped methodSignatureForSelector:selector] == nil) {
        return;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [wrapped performSelector:selector withObject:argument];
#pragma clang diagnostic pop
}

@end
