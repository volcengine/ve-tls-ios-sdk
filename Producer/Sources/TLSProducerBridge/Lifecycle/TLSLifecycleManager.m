// TLSLifecycleManager.m
// TLSProducerBridge/Lifecycle
//

#import "TLSLifecycleManager.h"

#import <objc/message.h>
#import <objc/runtime.h>

NSNotificationName const TLSLifecycleDidEnterBackgroundNotificationName =
    @"UIApplicationDidEnterBackgroundNotification";
NSNotificationName const TLSLifecycleWillEnterForegroundNotificationName =
    @"UIApplicationWillEnterForegroundNotification";

// UIKit's UIBackgroundTaskInvalid is zero. Keep this target UIKit-link-free;
// iOS tests compare this sentinel with the actual framework constant.
const NSUInteger TLSLifecycleInvalidBackgroundTaskIdentifier = 0;

static NSString *const kTLSBackgroundTaskName =
    @"com.volcengine.tls.producer.flush";

#pragma mark - TLSDefaultLifecycleHost

@implementation TLSDefaultLifecycleHost

- (NSUInteger)beginBackgroundTaskWithName:(NSString *)name
                        expirationHandler:(void (^)(void))expirationHandler {
    // UIApplication is reached through the runtime so this target never links
    // UIKit. TLSLifecycleManager guarantees this path is only taken in app
    // processes (extensionCheck gates all host calls); sharedApplication is
    // forbidden in App Extensions.
    Class uiApplicationClass = NSClassFromString(@"UIApplication");
    if (uiApplicationClass == Nil) {
        return TLSLifecycleInvalidBackgroundTaskIdentifier;
    }
    id sharedApplication =
        ((id (*)(id, SEL))objc_msgSend)(uiApplicationClass,
                                        NSSelectorFromString(@"sharedApplication"));
    if (sharedApplication == nil) {
        return TLSLifecycleInvalidBackgroundTaskIdentifier;
    }
    SEL beginSelector =
        NSSelectorFromString(@"beginBackgroundTaskWithName:expirationHandler:");
    if (![sharedApplication respondsToSelector:beginSelector]) {
        return TLSLifecycleInvalidBackgroundTaskIdentifier;
    }
    typedef NSUInteger (*TLSBeginBackgroundTaskIMP)(id, SEL, NSString *,
                                                    void (^)(void));
    TLSBeginBackgroundTaskIMP beginIMP =
        (TLSBeginBackgroundTaskIMP)objc_msgSend;
    return beginIMP(sharedApplication, beginSelector, name, expirationHandler);
}

- (void)endBackgroundTask:(NSUInteger)identifier {
    if (identifier == TLSLifecycleInvalidBackgroundTaskIdentifier) {
        return;
    }
    Class uiApplicationClass = NSClassFromString(@"UIApplication");
    if (uiApplicationClass == Nil) {
        return;
    }
    id sharedApplication =
        ((id (*)(id, SEL))objc_msgSend)(uiApplicationClass,
                                        NSSelectorFromString(@"sharedApplication"));
    if (sharedApplication == nil) {
        return;
    }
    SEL endSelector = NSSelectorFromString(@"endBackgroundTask:");
    if (![sharedApplication respondsToSelector:endSelector]) {
        return;
    }
    typedef void (*TLSEndBackgroundTaskIMP)(id, SEL, NSUInteger);
    TLSEndBackgroundTaskIMP endIMP = (TLSEndBackgroundTaskIMP)objc_msgSend;
    endIMP(sharedApplication, endSelector, identifier);
}

@end

#pragma mark - TLSLifecycleManager

@interface TLSLifecycleManager ()

@property (nonatomic, copy) void (^flushHandler)(void);
@property (nonatomic, copy) void (^wakeHandler)(void);
@property (nonatomic, strong, nullable) id<TLSLifecycleHost> host;
@property (nonatomic, assign) NSUInteger backgroundTaskIdentifier;
@property (nonatomic, assign, getter=isExtensionProcess) BOOL extensionProcess;
@property (nonatomic, assign) BOOL observersRegistered;

- (void)tls_registerObservers;
- (void)tls_endOutstandingBackgroundTask;
- (void)tls_endBackgroundTaskIfCurrent:(NSUInteger)taskIdentifier;

@end

@implementation TLSLifecycleManager

- (instancetype)initWithFlushHandler:(void (^)(void))flushHandler
                         wakeHandler:(void (^)(void))wakeHandler
                                host:(id<TLSLifecycleHost>)host
                      extensionCheck:(TLSExtensionCheckBlock)extensionCheck {
    self = [super init];
    if (self) {
        _flushHandler = [flushHandler copy];
        _wakeHandler = [wakeHandler copy];
        _host = host;
        _backgroundTaskIdentifier = TLSLifecycleInvalidBackgroundTaskIdentifier;

        TLSExtensionCheckBlock check = extensionCheck;
        if (check == nil) {
            check = ^BOOL{
                return [[NSBundle mainBundle] infoDictionary][@"NSExtension"] != nil;
            };
        }
        _extensionProcess = check();

        // Extension processes: no notifications, no UIApplication calls —
        // everything stays a no-op for the lifetime of the instance.
        if (!_extensionProcess) {
            [self tls_registerObservers];
        }
    }
    return self;
}

- (instancetype)initWithFlushHandler:(void (^)(void))flushHandler
                         wakeHandler:(void (^)(void))wakeHandler {
    return [self initWithFlushHandler:flushHandler
                          wakeHandler:wakeHandler
                                 host:[[TLSDefaultLifecycleHost alloc] init]
                       extensionCheck:nil];
}

- (void)dealloc {
    // The selector-based observer API does not retain the observer; leaving
    // observers registered would crash on the next notification.
    if (_observersRegistered) {
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
    if (_backgroundTaskIdentifier != TLSLifecycleInvalidBackgroundTaskIdentifier) {
        [_host endBackgroundTask:_backgroundTaskIdentifier];
        _backgroundTaskIdentifier = TLSLifecycleInvalidBackgroundTaskIdentifier;
    }
}

#pragma mark - Notifications

- (void)tls_registerObservers {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(tls_handleDidEnterBackground:)
                   name:TLSLifecycleDidEnterBackgroundNotificationName
                 object:nil];
    [center addObserver:self
               selector:@selector(tls_handleWillEnterForeground:)
                   name:TLSLifecycleWillEnterForegroundNotificationName
                 object:nil];
    self.observersRegistered = YES;
}

- (void)tls_handleDidEnterBackground:(NSNotification *)notification {
    if (self.extensionProcess) {
        return;
    }

    // Request the background task before doing any work: the system may suspend the process
    // shortly after backgrounding, so the wrap-up window must be claimed
    // first. End a stale task before requesting a new one — background
    // tasks are a finite system resource and must always be paired.
    [self tls_endOutstandingBackgroundTask];

    id<TLSLifecycleHost> host = self.host;
    if (host != nil) {
        // The expiration handler ends the task IMMEDIATELY instead of
        // continuing to block system suspension. WAL is preserved by the
        // Core; this helper does not promise unlimited background upload.
        __weak typeof(self) weakSelf = self;
        __block NSUInteger taskIdentifier = TLSLifecycleInvalidBackgroundTaskIdentifier;
        taskIdentifier =
            [host beginBackgroundTaskWithName:kTLSBackgroundTaskName
                            expirationHandler:^{
            NSUInteger expiredTaskIdentifier = taskIdentifier;
            dispatch_block_t endExpiredTask = ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf == nil) {
                    return;
                }
                [strongSelf tls_endBackgroundTaskIfCurrent:expiredTaskIdentifier];
            };
            if ([NSThread isMainThread]) {
                endExpiredTask();
            } else {
                dispatch_async(dispatch_get_main_queue(), endExpiredTask);
            }
        }];
        self.backgroundTaskIdentifier = taskIdentifier;
    }

    // Best-effort flush: the handler triggers the Core's flush path; it does
    // not block until remote delivery. Runs even when no
    // background task was granted (invalid identifier) — flush is
    // best-effort and does not depend on the task.
    void (^flush)(void) = self.flushHandler;
    if (flush != nil) {
        flush();
    }
}

- (void)tls_handleWillEnterForeground:(NSNotification *)notification {
    if (self.extensionProcess) {
        return;
    }

    // Wake the Core sender / recoverable retry. This does not rely on
    // Reachability: foregrounding is the signal to retry, not a guarantee
    // that the network is available.
    void (^wake)(void) = self.wakeHandler;
    if (wake != nil) {
        wake();
    }

    // The task was only needed for background wrap-up; release it now.
    [self tls_endOutstandingBackgroundTask];
}

#pragma mark - Private

- (void)tls_endOutstandingBackgroundTask {
    [self tls_endBackgroundTaskIfCurrent:self.backgroundTaskIdentifier];
}

- (void)tls_endBackgroundTaskIfCurrent:(NSUInteger)taskIdentifier {
    if (taskIdentifier == TLSLifecycleInvalidBackgroundTaskIdentifier) {
        return;
    }
    if (self.backgroundTaskIdentifier != taskIdentifier) {
        return;
    }
    self.backgroundTaskIdentifier = TLSLifecycleInvalidBackgroundTaskIdentifier;
    [self.host endBackgroundTask:taskIdentifier];
}

@end
