// TLSRealCoreAdapter.m
// TLSProducerBridge/Core
//
// Real C Core adapter implementation — wraps ve-tls-c-sdk v0.3.1.
//

#import "TLSRealCoreAdapter.h"
#import "CTLSProducerCore.h"
#import "Bridge/TLSRedactingLogger.h"
#import "Bridge/TLSThreadAssertions.h"
#import "Transport/TLSTransport.h"
#include <errno.h>
#include <fcntl.h>
#import <limits.h>
#import <pthread.h>
#include <sys/file.h>
#include <sys/stat.h>
#import <TargetConditionals.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

NSErrorDomain const TLSRealCoreAdapterErrorDomain = @"com.volcengine.tls.producer.realcore";
NSString *const TLSRealCoreAdapterErrorResultKey = @"TLSRealCoreAdapterResult";
NSString *const TLSRealCoreAdapterErrorHTTPCodeKey = @"TLSRealCoreAdapterHTTPCode";
NSString *const TLSRealCoreAdapterErrorCodeKey = @"TLSRealCoreAdapterErrorCode";
NSString *const TLSRealCoreAdapterErrorRequestIDKey = @"TLSRealCoreAdapterRequestID";
NSString *const TLSRealCoreAdapterErrorTransportKindKey = @"TLSRealCoreAdapterTransportKind";
NSString *const TLSRealCoreAdapterErrorTransportCodeKey = @"TLSRealCoreAdapterTransportCode";
NSString *const TLSRealCoreAdapterErrorRetryableKey = @"TLSRealCoreAdapterRetryable";

static const int32_t kTLSPersistentMaxLogCount = 200000;
static const int32_t kTLSPersistentMaxFileSize = 8 * 1024 * 1024;
static const int32_t kTLSPersistentMaxFileCount = 32;
static const int32_t kTLSPersistentMaxBytes = 256 * 1024 * 1024;
static NSString *const kTLSProcessLockFileName = @".ios-producer.lock";
static NSString *const kTLSCoreLeaseFileName = @"lease";

/// The callback context is deliberately independent from the adapter object.
/// C Core stores a raw user pointer; keeping this object alive through Core
/// destruction prevents a late callback from dereferencing a deallocated
/// Objective-C adapter.
@interface TLSCoreCallbackContext : NSObject
@property (nonatomic, strong) dispatch_queue_t callbackQueue;
@property (nonatomic, copy, nullable) TLSRealCoreAdapterSendResultHandler handler;
@end

@implementation TLSCoreCallbackContext
@end

@interface TLSHTTPClientContext : NSObject
@property (nonatomic, strong) TLSTransport *transport;
@end

@implementation TLSHTTPClientContext
@end

/// The platform ABI has no user-data slot for file callbacks. The default
/// pthread implementation is stateless, so retaining its function pointer
/// once is safe for all adapter instances. The wrapper applies and verifies
/// iOS backup/data-protection attributes for every WAL/manifest/checkpoint/
/// lease path opened by the Core.
static ve_tls_file *(*gTLSDefaultFileOpen)(const char *, int, int) = NULL;
static pthread_once_t gTLSDefaultFileOpenOnce = PTHREAD_ONCE_INIT;

static void tls_init_default_file_open(void) {
    ve_tls_platform platform;
    memset(&platform, 0, sizeof(platform));
    ve_tls_platform_init_default(&platform);
    gTLSDefaultFileOpen = platform.file_open;
}

static BOOL tls_apply_file_attributes(NSString *path) {
    if (path.length == 0) {
        return NO;
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    NSError *resourceError = nil;
    if (![url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&resourceError]) {
        return NO;
    }
    NSFileManager *fileManager = [[NSFileManager alloc] init];
#if TARGET_OS_IOS
    NSError *attributeError = nil;
    if (![fileManager setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
                         ofItemAtPath:path
                                error:&attributeError]) {
        return NO;
    }
#endif

    NSNumber *excluded = nil;
    NSError *verifyResourceError = nil;
    if (![url getResourceValue:&excluded forKey:NSURLIsExcludedFromBackupKey error:&verifyResourceError] ||
        ![excluded boolValue]) {
        return NO;
    }
#if TARGET_OS_IOS
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:NULL];
    id protection = attributes[NSFileProtectionKey];
    // iOS Simulator may not expose the protection attribute after a
    // successful set. A non-nil mismatch is still a hard failure.
    return protection == nil ||
        [protection isEqual:NSFileProtectionCompleteUntilFirstUserAuthentication];
#else
    return YES;
#endif
}

static ve_tls_file *tls_file_open_with_attributes_inner(const char *path, int flags, int mode) {
    pthread_once(&gTLSDefaultFileOpenOnce, tls_init_default_file_open);
    if (!gTLSDefaultFileOpen || !path) {
        return NULL;
    }
    ve_tls_file *file = gTLSDefaultFileOpen(path, flags, mode);
    if (!file) {
        return NULL;
    }
    if (!tls_apply_file_attributes([NSString stringWithUTF8String:path])) {
        // The default close function is available from the same stateless
        // platform implementation. Refuse the file rather than silently
        // persisting without the mandatory attributes.
        ve_tls_platform platform;
        memset(&platform, 0, sizeof(platform));
        ve_tls_platform_init_default(&platform);
        if (platform.file_close) {
            platform.file_close(file);
        }
        return NULL;
    }
    return file;
}

static ve_tls_file *tls_file_open_with_attributes(const char *path, int flags, int mode) {
    // The Core invokes platform callbacks from raw pthread workers. Those
    // threads do not own a Cocoa autorelease pool, so bound every Foundation
    // temporary to this one file operation instead of retaining it until the
    // worker exits.
    @autoreleasepool {
        return tls_file_open_with_attributes_inner(path, flags, mode);
    }
}

/// Acquires the bridge-level process lock before the C Core gets a chance to
/// inspect its heartbeat lease. The vendored Core's stale-lease takeover is
/// time based and cannot distinguish a dead process from a live one when the
/// process was terminated abruptly. An advisory lock gives live adapters an
/// immediate, kernel-owned exclusion while allowing the kernel to release the
/// lock after a crash.
///
/// The Core's lease is removed only after this lock is held. A regular lease
/// file or symlink is safe to unlink (the symlink itself is removed; its
/// target is never followed), while directories and other special files are
/// rejected to avoid deleting an unexpected object.
static int tls_acquire_persistent_directory_lock(NSString *directory,
                                                  NSString **failureReason) {
    if (failureReason) {
        *failureReason = nil;
    }
    if (directory.length == 0) {
        if (failureReason) {
            *failureReason = @"persistent directory lock is unavailable";
        }
        return -1;
    }

    struct stat directoryStat;
    if (lstat(directory.fileSystemRepresentation, &directoryStat) != 0 ||
        !S_ISDIR(directoryStat.st_mode)) {
        if (failureReason) {
            *failureReason = @"persistent directory is not a directory";
        }
        return -1;
    }

    NSString *lockPath = [directory stringByAppendingPathComponent:kTLSProcessLockFileName];
    int fd = open(lockPath.fileSystemRepresentation,
                  O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                  S_IRUSR | S_IWUSR);
    if (fd < 0) {
        if (failureReason) {
            *failureReason = (errno == EACCES || errno == EROFS)
                ? @"persistent directory lock is unavailable"
                : @"persistent directory lock could not be created";
        }
        return -1;
    }

    struct stat lockStat;
    if (fstat(fd, &lockStat) != 0 || !S_ISREG(lockStat.st_mode)) {
        if (failureReason) {
            *failureReason = @"persistent directory lock is not a regular file";
        }
        close(fd);
        return -1;
    }
    if (fchmod(fd, S_IRUSR | S_IWUSR) != 0) {
        if (failureReason) {
            *failureReason = @"persistent directory lock permissions could not be set";
        }
        close(fd);
        return -1;
    }

    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        if (failureReason) {
            *failureReason = (errno == EWOULDBLOCK || errno == EAGAIN)
                ? @"persistent directory is already in use"
                : @"persistent directory lock could not be acquired";
        }
        close(fd);
        return -1;
    }

    if (!tls_apply_file_attributes(lockPath)) {
        if (failureReason) {
            *failureReason = @"persistent directory lock attributes could not be applied";
        }
        (void)flock(fd, LOCK_UN);
        close(fd);
        return -1;
    }

    NSString *leasePath = [directory stringByAppendingPathComponent:kTLSCoreLeaseFileName];
    struct stat leaseStat;
    if (lstat(leasePath.fileSystemRepresentation, &leaseStat) == 0) {
        if (!S_ISREG(leaseStat.st_mode) && !S_ISLNK(leaseStat.st_mode)) {
            if (failureReason) {
                *failureReason = @"persistent lease is not a regular file";
            }
            (void)flock(fd, LOCK_UN);
            close(fd);
            return -1;
        }
        if (unlink(leasePath.fileSystemRepresentation) != 0 && errno != ENOENT) {
            if (failureReason) {
                *failureReason = @"persistent lease could not be removed";
            }
            (void)flock(fd, LOCK_UN);
            close(fd);
            return -1;
        }
    } else if (errno != ENOENT) {
        if (failureReason) {
            *failureReason = @"persistent lease could not be inspected";
        }
        (void)flock(fd, LOCK_UN);
        close(fd);
        return -1;
    }

    return fd;
}

static void tls_release_persistent_directory_lock(int *fd) {
    if (!fd || *fd < 0) {
        return;
    }
    (void)flock(*fd, LOCK_UN);
    close(*fd);
    *fd = -1;
}

// MARK: - Class extension (must be visible before the C callback)

@interface TLSRealCoreAdapter ()
@property (nonatomic, assign) ve_tls_producer *producer;
@property (nonatomic, strong) dispatch_queue_t callbackQueue;
@property (nonatomic, strong) NSLock *stateLock;
@property (nonatomic, strong) TLSCoreCallbackContext *callbackContext;
@property (nonatomic, strong) TLSHTTPClientContext *httpContext;
@property (nonatomic, copy) NSString *projectID;
@property (nonatomic, assign) BOOL closing;
@property (nonatomic, assign) BOOL closed;
@property (nonatomic, assign) int processLeaseFD;
@end

// MARK: - HTTP client bridge (NSURLSession → sync C interface)

/// Synchronous C callback backed by the adapter's per-instance TLSTransport.
/// The C Core calls this from its sender thread; TLSTransport owns the
/// NSURLSession and its serial state queue, while this function only waits for
/// the one terminal completion. On a boundary timeout we cancel the opaque
/// request ID and return a non-zero C result; we never inspect completion
/// state after returning, so a late completion cannot race with C response
/// storage.
static int tls_http_do_request_inner(ve_tls_http_client *client,
                                     const ve_tls_http_request *req,
                                     ve_tls_http_response *resp) {
    TLSHTTPClientContext *context = client ? (__bridge TLSHTTPClientContext *)client->user_data : nil;
    if (!context || !context.transport || !req || !resp || !req->url) {
        return -1;
    }

    NSString *urlString = [NSString stringWithUTF8String:req->url];
    if (!urlString) {
        return -1;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        ve_tls_http_response_init(resp);
        resp->transport_kind = VE_TLS_TRANSPORT_GENERIC;
        resp->transport_code = TLSTransportErrorCodeInvalidURL;
        resp->transport_retryable = 0;
        resp->error_message = strdup("invalid HTTP URL");
        return -1;
    }
    NSString *method = req->method ? [NSString stringWithUTF8String:req->method] : nil;
    if (method.length == 0) {
        ve_tls_http_response_init(resp);
        resp->transport_kind = VE_TLS_TRANSPORT_GENERIC;
        resp->transport_code = TLSTransportErrorCodeInvalidURL;
        resp->transport_retryable = 0;
        resp->error_message = strdup("invalid HTTP method");
        return -1;
    }

    NSMutableDictionary<NSString *, NSString *> *headerFields = [NSMutableDictionary dictionary];
    if (req->headers) {
        NSString *headers = [NSString stringWithUTF8String:req->headers];
        if (headers) {
            NSArray<NSString *> *lines = [headers componentsSeparatedByString:@"\n"];
            for (NSString *line in lines) {
                NSRange colon = [line rangeOfString:@":"];
                if (colon.location != NSNotFound && colon.location > 0) {
                    NSString *key = [[line substringToIndex:colon.location]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSString *value = [[line substringFromIndex:colon.location + 1]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (key.length > 0 && value) {
                        headerFields[key] = value;
                    }
                }
            }
        }
    }

    NSData *body = nil;
    if (req->body && req->body_size > 0) {
        body = [NSData dataWithBytes:req->body length:req->body_size];
    }
    NSTimeInterval connectTimeout = req->connect_timeout_ms > 0
        ? (NSTimeInterval)req->connect_timeout_ms / 1000.0
        : 0;
    NSTimeInterval requestTimeout = req->timeout_ms > 0
        ? (NSTimeInterval)req->timeout_ms / 1000.0
        : 50.0;
    TLSHTTPRequest *tlsRequest = [[TLSHTTPRequest alloc] initWithMethod:method
                                                                URLString:urlString
                                                                  headers:headerFields.count > 0 ? headerFields : nil
                                                                     body:body
                                                           connectTimeout:connectTimeout
                                                           requestTimeout:requestTimeout];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSHTTPURLResponse *httpResponse = nil;
    __block NSData *responseData = nil;
    __block NSError *requestError = nil;

    NSString *requestID = [context.transport performRequest:tlsRequest
                                           completionHandler:^(TLSHTTPResponse *response) {
        httpResponse = response.statusCode > 0
            ? [[NSHTTPURLResponse alloc] initWithURL:url
                                           statusCode:response.statusCode
                                          HTTPVersion:@"HTTP/1.1"
                                         headerFields:response.headers]
            : nil;
        responseData = response.body;
        requestError = response.error;
        dispatch_semaphore_signal(sem);
    }];

    if (requestID == nil) {
        ve_tls_http_response_init(resp);
        resp->transport_kind = VE_TLS_TRANSPORT_GENERIC;
        resp->transport_code = TLSTransportErrorCodeTransportFailure;
        resp->transport_retryable = 1;
        resp->error_message = strdup("failed to start HTTP request");
        return -1;
    }

    // TLSTransport owns the hard deadline. Give its serial queue a bounded
    // scheduling margin, then cancel and return a structured timeout if the
    // terminal completion still did not arrive.
    int64_t timeoutMs = req->timeout_ms > 0 ? req->timeout_ms : 50000;
    int64_t waitMs = timeoutMs > INT64_MAX - 1000 ? INT64_MAX : timeoutMs + 1000;
    dispatch_time_t deadline = waitMs > (INT64_MAX / NSEC_PER_MSEC)
        ? DISPATCH_TIME_FOREVER
        : dispatch_time(DISPATCH_TIME_NOW, waitMs * NSEC_PER_MSEC);
    long waitResult = dispatch_semaphore_wait(sem, deadline);
    if (waitResult != 0) {
        [context.transport cancelRequestWithID:requestID];
        ve_tls_http_response_init(resp);
        resp->transport_kind = VE_TLS_TRANSPORT_GENERIC;
        resp->transport_code = TLSTransportErrorCodeRequestTimeout;
        resp->transport_retryable = 1;
        resp->error_message = strdup("HTTP request timed out");
        return -1;
    }

    // Fill the C response
    ve_tls_http_response_init(resp);

    if (requestError) {
        resp->transport_kind = VE_TLS_TRANSPORT_GENERIC;
        resp->transport_code = (int32_t)requestError.code;
        resp->transport_retryable = 1;
        if ([requestError.domain isEqualToString:TLSTransportErrorDomain] &&
            requestError.code == TLSTransportErrorCodeRequestTimeout) {
            resp->error_message = strdup("HTTP request timed out");
        } else if ([requestError.domain isEqualToString:TLSTransportErrorDomain] &&
                   requestError.code == TLSTransportErrorCodeHTTPSRequired) {
            resp->error_message = strdup("HTTPS is required");
            resp->transport_retryable = 0;
        } else if ([requestError.domain isEqualToString:TLSTransportErrorDomain] &&
                   requestError.code == TLSTransportErrorCodeRedirectRejected) {
            resp->error_message = strdup("HTTP redirect rejected");
            resp->transport_retryable = 0;
        } else if ([requestError.domain isEqualToString:TLSTransportErrorDomain] &&
                   (requestError.code == TLSTransportErrorCodeInvalidURL ||
                    requestError.code == TLSTransportErrorCodeInvalidConfiguration ||
                    requestError.code == TLSTransportErrorCodeCancelled ||
                    requestError.code == TLSTransportErrorCodeResponseTooLarge)) {
            resp->error_message = strdup("HTTP request rejected");
            resp->transport_retryable = 0;
        } else {
            // Never propagate NSError.localizedDescription: URL loading
            // errors can echo URLs, query strings, or userinfo.
            resp->error_message = strdup("HTTP transport failed");
        }
        if ([requestError.userInfo[TLSTransportErrorRequestIDKey] isKindOfClass:[NSString class]]) {
            resp->request_id = strdup([requestError.userInfo[TLSTransportErrorRequestIDKey] UTF8String]);
        }
        return -1;
    }

    // A transport completion without either an HTTP response or an NSError
    // is an invalid terminal state. Do not let the C Core observe status 0 as
    // if the request had been delivered successfully.
    if (!httpResponse) {
        resp->transport_kind = VE_TLS_TRANSPORT_GENERIC;
        resp->transport_code = TLSTransportErrorCodeTransportFailure;
        resp->transport_retryable = 1;
        resp->error_message = strdup("HTTP transport failed");
        return -1;
    }

    resp->status_code = (int32_t)httpResponse.statusCode;
    if (responseData) {
        resp->body_size = responseData.length;
        resp->body = malloc(responseData.length);
        if (resp->body) {
            memcpy(resp->body, responseData.bytes, responseData.length);
        } else if (responseData.length > 0) {
            ve_tls_http_response_init(resp);
            resp->transport_kind = VE_TLS_TRANSPORT_GENERIC;
            resp->transport_code = ENOMEM;
            resp->transport_retryable = 1;
            resp->error_message = strdup("HTTP response allocation failed");
            return -1;
        }
    }
    NSString *reqID = nil;
    for (NSString *key in httpResponse.allHeaderFields) {
        if ([[key lowercaseString] isEqualToString:@"x-tls-request-id"]) {
            id value = httpResponse.allHeaderFields[key];
            if ([value isKindOfClass:[NSString class]]) {
                reqID = value;
            }
            break;
        }
    }
    if (reqID) {
        resp->request_id = strdup(reqID.UTF8String);
    }

    return 0;
}

static int tls_http_do_request(ve_tls_http_client *client,
                               const ve_tls_http_request *req,
                               ve_tls_http_response *resp) {
    // `do_request` runs on a Core-owned raw pthread. Without a local pool,
    // autoreleased URL/session/request/header objects accumulate for the full
    // sender lifetime and appear as linear RSS growth in a long-running SDK.
    @autoreleasepool {
        return tls_http_do_request_inner(client, req, resp);
    }
}

static void tls_http_free_response(ve_tls_http_client *client,
                                   ve_tls_http_response *resp) {
    if (!resp) return;
    free(resp->body);
    free(resp->request_id);
    free(resp->error_code);
    free(resp->error_message);
    ve_tls_http_response_init(resp);
    (void)client;
}

// MARK: - Send callback bridge

static NSString *TLSCoreSanitizedString(const char *value,
                                        NSUInteger maxLength,
                                        NSString *fallback) {
    if (!value) {
        return fallback;
    }
    NSString *input = [NSString stringWithUTF8String:value];
    if (input.length == 0) {
        return fallback;
    }
    if (input.length > maxLength) {
        input = [input substringToIndex:maxLength];
    }
    NSMutableString *output = [NSMutableString stringWithCapacity:input.length];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-"];
    for (NSUInteger index = 0; index < input.length; index++) {
        unichar character = [input characterAtIndex:index];
        if ([allowed characterIsMember:character]) {
            [output appendFormat:@"%C", character];
        } else {
            [output appendString:@"_"];
        }
    }
    return output.length > 0 ? output : fallback;
}

static NSString *TLSCoreSafeErrorCode(const char *value) {
    return TLSCoreSanitizedString(value, 128, @"CoreError");
}

static NSString *TLSCoreSafeRequestID(const char *value) {
    return TLSCoreSanitizedString(value, 256, nil);
}

static void tls_send_done_v2_inner(ve_tls_result result,
                                   size_t log_bytes,
                                   size_t compressed_bytes,
                                   const ve_tls_error *error,
                                   const unsigned char *raw_buffer,
                                   void *user_param,
                                   int64_t start_id,
                                   int64_t end_id) {
    TLSCoreCallbackContext *context = (__bridge TLSCoreCallbackContext *)user_param;
    if (!context) return;

    TLSRealCoreAdapterSendResultHandler handler = context.handler;
    if (!handler) return;

    // Do not forward the C error message: for HTTP responses the Core may
    // have copied a server-provided body into error_message. The structured
    // fields below retain classification data while the message stays a
    // stable, redacted summary.
    NSString *requestID = error ? TLSCoreSafeRequestID(error->request_id) : nil;
    NSString *errorCode = error ? TLSCoreSafeErrorCode(error->error_code) : nil;
    NSString *errorMessage = nil;
    if (error) {
        if (error->http_code > 0) {
            errorMessage = [NSString stringWithFormat:@"HTTP %d response", (int)error->http_code];
        } else if (error->transport_kind != VE_TLS_TRANSPORT_NONE) {
            // The sender may report its generic terminal send result after
            // retry exhaustion while preserving the actual request timeout in
            // the structured transport code. Classify from either signal so
            // the stable message agrees with the public Swift error mapping.
            errorMessage = (result == VE_TLS_TIMEOUT ||
                            error->transport_code == TLSTransportErrorCodeRequestTimeout)
                ? @"HTTP request timed out"
                : @"HTTP transport failed";
        } else {
            errorMessage = @"producer operation failed";
        }
    }

    int32_t resultCode = (int32_t)result;
    NSUInteger raw = (NSUInteger)log_bytes;
    NSUInteger compressed = (NSUInteger)compressed_bytes;
    NSInteger httpCode = error ? error->http_code : 0;
    NSInteger transportKind = error ? error->transport_kind : VE_TLS_TRANSPORT_NONE;
    NSInteger transportCode = error ? error->transport_code : 0;
    BOOL retryable = error ? (error->retryable != 0) : NO;
    int64_t start = start_id;
    int64_t end = end_id;
    dispatch_queue_t queue = context.callbackQueue ?: dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);

    dispatch_async(queue, ^{
        handler(resultCode, raw, compressed, httpCode, errorCode, errorMessage,
                requestID, transportKind, transportCode, retryable, start, end);
    });
}

static void tls_send_done_v2(ve_tls_result result,
                             size_t log_bytes,
                             size_t compressed_bytes,
                             const ve_tls_error *error,
                             const unsigned char *raw_buffer,
                             void *user_param,
                             int64_t start_id,
                             int64_t end_id) {
    // The completion may arrive on a Core-owned raw pthread as well. The
    // dispatched block retains its captured immutable values after this pool
    // drains, while callback-local Foundation temporaries are released here.
    @autoreleasepool {
        tls_send_done_v2_inner(result, log_bytes, compressed_bytes, error,
                               raw_buffer, user_param, start_id, end_id);
    }
}

// MARK: - Adapter implementation

static NSError *TLSAdapterError(TLSRealCoreAdapterErrorCode code,
                                ve_tls_result result,
                                NSString *description) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = description ?: @"C Core operation failed";
    userInfo[TLSRealCoreAdapterErrorResultKey] = @((NSInteger)result);
    return [NSError errorWithDomain:TLSRealCoreAdapterErrorDomain
                                code:code
                            userInfo:userInfo];
}

static BOOL TLSCheckedInt32(NSInteger value, BOOL strictlyPositive, int32_t *out) {
    if ((strictlyPositive && value <= 0) || value < INT32_MIN || value > INT32_MAX) {
        return NO;
    }
    if (out) {
        *out = (int32_t)value;
    }
    return YES;
}

static BOOL TLSCheckedMilliseconds(NSTimeInterval seconds,
                                  BOOL strictlyPositive,
                                  int32_t *out) {
    if (!isfinite(seconds) || (strictlyPositive ? seconds <= 0 : seconds < 0)) {
        return NO;
    }
    double milliseconds = seconds * 1000.0;
    if (!isfinite(milliseconds) || milliseconds > (double)INT32_MAX) {
        return NO;
    }
    int64_t value = (int64_t)milliseconds;
    if (strictlyPositive && value == 0) {
        // Preserve a positive caller budget instead of silently turning a
        // sub-millisecond value into the C Core's zero/unbounded sentinel.
        value = 1;
    }
    if (out) {
        *out = (int32_t)value;
    }
    return YES;
}

static BOOL TLSHasLineBreak(NSString *value) {
    return value != nil &&
        [value rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location != NSNotFound;
}

static BOOL TLSValidEndpoint(NSString *endpoint) {
    if (TLSHasLineBreak(endpoint)) {
        return NO;
    }
    NSURLComponents *components = endpoint.length > 0
        ? [NSURLComponents componentsWithString:endpoint]
        : nil;
    NSURL *url = components.URL;
    // Match Destination.validate: even explicitly empty userinfo is
    // rejected, because its presence changes the credential boundary.
    NSNumber *port = components.port;
    BOOL validPort = port != nil
        ? (port.integerValue >= 1 && port.integerValue <= 65535)
        : ![endpoint hasSuffix:@":"];
    return url != nil &&
        [[components.scheme lowercaseString] isEqualToString:@"https"] &&
        components.host.length > 0 &&
        components.user == nil &&
        components.password == nil &&
        components.path.length == 0 &&
        components.query == nil &&
        components.fragment == nil &&
        validPort;
}

@implementation TLSRealCoreAdapter

+ (NSString *)coreVersion {
    const char *version = ve_tls_iosp_core_version();
    if (!version) {
        return @"";
    }
    return [NSString stringWithUTF8String:version] ?: @"";
}

- (void)setOnSendResult:(TLSRealCoreAdapterSendResultHandler)onSendResult {
    self.callbackContext.handler = [onSendResult copy];
}

- (TLSRealCoreAdapterSendResultHandler)onSendResult {
    return self.callbackContext.handler;
}

- (BOOL)isClosed {
    [self.stateLock lock];
    BOOL closed = _closed;
    [self.stateLock unlock];
    return closed;
}

- (nullable instancetype)initWithEndpoint:(NSString *)endpoint
                                    region:(NSString *)region
                                  projectID:(NSString *)projectID
                                    topicID:(NSString *)topicID
                                accessKeyID:(NSString *)accessKeyID
                            accessKeySecret:(NSString *)accessKeySecret
                             securityToken:(nullable NSString *)securityToken
                                    source:(NSString *)source
                                  fileName:(nullable NSString *)fileName
                                      tags:(nullable NSDictionary<NSString *, NSString *> *)tags
                               maxLogCount:(NSInteger)maxLogCount
                               maxRawBytes:(NSInteger)maxRawBytes
                                    linger:(NSTimeInterval)linger
                            maxBufferBytes:(NSInteger)maxBufferBytes
                            connectTimeout:(NSTimeInterval)connectTimeout
                            requestTimeout:(NSTimeInterval)requestTimeout
                                lz4Enabled:(BOOL)lz4Enabled
                   sessionConfiguration:(nullable NSURLSessionConfiguration *)sessionConfiguration
                      bufferFullPolicy:(NSInteger)bufferFullPolicy
                     sendConcurrency:(NSInteger)sendConcurrency
               bufferFullBlockTimeout:(NSTimeInterval)bufferFullBlockTimeout
                     persistenceMode:(TLSRealCoreAdapterPersistenceMode)persistenceMode
                       persistentDirectory:(nullable NSString *)persistentDirectory
                           maxLogAgeSeconds:(NSInteger)maxLogAgeSeconds
                          expiredLogPolicy:(NSInteger)expiredLogPolicy
                         authFailurePolicy:(NSInteger)authFailurePolicy
                             callbackQueue:(dispatch_queue_t)callbackQueue
                                      error:(NSError * _Nullable * _Nullable)error {
    self = [super init];
    if (!self) return nil;

    _stateLock = [[NSLock alloc] init];
    _callbackQueue = callbackQueue ?: dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    _callbackContext = [[TLSCoreCallbackContext alloc] init];
    _callbackContext.callbackQueue = _callbackQueue;
    _projectID = [projectID copy];
    _closed = NO;
    _closing = NO;
    _processLeaseFD = -1;

    int32_t cMaxLogCount = 0;
    int32_t cMaxRawBytes = 0;
    int32_t cMaxBufferBytes = 0;
    int32_t cConnectTimeout = 0;
    int32_t cRequestTimeout = 0;
    int32_t cLinger = 0;
    int32_t cSendConcurrency = 0;
    int32_t cBlockTimeout = 0;
    if (!TLSValidEndpoint(endpoint) || region.length == 0 || projectID.length == 0 || topicID.length == 0 ||
        accessKeyID.length == 0 || accessKeySecret.length == 0 || source.length == 0 ||
        TLSHasLineBreak(region) || TLSHasLineBreak(projectID) || TLSHasLineBreak(topicID) ||
        TLSHasLineBreak(accessKeyID) || TLSHasLineBreak(accessKeySecret) || TLSHasLineBreak(securityToken) ||
        !TLSCheckedInt32(maxLogCount, YES, &cMaxLogCount) ||
        !TLSCheckedInt32(maxRawBytes, YES, &cMaxRawBytes) ||
        !TLSCheckedInt32(maxBufferBytes, YES, &cMaxBufferBytes) ||
        !TLSCheckedInt32(sendConcurrency, YES, &cSendConcurrency) ||
        !TLSCheckedMilliseconds(linger, NO, &cLinger) ||
        !TLSCheckedMilliseconds(connectTimeout, YES, &cConnectTimeout) ||
        !TLSCheckedMilliseconds(requestTimeout, YES, &cRequestTimeout) ||
        (bufferFullPolicy != VE_TLS_BUFFER_FULL_DROP &&
         bufferFullPolicy != VE_TLS_BUFFER_FULL_BLOCK) ||
        !TLSCheckedMilliseconds(bufferFullBlockTimeout,
                                bufferFullPolicy == VE_TLS_BUFFER_FULL_BLOCK,
                                &cBlockTimeout) ||
        (persistenceMode < TLSRealCoreAdapterPersistenceModeDisabled ||
         persistenceMode > TLSRealCoreAdapterPersistenceModeSync) ||
        maxLogAgeSeconds < 0 ||
        (maxLogAgeSeconds > INT64_MAX / 1000)) {
        if (error) {
            *error = TLSAdapterError(TLSRealCoreAdapterErrorCodeInvalidArgument,
                                      VE_TLS_INVALID,
                                      @"invalid adapter configuration");
        }
        return nil;
    }
    if (persistenceMode != TLSRealCoreAdapterPersistenceModeDisabled &&
        persistentDirectory.length == 0) {
        if (error) {
            *error = TLSAdapterError(TLSRealCoreAdapterErrorCodeInvalidArgument,
                                      VE_TLS_INVALID,
                                      @"persistent directory is required");
        }
        return nil;
    }

    if (persistenceMode != TLSRealCoreAdapterPersistenceModeDisabled) {
        NSString *lockFailureReason = nil;
        _processLeaseFD = tls_acquire_persistent_directory_lock(
            persistentDirectory, &lockFailureReason);
        if (_processLeaseFD < 0) {
            if (error) {
                *error = TLSAdapterError(
                    TLSRealCoreAdapterErrorCodeCreateFailed,
                    VE_TLS_PERSISTENT_ERROR,
                    lockFailureReason ?: @"persistent directory lock failed");
            }
            return nil;
        }
    }

    NSError *transportError = nil;
    _httpContext = [[TLSHTTPClientContext alloc] init];
    _httpContext.transport = [[TLSTransport alloc] initWithConfiguration:sessionConfiguration
                                                                      error:&transportError];
    if (!_httpContext.transport) {
        if (error) {
            *error = TLSAdapterError(TLSRealCoreAdapterErrorCodeCreateFailed,
                                      VE_TLS_INVALID,
                                      @"HTTP transport could not be created");
        }
        return nil;
    }

    // Initialize C Core config
    ve_tls_config cConfig;
    ve_tls_result rc = ve_tls_config_init_versioned(&cConfig, sizeof(cConfig), VE_TLS_CONFIG_VERSION_CURRENT);
    if (rc != VE_TLS_OK) {
        if (error) {
            *error = [NSError errorWithDomain:TLSRealCoreAdapterErrorDomain
                                         code:TLSRealCoreAdapterErrorCodeCreateFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"C Core config init failed"}];
        }
        return nil;
    }

    // Platform (pthread). The C ABI has no platform user-data slot; the
    // default pthread callbacks are stateless, so replacing only file_open
    // with this process-safe attribute wrapper is the narrowest per-instance
    // configuration available without modifying the vendored Core.
    ve_tls_platform_init_default(&cConfig.platform);
    if (persistenceMode != TLSRealCoreAdapterPersistenceModeDisabled) {
        cConfig.platform.file_open = tls_file_open_with_attributes;
    }

    // HTTP client (NSURLSession bridge)
    ve_tls_http_client httpClient;
    memset(&httpClient, 0, sizeof(httpClient));
    httpClient.do_request = tls_http_do_request;
    httpClient.free_response = tls_http_free_response;
    httpClient.user_data = (__bridge void *)_httpContext;
    cConfig.http_client = httpClient;

    // Endpoint / credentials
    cConfig.endpoint = endpoint.UTF8String;
    cConfig.region = region.UTF8String;
    cConfig.project_id = projectID.UTF8String;
    cConfig.topic_id = topicID.UTF8String;
    cConfig.access_key_id = accessKeyID.UTF8String;
    cConfig.access_key_secret = accessKeySecret.UTF8String;
    cConfig.security_token = securityToken.UTF8String;

    // Source / metadata
    cConfig.source = source.UTF8String;
    cConfig.file_name = fileName.UTF8String;
    ve_tls_kv *tagKV = NULL;
    if (tags.count > 0) {
        NSUInteger count = tags.count;
        tagKV = calloc(count, sizeof(ve_tls_kv));
        if (!tagKV) {
            if (error) {
                *error = TLSAdapterError(TLSRealCoreAdapterErrorCodeCreateFailed,
                                          VE_TLS_DROP_ERROR,
                                          @"metadata allocation failed");
            }
            return nil;
        }
        NSUInteger i = 0;
        for (NSString *key in tags) {
            tagKV[i].key = key.UTF8String;
            tagKV[i].value = tags[key].UTF8String;
            i++;
        }
        cConfig.log_tags = tagKV;
        cConfig.log_tag_count = count;
    }

    // Batch
    cConfig.log_count_per_package = cMaxLogCount;
    cConfig.log_bytes_per_package = cMaxRawBytes;
    cConfig.flush_interval_ms = cLinger;

    // Buffer
    cConfig.max_buffer_bytes = cMaxBufferBytes;
    cConfig.buffer_full_policy = (ve_tls_buffer_full_policy)bufferFullPolicy;
    cConfig.buffer_full_block_timeout_ms = cBlockTimeout;

    // Timeouts
    cConfig.connect_timeout_ms = cConnectTimeout;
    cConfig.request_timeout_ms = cRequestTimeout;

    // Compression
    cConfig.compress_type = lz4Enabled ? "lz4" : "none";

    // Persistence
    if (persistenceMode != TLSRealCoreAdapterPersistenceModeDisabled && persistentDirectory) {
        cConfig.use_persistent = 1;
        cConfig.persistent_file_path = persistentDirectory.UTF8String;
        cConfig.persistent_durability = persistenceMode == TLSRealCoreAdapterPersistenceModeSync
            ? VE_TLS_PDURABILITY_SYNC_WAL
            : VE_TLS_PDURABILITY_BUFFERED_WAL;
        cConfig.max_persistent_log_count = kTLSPersistentMaxLogCount;
        cConfig.max_persistent_file_size = kTLSPersistentMaxFileSize;
        cConfig.max_persistent_file_count = kTLSPersistentMaxFileCount;
        cConfig.persistent_max_bytes = kTLSPersistentMaxBytes;
        cConfig.persistent_max_log_delay_ms = (int64_t)maxLogAgeSeconds * 1000;
        cConfig.persistent_expired_log_policy =
            (expiredLogPolicy == 1) ? VE_TLS_PEXPIRED_DROP : VE_TLS_PEXPIRED_REWRITE;
        cConfig.persistent_auth_failure_policy =
            (authFailurePolicy == 1) ? VE_TLS_PAUTH_DROP : VE_TLS_PAUTH_RETAIN;
    }

    // Sender
    cConfig.send_thread_count = cSendConcurrency;
    cConfig.pack_thread_count = 1;
    cConfig.ordered_send = 1;

    // Retry
    // v0.3.1 sender reads retry_policy.max_attempts. Keep the legacy mirror
    // populated as well for ABI/forward compatibility, but do not mistake it
    // for the effective policy field in this Core version.
    cConfig.retry_max_attempts = 3;
    cConfig.retry_policy.max_attempts = 3;

    // TLS
    cConfig.tls_verify_peer = 1;
    cConfig.tls_verify_host = 1;

    // Create the producer
    _producer = ve_tls_producer_create_versioned(&cConfig, sizeof(cConfig), VE_TLS_CONFIG_VERSION_CURRENT);
    free(tagKV);
    if (!_producer) {
        if (error) {
            *error = [NSError errorWithDomain:TLSRealCoreAdapterErrorDomain
                                         code:TLSRealCoreAdapterErrorCodeCreateFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"C Core producer create failed"}];
        }
        return nil;
    }

    // Set the send callback
    ve_tls_producer_set_send_done_v2(_producer, tls_send_done_v2, (__bridge void *)_callbackContext);

    return self;
}

- (void)dealloc {
    ve_tls_producer *producer = _producer;
    _producer = NULL;
    __block int processLeaseFD = _processLeaseFD;
    _processLeaseFD = -1;
    if (!producer) {
        [_httpContext.transport invalidate];
        tls_release_persistent_directory_lock(&processLeaseFD);
        return;
    }

    // Never block the releasing thread (which may be the main thread) on C
    // worker joins. The raw callback and HTTP contexts are captured strongly
    // until destroy returns, eliminating a user-param UAF even after a close
    // timeout. Clear the callback before handing the producer off; a callback
    // already in flight can still use the retained context safely.
    ve_tls_producer_set_send_done_v2(producer, NULL, NULL);
    TLSCoreCallbackContext *callbackContext = _callbackContext;
    TLSHTTPClientContext *httpContext = _httpContext;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ve_tls_producer_destroy(producer);
        [httpContext.transport invalidate];
        tls_release_persistent_directory_lock(&processLeaseFD);
        (void)callbackContext;
    });
}

- (BOOL)openWithError:(NSError * _Nullable * _Nullable)error {
    [self.stateLock lock];
    if (_closed || _closing) {
        [self.stateLock unlock];
        if (error) {
            *error = TLSAdapterError(TLSRealCoreAdapterErrorCodeClosed,
                                      VE_TLS_CLOSED,
                                      @"adapter is closed");
        }
        return NO;
    }
    ve_tls_result result = ve_tls_producer_recover(_producer);
    [self.stateLock unlock];
    if (result != VE_TLS_OK) {
        if (error) {
            *error = TLSAdapterError(TLSRealCoreAdapterErrorCodeRecoveryFailed,
                                      result,
                                      @"persistent recovery failed");
        }
        return NO;
    }
    return YES;
}

- (BOOL)addLogWithTimestamp:(int64_t)timestampMs
                    hashKey:(nullable NSString *)hashKey
                    contents:(NSDictionary<NSString *, NSString *> *)contents
                      flush:(BOOL)flush
                      error:(NSError * _Nullable * _Nullable)error {
    [self.stateLock lock];
    if (_closed || _closing) {
        [self.stateLock unlock];
        if (error) {
            *error = TLSAdapterError(TLSRealCoreAdapterErrorCodeClosed,
                                      VE_TLS_CLOSED,
                                      @"adapter is closed");
        }
        return NO;
    }

    NSUInteger count = contents.count;
    if (count == 0) {
        [self.stateLock unlock];
        if (error) {
            *error = TLSAdapterError(TLSRealCoreAdapterErrorCodeAddFailed,
                                      VE_TLS_INVALID,
                                      @"log contents must not be empty");
        }
        return NO;
    }

    ve_tls_kv *kvs = calloc(count, sizeof(ve_tls_kv));
    if (!kvs) {
        [self.stateLock unlock];
        if (error) {
            *error = TLSAdapterError(TLSRealCoreAdapterErrorCodeAddFailed,
                                      VE_TLS_DROP_ERROR,
                                      @"memory allocation failed");
        }
        return NO;
    }

    NSUInteger i = 0;
    for (NSString *key in contents) {
        kvs[i].key = key.UTF8String;
        kvs[i].value = contents[key].UTF8String;
        i++;
    }

    ve_tls_result rc;
    if (hashKey) {
        rc = ve_tls_producer_add_log_kv_hashkey(_producer, timestampMs,
                                                 hashKey.UTF8String,
                                                 kvs, count,
                                                 flush ? 1 : 0);
    } else {
        rc = ve_tls_producer_add_log_kv(_producer, timestampMs, kvs, count, flush ? 1 : 0);
    }

    free(kvs);
    [self.stateLock unlock];

    if (rc != VE_TLS_OK) {
        if (error) {
            NSInteger code = TLSRealCoreAdapterErrorCodeAddFailed;
            if (rc == VE_TLS_CLOSED) {
                code = TLSRealCoreAdapterErrorCodeClosed;
            }
            *error = TLSAdapterError(code, rc, @"C Core add failed");
        }
        return NO;
    }

    return YES;
}

- (BOOL)updateCredentials:(NSString *)accessKeyID
           accessKeySecret:(NSString *)accessKeySecret
            securityToken:(nullable NSString *)securityToken
                    error:(NSError * _Nullable * _Nullable)error {
    [self.stateLock lock];
    if (_closed || _closing) {
        [self.stateLock unlock];
        if (error) {
            *error = TLSAdapterError(TLSRealCoreAdapterErrorCodeClosed,
                                      VE_TLS_CLOSED,
                                      @"adapter is closed");
        }
        return NO;
    }

    if (accessKeyID.length == 0 || accessKeySecret.length == 0 ||
        TLSHasLineBreak(accessKeyID) || TLSHasLineBreak(accessKeySecret) ||
        TLSHasLineBreak(securityToken)) {
        [self.stateLock unlock];
        if (error) {
            *error = TLSAdapterError(TLSRealCoreAdapterErrorCodeCredentialsUpdateFailed,
                                      VE_TLS_INVALID,
                                      @"credentials must not be empty");
        }
        return NO;
    }

    ve_tls_result rc = ve_tls_producer_update_static_credentials(
        _producer,
        accessKeyID.UTF8String,
        accessKeySecret.UTF8String,
        securityToken ? securityToken.UTF8String : "");
    [self.stateLock unlock];

    if (rc != VE_TLS_OK) {
        if (error) {
            NSInteger code = rc == VE_TLS_CLOSED
                ? TLSRealCoreAdapterErrorCodeClosed
                : TLSRealCoreAdapterErrorCodeCredentialsUpdateFailed;
            *error = TLSAdapterError(code, rc, @"C Core credentials update failed");
        }
        return NO;
    }
    return YES;
}

- (BOOL)updateDestination:(NSString *)endpoint
                   region:(NSString *)region
                 projectID:(NSString *)projectID
                   topicID:(NSString *)topicID
                    error:(NSError * _Nullable * _Nullable)error {
    [self.stateLock lock];
    if (_closed || _closing) {
        [self.stateLock unlock];
        if (error) {
            *error = TLSAdapterError(TLSRealCoreAdapterErrorCodeClosed,
                                      VE_TLS_CLOSED,
                                      @"adapter is closed");
        }
        return NO;
    }

    if (!TLSValidEndpoint(endpoint) || region.length == 0 || projectID.length == 0 || topicID.length == 0 ||
        TLSHasLineBreak(region) || TLSHasLineBreak(projectID) || TLSHasLineBreak(topicID)) {
        [self.stateLock unlock];
        if (error) {
            *error = TLSAdapterError(TLSRealCoreAdapterErrorCodeDestinationUpdateFailed,
                                      VE_TLS_INVALID,
                                      @"invalid destination");
        }
        return NO;
    }

    ve_tls_result rc = ve_tls_producer_update_endpoint(
        _producer,
        endpoint.UTF8String,
        region.UTF8String,
        topicID.UTF8String);
    if (rc == VE_TLS_OK) {
        // v0.3.1 does not expose a project-id update field. Keep the full
        // Swift destination group atomically in the bridge for lifecycle
        // consistency; the C sender's wire target is determined by the
        // endpoint/region/topic snapshot.
        _projectID = [projectID copy];
    }
    [self.stateLock unlock];

    if (rc != VE_TLS_OK) {
        if (error) {
            NSInteger code = rc == VE_TLS_CLOSED
                ? TLSRealCoreAdapterErrorCodeClosed
                : TLSRealCoreAdapterErrorCodeDestinationUpdateFailed;
            *error = TLSAdapterError(code, rc, @"C Core destination update failed");
        }
        return NO;
    }
    return YES;
}

- (BOOL)closeWithTimeout:(NSTimeInterval)timeout
                    error:(NSError * _Nullable * _Nullable)error {
    int32_t timeoutMs = 0;
    if (!TLSCheckedMilliseconds(timeout, NO, &timeoutMs)) {
        if (error) {
            *error = TLSAdapterError(TLSRealCoreAdapterErrorCodeInvalidArgument,
                                      VE_TLS_INVALID,
                                      @"invalid close timeout");
        }
        return NO;
    }

    [self.stateLock lock];
    if (_closed) {
        [self.stateLock unlock];
        return YES;
    }
    _closing = YES;
    ve_tls_producer *producer = _producer;
    ve_tls_result result = producer ? ve_tls_producer_close(producer, timeoutMs) : VE_TLS_CLOSED;
    if (result == VE_TLS_OK) {
        _closed = YES;
        _closing = NO;
        _producer = NULL;
    }
    [self.stateLock unlock];

    if (result != VE_TLS_OK) {
        if (error) {
            TLSRealCoreAdapterErrorCode code = result == VE_TLS_CLOSED
                ? TLSRealCoreAdapterErrorCodeClosed
                : TLSRealCoreAdapterErrorCodeCloseFailed;
            *error = TLSAdapterError(code, result,
                                     result == VE_TLS_TIMEOUT
                                         ? @"C Core close timed out"
                                         : @"C Core close failed");
        }
        return NO;
    }
    // Core has joined its sender/packer workers on success, so no future
    // request can use this transport. Clear the raw callback before destroy;
    // this also releases a persistent WAL lease immediately instead of
    // keeping the producerID owned until ObjC deallocation. Invalidate the
    // NSURLSession pool only after Core teardown. On timeout the producer and
    // transport remain usable for a later close retry.
    if (producer) {
        ve_tls_producer_set_send_done_v2(producer, NULL, NULL);
        ve_tls_producer_destroy(producer);
    }
    [self.httpContext.transport invalidate];
    int processLeaseFD = _processLeaseFD;
    _processLeaseFD = -1;
    tls_release_persistent_directory_lock(&processLeaseFD);
    return YES;
}

- (void)flush {
    [self.stateLock lock];
    if (!_closed && !_closing) {
        (void)ve_tls_producer_flush(_producer);
    }
    [self.stateLock unlock];
}

@end
