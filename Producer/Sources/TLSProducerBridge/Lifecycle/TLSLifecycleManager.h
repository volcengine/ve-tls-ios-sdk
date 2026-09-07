// TLSLifecycleManager.h
// TLSProducerBridge/Lifecycle
//
// App lifecycle helper for the TLS Producer SDK.
//
// Behavior in an APP process:
//   - Registers for UIApplicationDidEnterBackgroundNotification /
//     UIApplicationWillEnterForegroundNotification via NSNotificationCenter.
//   - didEnterBackground: invokes the flush handler (best-effort flush of
//     buffered data) and requests a finite background task through the host
//     so the system grants a short window for wrap-up.
//   - The background task's expirationHandler ends the task IMMEDIATELY: it
//     does not keep blocking system suspension. WAL data is preserved by the
//     Core; this helper never promises unlimited background upload.
//   - willEnterForeground: invokes the wake handler so the Core sender /
//     recoverable retry can resume. Wake does NOT rely on Reachability to
//     assume network availability.
//
// Behavior in an APP EXTENSION process:
//   - When extensionCheck returns YES the manager registers NO notifications
//     and calls NO UIApplication APIs — every entry point is a no-op.
//     UIApplication.sharedApplication is forbidden in extensions; the
//     default host is never messaged in that case.
//
// Testability:
//   - UIApplication access is abstracted behind the TLSLifecycleHost
//     protocol. The default implementation (TLSDefaultLifecycleHost) talks
//     to UIApplication via the Objective-C runtime (NSClassFromString +
//     objc_msgSend) so this target never links UIKit directly. Tests inject
//     a fake host.
//   - The extension probe is an injectable block; the default checks
//     [[NSBundle mainBundle] infoDictionary][@"NSExtension"] != nil.
//   - The observed notification names are exported as constants below; tests
//     post them directly. They are the raw string values of UIKit's
//     UIApplicationDidEnterBackgroundNotification /
//     UIApplicationWillEnterForegroundNotification, referenced by literal so
//     the Bridge stays UIKit-link-free and App-Extension-safe.
//
// Background execution time is finite and
// granted at the system's discretion. This helper only buys wrap-up time; it
// does not guarantee delivery, does not promise unlimited background upload,
// and always ends background tasks in pairs (begin/end).
//
// Pure Objective-C; iOS 13.0+ safe APIs only.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Notification name observed for "app did enter background".
/// Value equals UIKit's UIApplicationDidEnterBackgroundNotification.
FOUNDATION_EXPORT NSNotificationName const TLSLifecycleDidEnterBackgroundNotificationName;

/// Notification name observed for "app will enter foreground".
/// Value equals UIKit's UIApplicationWillEnterForegroundNotification.
FOUNDATION_EXPORT NSNotificationName const TLSLifecycleWillEnterForegroundNotificationName;

/// Sentinel for "no background task". Equal to UIBackgroundTaskInvalid
/// (zero); defined locally so this header does not import UIKit.
FOUNDATION_EXPORT const NSUInteger TLSLifecycleInvalidBackgroundTaskIdentifier;

/// Abstracts the UIApplication background-task API so TLSLifecycleManager
/// can be unit-tested with a fake host. The default implementation
/// (TLSDefaultLifecycleHost) forwards to UIApplication via the runtime.
@protocol TLSLifecycleHost <NSObject>

/// Mirrors -[UIApplication beginBackgroundTaskWithName:expirationHandler:].
/// Returns TLSLifecycleInvalidBackgroundTaskIdentifier if no time was granted.
- (NSUInteger)beginBackgroundTaskWithName:(NSString *)name
                        expirationHandler:(nullable void (^)(void))expirationHandler;

/// Mirrors -[UIApplication endBackgroundTask:].
- (void)endBackgroundTask:(NSUInteger)identifier;

@end

/// Default host: forwards to UIApplication through the Objective-C runtime
/// (NSClassFromString(@"UIApplication") + objc_msgSend). Never linked against
/// UIKit at build time. In an App Extension this object may still be
/// constructed, but TLSLifecycleManager never messages it when
/// extensionCheck returns YES.
@interface TLSDefaultLifecycleHost : NSObject <TLSLifecycleHost>
@end

/// Block returning YES when the process is an App Extension.
typedef BOOL (^TLSExtensionCheckBlock)(void);

/// App lifecycle helper. One instance per Producer.
///
/// Threading contract: must be used from the main thread. UIKit lifecycle
/// notifications are always delivered on the main thread, and the flush/wake
/// handlers are invoked synchronously on that thread. The manager is not
/// thread-safe; do not post the observed notifications from background
/// threads.
@interface TLSLifecycleManager : NSObject

/// Full initializer.
/// @param flushHandler    Called on didEnterBackground (best-effort flush).
/// @param wakeHandler     Called on willEnterForeground (wake sender/retry).
/// @param host            Background-task host. Pass nil to disable background
///                        tasks (notifications are still observed).
/// @param extensionCheck  Extension probe. Pass nil for the default
///                        (mainBundle infoDictionary[@"NSExtension"] != nil).
- (instancetype)initWithFlushHandler:(void (^)(void))flushHandler
                         wakeHandler:(void (^)(void))wakeHandler
                                host:(nullable id<TLSLifecycleHost>)host
                      extensionCheck:(nullable TLSExtensionCheckBlock)extensionCheck;

/// Convenience initializer: default host (UIApplication via runtime) and the
/// default extension probe.
- (instancetype)initWithFlushHandler:(void (^)(void))flushHandler
                         wakeHandler:(void (^)(void))wakeHandler;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
