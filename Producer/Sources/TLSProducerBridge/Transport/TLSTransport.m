// TLSTransport.m
// TLSProducerBridge/Transport
//

#import "TLSTransport.h"
#import "TLSHTTPRequest.h"
#import "TLSHTTPResponse.h"
#import "Bridge/TLSRedactingLogger.h"
#import "Bridge/TLSSerialQueueFactory.h"
#import "Bridge/TLSThreadAssertions.h"

#import <float.h>
#import <math.h>
#import <stdint.h>

static NSTimeInterval TLSMonotonicTime(void) {
    return [NSProcessInfo processInfo].systemUptime;
}

NSErrorDomain const TLSTransportErrorDomain = @"com.volcengine.tls.producer.transport";
NSString *const TLSTransportErrorStatusCodeKey = @"TLSTransportErrorStatusCode";
NSString *const TLSTransportErrorRequestIDKey = @"TLSTransportErrorRequestID";
NSString *const TLSTransportErrorUnderlyingCodeKey = @"TLSTransportErrorUnderlyingCode";
NSString *const TLSTransportErrorRetryableKey = @"TLSTransportErrorRetryable";

/// Session-wide default for timeoutIntervalForRequest when the caller
/// configuration leaves it unset. An explicit request idleTimeout overrides
/// this value for that request.
static NSTimeInterval const kTLSTransportDefaultTimeoutIntervalForRequest = 15.0;
static NSUInteger const kTLSTransportMaxResponseBodyBytes = 64 * 1024;
static NSString *const kTLSTransportQueueSuffix = @"transport";
static NSString *const kTLSTransportRequestIDHeader = @"x-tls-requestid";
static NSString *const kTLSTransportLegacyRequestIDHeader = @"x-tls-request-id";

/// Request timeout values use the same signed 32-bit millisecond envelope as
/// the Core configuration. Zero remains valid for package-internal direct
/// requests: it disables the outer deadline or leaves the session idle
/// timeout untouched, matching the pre-split timeout behavior.
static BOOL TLSValidTimeoutValue(NSTimeInterval value) {
    if (!isfinite(value) || value < 0) {
        return NO;
    }
    if (value == 0) {
        return YES;
    }
    double milliseconds = value * 1000.0;
    if (!isfinite(milliseconds) || milliseconds < 1.0 ||
        milliseconds > (double)INT32_MAX) {
        return NO;
    }
    double roundedMilliseconds = round(milliseconds);
    double tolerance = fmax(1.0, fabs(milliseconds)) * DBL_EPSILON * 2.0;
    return fabs(milliseconds - roundedMilliseconds) <= tolerance;
}

static BOOL TLSRetryableURLErrorCode(NSInteger code) {
    switch (code) {
        case NSURLErrorTimedOut:
        case NSURLErrorCannotFindHost:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorNetworkConnectionLost:
            return YES;
        default:
            return NO;
    }
}

#pragma mark - Request context

typedef NS_ENUM(NSInteger, TLSTransportRequestState) {
    TLSTransportRequestStateRunning = 0,
    TLSTransportRequestStateTerminal = 1,
};

/// Per-request state, confined to the transport's serial queue.
///
/// Ownership: the context is retained by the transport's
/// registries while running and released at terminal completion. The
/// URLSession task does not retain it; delegate callbacks look it up by
/// task identifier. A late callback after terminal only releases itself.
@interface TLSRequestContext : NSObject
@property (nonatomic, copy) NSString *requestID;
@property (nonatomic, copy) TLSHTTPRequest *request;
@property (nonatomic, copy) TLSTransportCompletionHandler completionHandler;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *task;
@property (nonatomic) NSInteger taskIdentifier;
@property (nonatomic) TLSTransportRequestState state;
@property (nonatomic) NSInteger statusCode;
@property (nonatomic, copy, nullable) NSDictionary *responseHeaders;
@property (nonatomic, strong) NSMutableData *accumulatedBody;
@property (nonatomic, copy, nullable) NSString *responseRequestID;
@property (nonatomic, copy, nullable) NSString *diagnosticRequestID;
@property (nonatomic) BOOL diagnosticFieldsOmitted;
@property (nonatomic, copy, nullable) NSString *diagnosticUnderlyingErrorDomain;
@property (nonatomic, strong, nullable) NSNumber *diagnosticUnderlyingErrorCode;
@property (nonatomic) NSTimeInterval monotonicStartTime;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *diagnosticContext;
@property (nonatomic, copy, nullable) TLSTransportDiagnosticSink diagnosticSink;
@property (nonatomic) int64_t sentBodyBytes;
@property (nonatomic) int64_t expectedBodyBytes;
@property (nonatomic, copy, nullable) NSString *timeoutSource;
@property (nonatomic, copy, nullable) NSString *cancelSource;
@end

@implementation TLSRequestContext
@end

/// Safe scalar snapshot retained only for a bounded period after a request
/// reaches a terminal state. URLSession may deliver metrics after completion;
/// this record deliberately contains no request, task, NSError, or metrics
/// object.
@interface TLSLateMetricsRecord : NSObject
@property (nonatomic, copy) NSDictionary<NSString *, id> *baseFields;
@property (nonatomic, copy) TLSTransportDiagnosticSink sink;
@property (nonatomic) NSTimeInterval expiresAt;
@end

@implementation TLSLateMetricsRecord
@end

static id TLSDiagnosticNullableNumber(int64_t value) {
    return value >= 0 ? @(value) : [NSNull null];
}

static id TLSDiagnosticNullableString(NSString *value) {
    return value.length > 0 ? [value copy] : [NSNull null];
}

static BOOL TLSIsStrictDiagnosticRequestID(NSString *value) {
    if (![value isKindOfClass:[NSString class]] ||
        value.length == 0 || value.length > 256) {
        return NO;
    }
    for (NSUInteger index = 0; index < value.length; index++) {
        unichar character = [value characterAtIndex:index];
        BOOL allowed = (character >= 'a' && character <= 'z') ||
                       (character >= 'A' && character <= 'Z') ||
                       (character >= '0' && character <= '9') ||
                       character == '.' || character == '_' ||
                       character == ':' || character == '-';
        if (!allowed) {
            return NO;
        }
    }
    return YES;
}

static BOOL TLSIsAllowedDiagnosticErrorDomain(NSString *domain) {
    if (![domain isKindOfClass:[NSString class]]) {
        return NO;
    }
    // Keep this an explicit Foundation whitelist. An arbitrary NSError
    // domain may contain user-controlled or sensitive text and must never be
    // copied into the diagnostic payload.
    return [domain isEqualToString:NSURLErrorDomain] ||
           [domain isEqualToString:NSCocoaErrorDomain] ||
           [domain isEqualToString:NSPOSIXErrorDomain] ||
           [domain isEqualToString:NSOSStatusErrorDomain] ||
           [domain isEqualToString:NSMachErrorDomain] ||
           [domain isEqualToString:NSStreamSocketSSLErrorDomain];
}

static void TLSRecordOriginalErrorForDiagnostics(TLSRequestContext *context,
                                                  NSError *error) {
    if (context == nil || error == nil) {
        return;
    }
    context.diagnosticUnderlyingErrorCode = @(error.code);
    if (TLSIsAllowedDiagnosticErrorDomain(error.domain)) {
        context.diagnosticUnderlyingErrorDomain = [error.domain copy];
    } else {
        context.diagnosticUnderlyingErrorDomain = nil;
        context.diagnosticFieldsOmitted = YES;
    }
}

static void TLSMergeDiagnosticContext(NSMutableDictionary<NSString *, id> *fields,
                                      NSDictionary<NSString *, id> *context) {
    if (![context isKindOfClass:[NSDictionary class]]) {
        return;
    }
    for (NSString *key in @[@"batch_start_id", @"batch_end_id", @"attempt_id"]) {
        id value = context[key];
        if (value != nil) {
            fields[key] = value;
        }
    }
    NSDictionary *counters = context[@"counters"];
    if ([counters isKindOfClass:[NSDictionary class]]) {
        fields[@"counters"] = [counters copy];
    }
}

static NSMutableDictionary<NSString *, id> *TLSBaseDiagnosticFields(
    TLSRequestContext *context,
    NSString *event) {
    NSMutableDictionary<NSString *, id> *fields = [NSMutableDictionary dictionary];
    fields[@"event"] = event ?: @"transport_finished";
    fields[@"source"] = @"transport";
    TLSMergeDiagnosticContext(fields, context.diagnosticContext);
    fields[@"http_code"] = @(context.statusCode);
    fields[@"request_id"] = TLSDiagnosticNullableString(context.diagnosticRequestID);
    if (context.diagnosticFieldsOmitted) {
        fields[@"fields_omitted"] = @YES;
    }
    fields[@"sent_body_bytes"] = TLSDiagnosticNullableNumber(context.sentBodyBytes);
    fields[@"expected_body_bytes"] = TLSDiagnosticNullableNumber(context.expectedBodyBytes);
    NSTimeInterval elapsed = TLSMonotonicTime() - context.monotonicStartTime;
    if (!isfinite(elapsed) || elapsed < 0) {
        fields[@"duration_ms"] = [NSNull null];
    } else {
        fields[@"duration_ms"] = @(elapsed * 1000.0);
    }
    fields[@"timeout_source"] = TLSDiagnosticNullableString(context.timeoutSource);
    fields[@"cancel_source"] = TLSDiagnosticNullableString(context.cancelSource);
    return fields;
}

static void TLSAddDiagnosticErrorFields(NSMutableDictionary<NSString *, id> *fields,
                                        TLSRequestContext *context,
                                        NSError *error) {
    if (error == nil) {
        fields[@"error_domain"] = [NSNull null];
        fields[@"error_code"] = [NSNull null];
        fields[@"transport_error_domain"] = [NSNull null];
        fields[@"transport_code"] = [NSNull null];
        fields[@"underlying_error_domain"] = [NSNull null];
        fields[@"underlying_error_code"] = [NSNull null];
        fields[@"retryable"] = [NSNull null];
        return;
    }

    fields[@"error_domain"] = error.domain.length > 0 ? [error.domain copy] : [NSNull null];
    // Transport numeric codes stay in the transport namespace. Leaving the
    // service `error_code` field null prevents a local NSError code from being
    // mistaken for Core's string error name by the owner formatter.
    fields[@"error_code"] = [NSNull null];
    if ([error.domain isEqualToString:TLSTransportErrorDomain]) {
        fields[@"transport_error_domain"] = [error.domain copy];
        fields[@"transport_code"] = @(error.code);
    } else {
        fields[@"transport_error_domain"] = [NSNull null];
        fields[@"transport_code"] = [NSNull null];
    }
    fields[@"underlying_error_domain"] = context.diagnosticUnderlyingErrorDomain.length > 0
        ? [context.diagnosticUnderlyingErrorDomain copy] : [NSNull null];
    fields[@"underlying_error_code"] = context.diagnosticUnderlyingErrorCode != nil
        ? [context.diagnosticUnderlyingErrorCode copy] : [NSNull null];
    NSNumber *retryable = error.userInfo[TLSTransportErrorRetryableKey];
    fields[@"retryable"] = [retryable isKindOfClass:[NSNumber class]]
        ? [retryable copy] : [NSNull null];
    // Cancellation can arrive from URLSession without an explicit SDK call.
    // Preserve that distinction without changing the returned NSError.
    if (error.code == NSURLErrorCancelled && context.cancelSource.length == 0) {
        fields[@"cancel_source"] = @"unknown";
    }
}

static void TLSOfferDiagnosticFields(TLSRequestContext *context,
                                     NSDictionary<NSString *, id> *fields) {
    TLSTransportDiagnosticSink sink = context.diagnosticSink;
    if (sink == nil || fields.count == 0) {
        return;
    }
    // The sink is the owner-side bounded offer. Do not dispatch customer code
    // from this transport hot path and do not retain the input context.
    sink([fields copy]);
}

#pragma mark - Weak delegate proxy

/// NSURLSession strongly retains its delegate until the session is
/// invalidated. If TLSTransport were the direct delegate, the
/// transport<->session retain cycle would keep -dealloc from ever running,
/// making the dealloc-time invalidateAndCancel contract unreachable. The
/// proxy is retained by the session and references the transport weakly,
/// so the transport can deallocate normally and invalidate the session
/// from dealloc.
@interface TLSTransportDelegateProxy : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, weak) TLSTransport *transport;
@end

@implementation TLSTransportDelegateProxy

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    TLSTransport *transport = self.transport;
    if (transport == nil) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    [transport URLSession:session
                 dataTask:dataTask
       didReceiveResponse:response
        completionHandler:completionHandler];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    [self.transport URLSession:session dataTask:dataTask didReceiveData:data];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
 didSendBodyData:(int64_t)bytesSent
  totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    [self.transport URLSession:session
                           task:task
             didSendBodyData:bytesSent
              totalBytesSent:totalBytesSent
  totalBytesExpectedToSend:totalBytesExpectedToSend];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics {
    [self.transport URLSession:session
                           task:task
      didFinishCollectingMetrics:metrics];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    [self.transport URLSession:session task:task didCompleteWithError:error];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    TLSTransport *transport = self.transport;
    if (transport == nil) {
        completionHandler(nil);
        return;
    }
    [transport URLSession:session
                     task:task
willPerformHTTPRedirection:response
               newRequest:request
        completionHandler:completionHandler];
}

- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition,
                             NSURLCredential * _Nullable credential))completionHandler {
    TLSTransport *transport = self.transport;
    if (transport == nil) {
        // SECURITY: default handling even on the late-callback path; never
        // trust-all.
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        return;
    }
    [transport URLSession:session
       didReceiveChallenge:challenge
        completionHandler:completionHandler];
}

@end

#pragma mark - TLSTransport

static void TLSCompleteContextForTransportDeallocation(
    TLSRequestContext *context,
    NSMutableDictionary<NSString *, TLSRequestContext *> *contextsByID,
    NSMutableDictionary<NSNumber *, TLSRequestContext *> *contextsByTaskID
) {
    if (context.state == TLSTransportRequestStateTerminal) {
        return;
    }
    context.state = TLSTransportRequestStateTerminal;
    [contextsByID removeObjectForKey:context.requestID];
    if (context.taskIdentifier != 0) {
        [contextsByTaskID removeObjectForKey:@(context.taskIdentifier)];
    }

    context.cancelSource = @"unknown";

    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:@"transport released"
                                                                        forKey:NSLocalizedDescriptionKey];
    if (context.statusCode > 0) {
        userInfo[TLSTransportErrorStatusCodeKey] = @(context.statusCode);
    }
    if (context.responseRequestID.length > 0) {
        userInfo[TLSTransportErrorRequestIDKey] = context.responseRequestID;
    }
    userInfo[TLSTransportErrorRetryableKey] = @NO;
    NSError *error = [NSError errorWithDomain:TLSTransportErrorDomain
                                         code:TLSTransportErrorCodeCancelled
                                     userInfo:userInfo];
    if (context.diagnosticSink != nil) {
        NSMutableDictionary<NSString *, id> *diagnostic = TLSBaseDiagnosticFields(
            context, @"transport_finished");
        TLSAddDiagnosticErrorFields(diagnostic, context, error);
        TLSOfferDiagnosticFields(context, diagnostic);
    }
    NSData *body = [context.accumulatedBody copy];
    TLSHTTPResponse *response = [[TLSHTTPResponse alloc] initWithStatusCode:context.statusCode
                                                                    headers:context.responseHeaders
                                                                       body:body
                                                                  requestID:context.responseRequestID
                                                                      error:error];
    TLSTransportCompletionHandler handler = context.completionHandler;
    context.completionHandler = nil;
    if (handler != nil) {
        handler(response);
    }
}

@interface TLSTransport ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSOperationQueue *delegateQueue;
@property (nonatomic, strong) TLSTransportDelegateProxy *delegateProxy;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) NSMutableDictionary<NSString *, TLSRequestContext *> *contextsByID;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, TLSRequestContext *> *contextsByTaskID;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, TLSLateMetricsRecord *> *lateMetricsByTaskID;
@property (nonatomic, assign) BOOL invalidated;

- (NSInteger)effectivePortForURL:(NSURL *)URL;
- (void)pruneLateMetricsRecords;
- (void)saveLateMetricsRecordForContext:(TLSRequestContext *)context;
- (void)emitTransportMetricsForContext:(TLSRequestContext *)context
                                values:(NSDictionary<NSString *, id> *)values
                                  late:(BOOL)late;
- (NSDictionary<NSString *, id> *)scalarMetricsForTransaction:(NSURLSessionTaskTransactionMetrics *)transaction;
- (nullable NSString *)diagnosticRequestIDFromHeaders:(NSDictionary *)headers
                                               omitted:(BOOL *)omitted;
- (void)handleLateMetrics:(NSURLSessionTaskMetrics *)metrics
             taskIdentifier:(NSInteger)taskIdentifier;
@end

@implementation TLSTransport

- (nullable instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration
                                         error:(NSError * _Nullable * _Nullable)error {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *sessionConfig;
        if (configuration != nil) {
            // Copy before building the session (§8.2 — no hot updates).
            sessionConfig = [configuration copy];
            if (sessionConfig == nil) {
                if (error != NULL) {
                    *error = [self transportErrorWithCode:TLSTransportErrorCodeInvalidConfiguration
                                              description:@"failed to copy URLSessionConfiguration"
                                               statusCode:0
                                                requestID:nil
                                           underlyingCode:nil];
                }
                return nil;
            }
        } else {
            sessionConfig = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        }
        // Hardening (§8.2): no cache, no cookies, no credential storage —
        // enforced even for caller-supplied configurations.
        sessionConfig.URLCache = nil;
        sessionConfig.HTTPCookieStorage = nil;
        sessionConfig.URLCredentialStorage = nil;
        // URLSession has no independent DNS/TCP/TLS connect-phase timer. The
        // copied configuration remains the session-wide idle/request default;
        // a positive request idleTimeout overrides it below.
        if (sessionConfig.timeoutIntervalForRequest <= 0) {
            sessionConfig.timeoutIntervalForRequest = kTLSTransportDefaultTimeoutIntervalForRequest;
        }
        // One SDK-owned serial, non-main queue for ALL transport state:
        // control calls (perform/cancel/invalidate) and URLSession delegate
        // callbacks (via the delegate operation queue's underlyingQueue).
        // Single-queue confinement makes the exactly-once completion and
        // late-callback safety race-free without extra locks.
        _queue = [TLSSerialQueueFactory serialQueueWithSuffix:kTLSTransportQueueSuffix];
        _contextsByID = [NSMutableDictionary dictionary];
        _contextsByTaskID = [NSMutableDictionary dictionary];
        _lateMetricsByTaskID = [NSMutableDictionary dictionary];
        _delegateQueue = [[NSOperationQueue alloc] init];
        _delegateQueue.maxConcurrentOperationCount = 1;
        _delegateQueue.underlyingQueue = _queue;
        _delegateQueue.name = @"com.volcengine.tls.producer.transport.delegate";

        TLSTransportDelegateProxy *proxy = [[TLSTransportDelegateProxy alloc] init];
        proxy.transport = self;
        _delegateProxy = proxy;
        _session = [NSURLSession sessionWithConfiguration:sessionConfig
                                                 delegate:proxy
                                            delegateQueue:_delegateQueue];
        if (_session == nil) {
            if (error != NULL) {
                *error = [self transportErrorWithCode:TLSTransportErrorCodeInvalidConfiguration
                                          description:@"failed to create URLSession"
                                           statusCode:0
                                            requestID:nil
                                       underlyingCode:nil];
            }
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    // The session retains only the weak delegate proxy, so URLSession
    // cancellation callbacks cannot be relied on after deallocation starts.
    // Drain every context on the transport queue first, preserving the
    // exactly-once/off-main completion contract even when requestTimeout=0.
    _delegateProxy.transport = nil;
    NSURLSession *session = _session;
    dispatch_queue_t queue = _queue;
    NSMutableDictionary<NSString *, TLSRequestContext *> *contextsByID = _contextsByID;
    NSMutableDictionary<NSNumber *, TLSRequestContext *> *contextsByTaskID = _contextsByTaskID;
    dispatch_block_t drain = ^{
        NSArray<TLSRequestContext *> *pending = [contextsByID.allValues copy];
        for (TLSRequestContext *context in pending) {
            TLSCompleteContextForTransportDeallocation(context, contextsByID, contextsByTaskID);
        }
        [session invalidateAndCancel];
    };
    if (queue == nil) {
        [session invalidateAndCancel];
    } else if (dispatch_get_specific(TLSSerialQueueIdentityKey) == (__bridge const void *)queue) {
        drain();
    } else {
        dispatch_sync(queue, drain);
    }
}

#pragma mark - Public API

- (nullable NSString *)performRequest:(TLSHTTPRequest *)request
                    completionHandler:(TLSTransportCompletionHandler)completionHandler {
    if (request == nil || completionHandler == nil) {
        // Programmer error: no ID, no completion.
        return nil;
    }
    NSString *requestID = [[NSUUID UUID] UUIDString];
    TLSRequestContext *context = [[TLSRequestContext alloc] init];
    context.requestID = requestID;
    context.request = request;
    context.completionHandler = completionHandler;
    context.state = TLSTransportRequestStateRunning;
    context.accumulatedBody = [NSMutableData data];
    context.monotonicStartTime = TLSMonotonicTime();
    context.sentBodyBytes = -1;
    context.expectedBodyBytes = -1;

    dispatch_async(_queue, ^{
        // Capture the sink and the already-sanitized request context at the
        // first transport-queue boundary. A nil sink intentionally keeps the
        // hot path free of detailed progress/metrics work.
        context.diagnosticSink = self.diagnosticSink;
        context.diagnosticContext = request.diagnosticContext;
        if (self.invalidated) {
            context.cancelSource = @"invalidate";
            NSError *error = [self transportErrorWithCode:TLSTransportErrorCodeCancelled
                                              description:@"transport invalidated; request not started"
                                               statusCode:0
                                                requestID:nil
                                           underlyingCode:nil];
            [self completeContext:context withError:error];
            return;
        }
        NSError *validationError = [self validationErrorForRequest:request];
        if (validationError != nil) {
            [self completeContext:context withError:validationError];
            return;
        }
        NSURL *url = [NSURL URLWithString:request.URLString];
        NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:url];
        urlRequest.HTTPMethod = request.method;
        if (request.body.length > 0) {
            urlRequest.HTTPBody = request.body;
        }
        // A positive request idle timeout explicitly takes precedence over
        // the copied session configuration. This is an NSURLSession
        // request-loading/idle timeout, not a portable TCP connect timer.
        if (request.idleTimeout > 0) {
            urlRequest.timeoutInterval = request.idleTimeout;
        }
        [request.headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
            [urlRequest setValue:value forHTTPHeaderField:key];
        }];

        NSURLSessionDataTask *task = [self.session dataTaskWithRequest:urlRequest];
        if (task == nil) {
            // Defensive: dataTaskWithRequest: can theoretically return nil.
            // Complete with a transport failure so the context does not leak.
            NSError *error = [self transportErrorWithCode:TLSTransportErrorCodeTransportFailure
                                              description:@"failed to create URLSession task"
                                               statusCode:0
                                                requestID:nil
                                           underlyingCode:nil];
            [self completeContext:context withError:error];
            return;
        }
        context.task = task;
        context.taskIdentifier = task.taskIdentifier;
        self.contextsByID[requestID] = context;
        self.contextsByTaskID[@(task.taskIdentifier)] = context;
        [task resume];

        // Outer hard deadline (§8.3): on fire, cancel the task and complete
        // with a stable timeout error, regardless of when URLSession itself
        // would time out. The block captures self strongly so that a caller
        // dropping the transport early cannot strand an in-flight request
        // without its terminal completion; this extends the transport's
        // lifetime by at most requestTimeout, which is the intended
        // bounded tradeoff for exactly-once completion.
        if (request.requestTimeout > 0) {
            NSTimeInterval deadline = request.requestTimeout;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(deadline * NSEC_PER_SEC)),
                           self.queue,
                           ^{
                TLSRequestContext *pending = self.contextsByID[requestID];
                if (pending == nil || pending.state == TLSTransportRequestStateTerminal) {
                    return;
                }
                // Publish our stable timeout terminal state before cancelling.
                // A custom URLProtocol may deliver NSURLErrorCancelled
                // synchronously from -cancel; cancelling first would let that
                // callback win the exactly-once race and erase the timeout
                // classification.
                NSURLSessionDataTask *task = pending.task;
                pending.timeoutSource = @"sdk_request_deadline";
                NSError *error = [self transportErrorWithCode:TLSTransportErrorCodeRequestTimeout
                                                  description:[NSString stringWithFormat:@"request timed out after %.3f seconds", deadline]
                                                   statusCode:pending.statusCode
                                                    requestID:pending.responseRequestID
                                               underlyingCode:nil];
                [self completeContext:pending withError:error];
                [task cancel];
            });
        }
    });
    return requestID;
}

- (void)cancelRequestWithID:(NSString *)requestID {
    if (requestID.length == 0) {
        return;
    }
    dispatch_async(_queue, ^{
        TLSRequestContext *context = self.contextsByID[requestID];
        if (context == nil || context.state == TLSTransportRequestStateTerminal) {
            return;
        }
        NSURLSessionDataTask *task = context.task;
        context.cancelSource = @"explicit_cancel";
        NSError *error = [self transportErrorWithCode:TLSTransportErrorCodeCancelled
                                          description:@"request cancelled"
                                           statusCode:context.statusCode
                                            requestID:context.responseRequestID
                                       underlyingCode:nil];
        [self completeContext:context withError:error];
        [task cancel];
    });
}

- (void)invalidate {
    dispatch_async(_queue, ^{
        if (self.invalidated) {
            return;
        }
        self.invalidated = YES;
        // Complete every in-flight request once, then invalidate the
        // session. Proactive completion guarantees callers are not left
        // waiting on URLSession's own cancellation callbacks.
        NSArray<TLSRequestContext *> *pending = [self.contextsByID.allValues copy];
        for (TLSRequestContext *context in pending) {
            if (context.state == TLSTransportRequestStateRunning) {
                NSURLSessionDataTask *task = context.task;
                context.cancelSource = @"invalidate";
                NSError *error = [self transportErrorWithCode:TLSTransportErrorCodeCancelled
                                                  description:@"transport invalidated"
                                                   statusCode:context.statusCode
                                                    requestID:context.responseRequestID
                                               underlyingCode:nil];
                [self completeContext:context withError:error];
                [task cancel];
            }
        }
        [self.session invalidateAndCancel];
    });
}

#pragma mark - NSURLSessionDataDelegate (invoked on _queue via the proxy)

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    TLSRequestContext *context = self.contextsByTaskID[@(dataTask.taskIdentifier)];
    if (context == nil || context.state == TLSTransportRequestStateTerminal) {
        // Late response after our own terminal completion: cancel, do not
        // touch the released context.
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        context.statusCode = httpResponse.statusCode;
        context.responseHeaders = httpResponse.allHeaderFields;
        context.responseRequestID = [self requestIDFromHeaders:httpResponse.allHeaderFields];
        BOOL diagnosticRequestIDOmitted = NO;
        context.diagnosticRequestID = [self diagnosticRequestIDFromHeaders:
            httpResponse.allHeaderFields omitted:&diagnosticRequestIDOmitted];
        context.diagnosticFieldsOmitted |= diagnosticRequestIDOmitted;
    }
    if (response.expectedContentLength > (int64_t)kTLSTransportMaxResponseBodyBytes) {
        NSError *error = [self transportErrorWithCode:TLSTransportErrorCodeResponseTooLarge
                                          description:@"response body exceeded safety limit"
                                           statusCode:context.statusCode
                                            requestID:context.responseRequestID
                                       underlyingCode:nil];
        [context.accumulatedBody setLength:0];
        [self completeContext:context withError:error];
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    TLSRequestContext *context = self.contextsByTaskID[@(dataTask.taskIdentifier)];
    if (context == nil || context.state == TLSTransportRequestStateTerminal) {
        return;
    }
    NSUInteger accumulatedLength = context.accumulatedBody.length;
    if (accumulatedLength > kTLSTransportMaxResponseBodyBytes ||
        data.length > kTLSTransportMaxResponseBodyBytes - accumulatedLength) {
        NSURLSessionDataTask *task = context.task;
        NSError *error = [self transportErrorWithCode:TLSTransportErrorCodeResponseTooLarge
                                          description:@"response body exceeded safety limit"
                                           statusCode:context.statusCode
                                            requestID:context.responseRequestID
                                       underlyingCode:nil];
        [context.accumulatedBody setLength:0];
        [self completeContext:context withError:error];
        [task cancel];
        return;
    }
    [context.accumulatedBody appendData:data];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
 didSendBodyData:(int64_t)bytesSent
  totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    TLSRequestContext *context = self.contextsByTaskID[@(task.taskIdentifier)];
    if (context == nil || context.state == TLSTransportRequestStateTerminal ||
        context.diagnosticSink == nil) {
        return;
    }
    if (totalBytesSent >= 0) {
        context.sentBodyBytes = totalBytesSent;
    } else if (bytesSent >= 0 && context.sentBodyBytes >= 0 &&
               INT64_MAX - context.sentBodyBytes >= bytesSent) {
        context.sentBodyBytes += bytesSent;
    }
    if (totalBytesExpectedToSend >= 0) {
        context.expectedBodyBytes = totalBytesExpectedToSend;
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics {
    TLSRequestContext *context = self.contextsByTaskID[@(task.taskIdentifier)];
    if (context != nil && context.state != TLSTransportRequestStateTerminal &&
        context.diagnosticSink != nil) {
        NSURLSessionTaskTransactionMetrics *transaction =
            metrics.transactionMetrics.lastObject;
        if (transaction != nil) {
            [self emitTransportMetricsForContext:context
                                           values:[self scalarMetricsForTransaction:transaction]
                                             late:NO];
        }
        return;
    }
    [self handleLateMetrics:metrics taskIdentifier:task.taskIdentifier];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    TLSRequestContext *context = self.contextsByTaskID[@(task.taskIdentifier)];
    if (context == nil || context.state == TLSTransportRequestStateTerminal) {
        // Late completion after timeout/cancel/redirect-rejection: release
        // only ourselves.
        return;
    }
    if (error == nil) {
        [self completeContext:context withError:nil];
        return;
    }
    if ([error.domain isEqualToString:NSURLErrorDomain] &&
        error.code == NSURLErrorTimedOut && context.timeoutSource.length == 0) {
        context.timeoutSource = @"urlsession_timeout";
    } else if ([error.domain isEqualToString:NSURLErrorDomain] &&
               error.code == NSURLErrorCancelled && context.cancelSource.length == 0) {
        context.cancelSource = @"unknown";
    }
    [self completeContext:context withError:[self mappedErrorForURLError:error context:context]];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    TLSRequestContext *context = self.contextsByTaskID[@(task.taskIdentifier)];
    if (context == nil || context.state == TLSTransportRequestStateTerminal) {
        completionHandler(nil);
        return;
    }
    NSURL *originalURL = task.originalRequest.URL;
    NSURL *nextURL = request.URL;
    NSURLComponents *originalComponents = originalURL
        ? [NSURLComponents componentsWithURL:originalURL resolvingAgainstBaseURL:NO]
        : nil;
    NSURLComponents *nextComponents = nextURL
        ? [NSURLComponents componentsWithURL:nextURL resolvingAgainstBaseURL:NO]
        : nil;
    BOOL sameScheme = (originalURL.scheme != nil && nextURL.scheme != nil &&
                       [[originalURL.scheme lowercaseString] isEqualToString:[nextURL.scheme lowercaseString]]);
    BOOL sameHost = (originalURL.host != nil && nextURL.host != nil &&
                     [[originalURL.host lowercaseString] isEqualToString:[nextURL.host lowercaseString]]);
    BOOL samePort = ([self effectivePortForURL:originalURL] ==
                     [self effectivePortForURL:nextURL]);
    BOOL noUserInfo = nextComponents.user == nil && nextComponents.password == nil;
    // HTTP methods are case-sensitive tokens and are part of the V4 canonical
    // request. A case-only change is therefore a signature-changing redirect.
    BOOL sameMethod = context.request.method.length > 0 && request.HTTPMethod.length > 0 &&
        [context.request.method isEqualToString:request.HTTPMethod];
    BOOL samePath = originalComponents != nil && nextComponents != nil &&
        [(originalComponents.percentEncodedPath ?: @"")
            isEqualToString:(nextComponents.percentEncodedPath ?: @"")];
    BOOL sameQuery = ((originalComponents.percentEncodedQuery == nil &&
                       nextComponents.percentEncodedQuery == nil) ||
                      [originalComponents.percentEncodedQuery
                          isEqualToString:nextComponents.percentEncodedQuery]);
    BOOL sameBody = ((context.request.body == nil && request.HTTPBody == nil) ||
                     [context.request.body isEqualToData:request.HTTPBody]);
    if (sameScheme && sameHost && samePort && noUserInfo && sameMethod &&
        samePath && sameQuery && sameBody) {
        // NSURLSession strips Authorization while constructing a redirect
        // request. The C Core signs before entering this transport, and its V4
        // signature covers method, canonical path/query, and payload. Reapply
        // the original Core-provided headers only when every signed request
        // component and the exact origin are unchanged.
        NSMutableURLRequest *sameOriginRequest = [request mutableCopy];
        for (NSString *key in context.request.headers) {
            NSString *value = context.request.headers[key];
            if (key.length > 0 && value != nil) {
                [sameOriginRequest setValue:value forHTTPHeaderField:key];
            }
        }
        completionHandler(sameOriginRequest);
        return;
    }
    // Cross-origin or signature-changing redirect: do not follow. This both
    // keeps credentials within their origin and prevents replaying an
    // Authorization value whose canonical method/path/query/body no longer
    // matches. A missing HTTPS port is normalized to 443, making explicit
    // :443 equivalent to the default origin.
    // Record our redirect-rejected terminal state before asking URLSession to
    // cancel the redirect. Some URLProtocol implementations synchronously
    // report cancellation from this completion handler.
    context.statusCode = response.statusCode;
    context.responseHeaders = response.allHeaderFields;
    context.responseRequestID = [self requestIDFromHeaders:response.allHeaderFields];
    BOOL diagnosticRequestIDOmitted = NO;
    context.diagnosticRequestID = [self diagnosticRequestIDFromHeaders:
        response.allHeaderFields omitted:&diagnosticRequestIDOmitted];
    context.diagnosticFieldsOmitted |= diagnosticRequestIDOmitted;
    NSError *error = [self transportErrorWithCode:TLSTransportErrorCodeRedirectRejected
                                      description:@"redirect rejected: origin or signed request target changed"
                                       statusCode:response.statusCode
                                        requestID:context.responseRequestID
                                   underlyingCode:nil];
    [self completeContext:context withError:error];
    completionHandler(nil);
}

- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition,
                             NSURLCredential * _Nullable credential))completionHandler {
    // SECURITY (§8.2): system default trust evaluation only. There is
    // intentionally no trust-all bypass and no credential injection.
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

#pragma mark - Internal helpers (all on _queue)

- (NSInteger)effectivePortForURL:(NSURL *)URL {
    if (URL.port != nil) {
        return URL.port.integerValue;
    }
    NSString *scheme = URL.scheme.lowercaseString;
    if ([scheme isEqualToString:@"https"]) {
        return 443;
    }
    if ([scheme isEqualToString:@"http"]) {
        return 80;
    }
    return -1;
}

- (nullable NSError *)validationErrorForRequest:(TLSHTTPRequest *)request {
    if (request.method.length == 0) {
        return [self transportErrorWithCode:TLSTransportErrorCodeInvalidURL
                                description:@"HTTP method must not be empty"
                                 statusCode:0
                                  requestID:nil
                             underlyingCode:nil];
    }
    if (!TLSValidTimeoutValue(request.connectTimeout) ||
        !TLSValidTimeoutValue(request.idleTimeout) ||
        !TLSValidTimeoutValue(request.requestTimeout)) {
        // Keep timeout validation on the transport queue and use the stable
        // non-retryable request-validation code. In particular, rejecting
        // NaN/Infinity before dispatch_after or URLRequest mutation avoids
        // undefined timer conversion and Foundation timeout behavior.
        return [self transportErrorWithCode:TLSTransportErrorCodeInvalidURL
                                description:@"invalid timeout value"
                                 statusCode:0
                                  requestID:nil
                             underlyingCode:nil];
    }
    NSURL *url = [NSURL URLWithString:request.URLString];
    if (url == nil || url.scheme.length == 0 || url.host.length == 0) {
        // Generic message on purpose: never echo the URL (it may embed
        // credentials or tokens in the authority/query).
        return [self transportErrorWithCode:TLSTransportErrorCodeInvalidURL
                                description:@"invalid URL"
                                 statusCode:0
                                  requestID:nil
                             underlyingCode:nil];
    }
    if (![[url.scheme lowercaseString] isEqualToString:@"https"]) {
        return [self transportErrorWithCode:TLSTransportErrorCodeHTTPSRequired
                                description:@"only HTTPS requests are supported"
                                 statusCode:0
                                  requestID:nil
                             underlyingCode:nil];
    }
    return nil;
}

/// Maps an NSURLError to a sanitized transport error. The underlying
/// userInfo is intentionally NOT propagated (it may embed the failing URL
/// and other connection details); only the numeric code is kept.
- (NSError *)mappedErrorForURLError:(NSError *)error context:(TLSRequestContext *)context {
    // Snapshot only the original error's safe namespace and numeric code.
    // The returned transport NSError remains unchanged; this is diagnostics
    // correlation state only.
    TLSRecordOriginalErrorForDiagnostics(context, error);
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
        return [self transportErrorWithCode:TLSTransportErrorCodeCancelled
                                description:@"request cancelled"
                                 statusCode:context.statusCode
                                  requestID:context.responseRequestID
                             underlyingCode:nil];
    }
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorTimedOut) {
        return [self transportErrorWithCode:TLSTransportErrorCodeRequestTimeout
                                description:@"request timed out"
                                 statusCode:context.statusCode
                                  requestID:context.responseRequestID
                             underlyingCode:@(error.code)
                                  retryable:YES];
    }
    BOOL retryable = [error.domain isEqualToString:NSURLErrorDomain] &&
        TLSRetryableURLErrorCode(error.code);
    return [self transportErrorWithCode:TLSTransportErrorCodeTransportFailure
                            description:[NSString stringWithFormat:@"transport failure (code %ld)", (long)error.code]
                             statusCode:context.statusCode
                              requestID:context.responseRequestID
                         underlyingCode:@(error.code)
                              retryable:retryable];
}

/// Builds a sanitized NSError. userInfo only ever carries the safe fields
/// declared in TLSTransport.h; never credentials, Authorization headers or
/// raw bodies (§11.3).
- (NSError *)transportErrorWithCode:(TLSTransportErrorCode)code
                        description:(NSString *)description
                         statusCode:(NSInteger)statusCode
                          requestID:(nullable NSString *)requestID
                     underlyingCode:(nullable NSNumber *)underlyingCode {
    return [self transportErrorWithCode:code
                            description:description
                             statusCode:statusCode
                              requestID:requestID
                         underlyingCode:underlyingCode
                              retryable:(code == TLSTransportErrorCodeRequestTimeout)];
}

- (NSError *)transportErrorWithCode:(TLSTransportErrorCode)code
                        description:(NSString *)description
                         statusCode:(NSInteger)statusCode
                          requestID:(nullable NSString *)requestID
                     underlyingCode:(nullable NSNumber *)underlyingCode
                          retryable:(BOOL)retryable {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = description;
    if (statusCode > 0) {
        userInfo[TLSTransportErrorStatusCodeKey] = @(statusCode);
    }
    if (requestID.length > 0) {
        userInfo[TLSTransportErrorRequestIDKey] = requestID;
    }
    if (underlyingCode != nil) {
        userInfo[TLSTransportErrorUnderlyingCodeKey] = underlyingCode;
    }
    userInfo[TLSTransportErrorRetryableKey] = @(retryable);
    return [NSError errorWithDomain:TLSTransportErrorDomain code:code userInfo:userInfo];
}

/// Terminal completion. Exactly once: the state guard makes every late
/// path (timeout vs completion vs cancel vs invalidate vs redirect) a
/// no-op after the first transition.
- (void)completeContext:(TLSRequestContext *)context withError:(nullable NSError *)error {
    TLSAssertIsOnQueue(self.queue);
    if (context.state == TLSTransportRequestStateTerminal) {
        return;
    }
    context.state = TLSTransportRequestStateTerminal;
    [self.contextsByID removeObjectForKey:context.requestID];
    if (context.taskIdentifier != 0) {
        [self.contextsByTaskID removeObjectForKey:@(context.taskIdentifier)];
    }
    if (error != nil && error.code == TLSTransportErrorCodeCancelled &&
        context.cancelSource.length == 0) {
        context.cancelSource = @"unknown";
    }
    if (context.diagnosticSink != nil) {
        NSMutableDictionary<NSString *, id> *diagnostic = TLSBaseDiagnosticFields(
            context, @"transport_finished");
        TLSAddDiagnosticErrorFields(diagnostic, context, error);
        [self saveLateMetricsRecordForContext:context];
        TLSOfferDiagnosticFields(context, diagnostic);
    }
    NSData *body = [context.accumulatedBody copy];
    TLSHTTPResponse *response = [[TLSHTTPResponse alloc] initWithStatusCode:context.statusCode
                                                                    headers:context.responseHeaders
                                                                       body:body
                                                                  requestID:context.responseRequestID
                                                                      error:error];
    NSTimeInterval duration = TLSMonotonicTime() - context.monotonicStartTime;
    // Disabled by default. When an internal diagnostic explicitly opts in,
    // only method / stripped URL / status / duration / requestID fingerprint
    // / byte count reach the logger. Headers and bodies never do.
    [TLSRedactingLogger logWithMethod:context.request.method
                            URLString:context.request.URLString
                               status:context.statusCode
                     durationInterval:duration
                            requestID:context.responseRequestID
                            byteCount:(NSInteger)body.length];
    TLSTransportCompletionHandler handler = context.completionHandler;
    context.completionHandler = nil;
    if (handler != nil) {
        handler(response);
    }
    context.diagnosticSink = nil;
}

- (NSDictionary<NSString *, id> *)scalarMetricsForTransaction:(NSURLSessionTaskTransactionMetrics *)transaction {
    if (transaction == nil) {
        return @{};
    }
    id (^durationMilliseconds)(NSDate *, NSDate *) = ^id(NSDate *start, NSDate *end) {
        if (start == nil || end == nil) {
            return [NSNull null];
        }
        NSTimeInterval seconds = [end timeIntervalSinceDate:start];
        if (!isfinite(seconds) || seconds < 0) {
            return [NSNull null];
        }
        return @(seconds * 1000.0);
    };
    NSString *protocol = transaction.networkProtocolName;
    if (protocol.length > 64) {
        protocol = [protocol substringToIndex:64];
    }
    return @{
        @"dns_ms": durationMilliseconds(transaction.domainLookupStartDate,
                                          transaction.domainLookupEndDate),
        @"connection_setup_ms": durationMilliseconds(transaction.connectStartDate,
                                                       transaction.connectEndDate),
        @"tls_handshake_ms": durationMilliseconds(transaction.secureConnectionStartDate,
                                                   transaction.secureConnectionEndDate),
        @"request_send_ms": durationMilliseconds(transaction.requestStartDate,
                                                  transaction.requestEndDate),
        @"response_wait_ms": durationMilliseconds(transaction.requestEndDate,
                                                   transaction.responseStartDate),
        @"response_read_ms": durationMilliseconds(transaction.responseStartDate,
                                                   transaction.responseEndDate),
        @"network_protocol": protocol.length > 0 ? [protocol copy] : [NSNull null],
        @"connection_reused": @(transaction.reusedConnection),
    };
}

- (void)pruneLateMetricsRecords {
    TLSAssertIsOnQueue(self.queue);
    NSTimeInterval now = TLSMonotonicTime();
    NSArray<NSNumber *> *keys = [self.lateMetricsByTaskID.allKeys copy];
    for (NSNumber *key in keys) {
        TLSLateMetricsRecord *record = self.lateMetricsByTaskID[key];
        if (record == nil || record.expiresAt <= now) {
            [self.lateMetricsByTaskID removeObjectForKey:key];
        }
    }
}

- (void)saveLateMetricsRecordForContext:(TLSRequestContext *)context {
    TLSAssertIsOnQueue(self.queue);
    if (context == nil || context.taskIdentifier == 0 || context.diagnosticSink == nil) {
        return;
    }
    [self pruneLateMetricsRecords];
    if (self.lateMetricsByTaskID.count >= 128) {
        NSNumber *oldestKey = nil;
        NSTimeInterval oldestExpiry = DBL_MAX;
        for (NSNumber *key in self.lateMetricsByTaskID) {
            TLSLateMetricsRecord *record = self.lateMetricsByTaskID[key];
            if (record.expiresAt < oldestExpiry) {
                oldestExpiry = record.expiresAt;
                oldestKey = key;
            }
        }
        if (oldestKey != nil) {
            [self.lateMetricsByTaskID removeObjectForKey:oldestKey];
        }
    }
    TLSLateMetricsRecord *record = [[TLSLateMetricsRecord alloc] init];
    record.baseFields = [TLSBaseDiagnosticFields(context, @"transport_metrics") copy];
    record.sink = [context.diagnosticSink copy];
    record.expiresAt = TLSMonotonicTime() + 30.0;
    self.lateMetricsByTaskID[@(context.taskIdentifier)] = record;
}

- (void)emitTransportMetricsForContext:(TLSRequestContext *)context
                                values:(NSDictionary<NSString *, id> *)values
                                  late:(BOOL)late {
    if (context == nil || values.count == 0) {
        return;
    }
    NSMutableDictionary<NSString *, id> *fields = TLSBaseDiagnosticFields(
        context, @"transport_metrics");
    [fields addEntriesFromDictionary:values];
    fields[@"metrics_late"] = @(late);
    TLSOfferDiagnosticFields(context, fields);
}

- (void)handleLateMetrics:(NSURLSessionTaskMetrics *)metrics
             taskIdentifier:(NSInteger)taskIdentifier {
    TLSAssertIsOnQueue(self.queue);
    [self pruneLateMetricsRecords];
    TLSLateMetricsRecord *record = self.lateMetricsByTaskID[@(taskIdentifier)];
    if (record == nil) {
        return;
    }
    [self.lateMetricsByTaskID removeObjectForKey:@(taskIdentifier)];
    NSURLSessionTaskTransactionMetrics *transaction = metrics.transactionMetrics.lastObject;
    if (transaction == nil || record.sink == nil) {
        return;
    }
    NSMutableDictionary<NSString *, id> *fields = [record.baseFields mutableCopy];
    [fields setValuesForKeysWithDictionary:[self scalarMetricsForTransaction:transaction]];
    fields[@"event"] = @"transport_metrics";
    fields[@"source"] = @"transport";
    fields[@"metrics_late"] = @YES;
    record.sink([fields copy]);
}

/// Extracts the TLS request ID case-insensitively. The service contract uses
/// `x-tls-requestid`; retain the older hyphenated spelling for compatibility.
- (nullable NSString *)requestIDFromHeaders:(NSDictionary *)headers {
    if (![headers isKindOfClass:[NSDictionary class]] || headers.count == 0) {
        return nil;
    }
    for (NSString *key in headers) {
        if (![key isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *lowercaseKey = [key lowercaseString];
        if ([lowercaseKey isEqualToString:kTLSTransportRequestIDHeader] ||
            [lowercaseKey isEqualToString:kTLSTransportLegacyRequestIDHeader]) {
            id value = headers[key];
            if ([value isKindOfClass:[NSString class]] && ((NSString *)value).length > 0) {
                return [TLSRedactingLogger normalizedRequestID:(NSString *)value];
            }
        }
    }
    return nil;
}

- (nullable NSString *)diagnosticRequestIDFromHeaders:(NSDictionary *)headers
                                               omitted:(BOOL *)omitted {
    if (omitted != NULL) {
        *omitted = NO;
    }
    if (![headers isKindOfClass:[NSDictionary class]] || headers.count == 0) {
        return nil;
    }
    NSString *requestID = nil;
    for (NSString *key in headers) {
        if (![key isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *lowercaseKey = [key lowercaseString];
        if (![lowercaseKey isEqualToString:kTLSTransportRequestIDHeader] &&
            ![lowercaseKey isEqualToString:kTLSTransportLegacyRequestIDHeader]) {
            continue;
        }
        id value = headers[key];
        if (![value isKindOfClass:[NSString class]] ||
            !TLSIsStrictDiagnosticRequestID((NSString *)value)) {
            if (omitted != NULL) {
                *omitted = YES;
            }
            continue;
        }
        requestID = [value copy];
    }
    return requestID;
}

@end
