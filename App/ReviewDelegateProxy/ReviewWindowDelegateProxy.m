#import "ReviewWindowDelegateProxy.h"

@implementation ReviewWindowDelegateProxy {
    BOOL _allowClose;
}

- (id)wrappedDelegate {
    id wrapped = self.forwardingDelegate;
    if (wrapped == nil || wrapped == self) {
        return nil;
    }
    return wrapped;
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    // Only methods this class implements, or methods the wrapped delegate can run.
    // Do not inherit Swift's "yes" for every optional NSWindowDelegate method.
    if ([super respondsToSelector:aSelector]) {
        return YES;
    }
    id wrapped = [self wrappedDelegate];
    return wrapped != nil && [wrapped respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    // Our own methods must not be forwarded, or the call loops.
    if ([super respondsToSelector:aSelector]) {
        return nil;
    }
    id wrapped = [self wrappedDelegate];
    if (wrapped != nil && [wrapped respondsToSelector:aSelector]) {
        return wrapped;
    }
    return [super forwardingTargetForSelector:aSelector];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    NSMethodSignature *signature = [super methodSignatureForSelector:aSelector];
    if (signature != nil) {
        return signature;
    }
    id wrapped = [self wrappedDelegate];
    if (wrapped != nil && [wrapped respondsToSelector:aSelector]) {
        return [wrapped methodSignatureForSelector:aSelector];
    }
    return nil;
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    // Slow path used when AppKit looks up an IMP instead of objc_msgSend.
    // Same rule as forwardingTargetForSelector:.
    id wrapped = [self wrappedDelegate];
    SEL selector = invocation.selector;
    if (wrapped != nil && [wrapped respondsToSelector:selector]) {
        [invocation invokeWithTarget:wrapped];
        return;
    }
    [super forwardInvocation:invocation];
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

- (void)windowDidOrderOffScreen:(id)argument {
    [self emit:@"ordered off screen" window:[self windowFromArgument:argument]];
    [self forwardSelector:@selector(windowDidOrderOffScreen:) argument:argument];
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
    id wrapped = [self wrappedDelegate];
    if (wrapped == nil || ![wrapped respondsToSelector:selector]) {
        return;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [wrapped performSelector:selector withObject:argument];
#pragma clang diagnostic pop
}

@end
