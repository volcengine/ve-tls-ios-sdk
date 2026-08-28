// TLSTransport.m
// TLSProducerBridge/Transport
//

#import "TLSTransport.h"
#import "TLSHTTPRequest.h"
#import "TLSHTTPResponse.h"
#import "Bridge/TLSRedactingLogger.h"
#import "Bridge/TLSSerialQueueFactory.h"
#import "Bridge/TLSThreadAssertions.h"

NSErrorDomain const TLSTransportErrorDomain = @"com.volcengine.tls.producer.transport";
NSString *const TLSTransportErrorStatusCodeKey = @"TLSTransportErrorStatusCode";
NSString *const TLSTransportErrorRequestIDKey = @"TLSTransportErrorRequestID";
NSString *const TLSTransportErrorUnderlyingCodeKey = @"TLSTransportErrorUnderlyingCode";

/// Session-wide default for timeoutIntervalForRequest when the caller
/// configuration leaves it unset. Best-effort connect budget only (§8.3).
static NSTimeInterval const kTLSTransportDefaultTimeoutIntervalForRequest = 15.0;
static NSUInteger const kTLSTransportMaxResponseBodyBytes = 64 * 1024;
static NSString *const kTLSTransportQueueSuffix = @"transport";
static NSString *const kTLSTransportRequestIDHeader = @"x-tls-requestid";
static NSString *const kTLSTransportLegacyRequestIDHeader = @"x-tls-request-id";

#pragma mark - Request context

typedef NS_ENUM(NSInteger, TLSTransportRequestState) {
    TLSTransportRequestStateRunning = 0,
    TLSTransportRequestStateTerminal = 1,
};

/// Per-request state, confined to the transport's serial queue.
///
/// Ownership (Beta design §8.1): the context is retained by the transport's
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
@property (nonatomic) CFAbsoluteTime startTime;
@end

@implementation TLSRequestContext
@end

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

@interface TLSTransport ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSOperationQueue *delegateQueue;
@property (nonatomic, strong) TLSTransportDelegateProxy *delegateProxy;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) NSMutableDictionary<NSString *, TLSRequestContext *> *contextsByID;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, TLSRequestContext *> *contextsByTaskID;
@property (nonatomic, assign) BOOL invalidated;

- (NSInteger)effectivePortForURL:(NSURL *)URL;
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
        // Best-effort connect budget (§8.3): URLSession has no independent
        // connect-phase timer; timeoutIntervalForRequest is the closest
        // session-wide knob. The verifiable hard deadline is the per-request
        // requestTimeout, enforced by this transport.
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
    // Best-effort cleanup (safe from any thread; a second
    // invalidateAndCancel after an explicit -invalidate is a no-op). The
    // weak proxy keeps the session from retaining this transport, so
    // dealloc actually runs when the caller drops the transport.
    [_session invalidateAndCancel];
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
    context.startTime = CFAbsoluteTimeGetCurrent();

    dispatch_async(_queue, ^{
        if (self.invalidated) {
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
        // Best-effort connect budget (§8.3): per-request timeoutInterval is
        // the closest knob and may be superseded by the session
        // configuration in delegate sessions. The hard upper bound is
        // requestTimeout, enforced below.
        if (request.connectTimeout > 0) {
            urlRequest.timeoutInterval = request.connectTimeout;
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
                             underlyingCode:nil];
    }
    return [self transportErrorWithCode:TLSTransportErrorCodeTransportFailure
                            description:[NSString stringWithFormat:@"transport failure (code %ld)", (long)error.code]
                             statusCode:context.statusCode
                              requestID:context.responseRequestID
                         underlyingCode:@(error.code)];
}

/// Builds a sanitized NSError. userInfo only ever carries the safe fields
/// declared in TLSTransport.h; never credentials, Authorization headers or
/// raw bodies (§11.3).
- (NSError *)transportErrorWithCode:(TLSTransportErrorCode)code
                        description:(NSString *)description
                         statusCode:(NSInteger)statusCode
                          requestID:(nullable NSString *)requestID
                     underlyingCode:(nullable NSNumber *)underlyingCode {
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
    NSData *body = [context.accumulatedBody copy];
    TLSHTTPResponse *response = [[TLSHTTPResponse alloc] initWithStatusCode:context.statusCode
                                                                    headers:context.responseHeaders
                                                                       body:body
                                                                  requestID:context.responseRequestID
                                                                      error:error];
    NSTimeInterval duration = CFAbsoluteTimeGetCurrent() - context.startTime;
    // Redacted logging: method / stripped URL / status / duration /
    // requestID / byte count only. Headers and bodies never reach the log.
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

@end
