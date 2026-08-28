// TLSTransport.h
// TLSProducerBridge/Transport
//
// NSURLSession-based HTTP transport for the TLS producer (Beta design §8).
//
// Security contract (Beta design §8.2 / decision ledger):
// - HTTPS only; plain-http requests fail with
//   TLSTransportErrorCodeHTTPSRequired before any task is created.
// - Redirects are followed only when the normalized origin (scheme, host,
//   effective port) and every signed request component (method, path, query,
//   body) are unchanged. Cross-origin or signature-changing redirects are
//   rejected, so credentials are never replayed to a different target.
// - TLS challenges use the system default trust evaluation only. There is
//   intentionally no trust-all bypass and no certificate override switch.
// - Logging goes through TLSRedactingLogger: only method, redacted URL,
//   status, duration, request ID and byte counts are ever logged. Headers,
//   bodies and Authorization values never reach the log, and NSError
//   userInfo never contains credentials or raw bodies.
// - Response bodies are capped at 64 KiB. Oversized responses terminate once
//   with a non-retryable transport error and no partial body is returned.
//
// Threading/ownership contract (Beta design §8.1):
// - One transport owns one NSURLSession on a SDK-owned serial, non-main
//   queue. All per-request state lives in a request context confined to
//   that queue; completion is invoked exactly once on that queue.
// - After completion the context is released; late URLSession callbacks
//   only release themselves and never touch already-returned objects.
//
// Timeout mapping (Beta design §8.3, honest naming):
// - `requestTimeout` is the outer hard deadline, enforced by the transport
//   itself (timer fires -> cancel task -> stable timeout error).
// - `connectTimeout` is best-effort only; NSURLSession has no fully
//   independent, portable connect-phase timer, so it is mapped to
//   timeoutIntervalForRequest / NSMutableURLRequest.timeoutInterval.
//   The verifiable hard upper bound is requestTimeout.
//
// Pure Objective-C; iOS 13.0+ safe APIs only.
//

#import <Foundation/Foundation.h>

#import "TLSHTTPRequest.h"
#import "TLSHTTPResponse.h"

NS_ASSUME_NONNULL_BEGIN

/// Error domain for TLSTransport errors. Distinct from the Core adapter
/// domain so transport failures can be classified unambiguously.
FOUNDATION_EXPORT NSErrorDomain const TLSTransportErrorDomain;

/// Transport error codes. Raw values are stable.
typedef NS_ENUM(NSInteger, TLSTransportErrorCode) {
    /// URL string is malformed (cannot construct an NSURL with scheme+host).
    TLSTransportErrorCodeInvalidURL = 2100,
    /// Non-HTTPS URL; the transport refuses plain HTTP.
    TLSTransportErrorCodeHTTPSRequired = 2101,
    /// Redirect changed the origin or signed request target; it was rejected.
    TLSTransportErrorCodeRedirectRejected = 2102,
    /// The requestTimeout hard deadline fired before a terminal response.
    TLSTransportErrorCodeRequestTimeout = 2103,
    /// Request cancelled via cancelRequestWithID:, invalidate, or session
    /// invalidation.
    TLSTransportErrorCodeCancelled = 2104,
    /// Session construction failed (e.g. configuration copy failed).
    TLSTransportErrorCodeInvalidConfiguration = 2105,
    /// Generic URL-loading failure (DNS/TLS/connection/...). The original
    /// NSURLError code is recorded under TLSTransportErrorUnderlyingCodeKey.
    TLSTransportErrorCodeTransportFailure = 2106,
    /// The server response body exceeded the fixed transport safety limit.
    TLSTransportErrorCodeResponseTooLarge = 2107,
};

/// userInfo key: HTTP status code (NSNumber) when a response was received.
FOUNDATION_EXPORT NSString *const TLSTransportErrorStatusCodeKey;

/// userInfo key: `x-tls-request-id` value (NSString) when available.
FOUNDATION_EXPORT NSString *const TLSTransportErrorRequestIDKey;

/// userInfo key: underlying NSURLError code (NSNumber) when mapped.
FOUNDATION_EXPORT NSString *const TLSTransportErrorUnderlyingCodeKey;

/// Completion handler. Invoked exactly once, on the transport's internal
/// serial (non-main) queue. The handler must not block the queue.
typedef void (^TLSTransportCompletionHandler)(TLSHTTPResponse *response);

/// NSURLSession-backed transport.
///
/// One transport per producer; the producer's senders share its connection
/// pool (Beta design §8). Isolation across producers is preferred over
/// cross-producer connection reuse.
@interface TLSTransport : NSObject <NSURLSessionDataDelegate>

/// Builds a transport with a copied session configuration.
///
/// The configuration is copied before the session is created (Beta design
/// §8.2 — no hot updates afterwards). Hardening is enforced on the copy
/// even for caller-supplied configurations: URLCache, cookie storage and
/// credential storage are disabled. When `configuration` is nil an
/// ephemeral configuration is used.
///
/// @param configuration Caller configuration, or nil for ephemeral default.
/// @param error Set when the transport could not be created.
- (nullable instancetype)initWithConfiguration:(nullable NSURLSessionConfiguration *)configuration
                                         error:(NSError * _Nullable * _Nullable)error NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Performs an HTTPS request.
///
/// Always asynchronous; the completion handler is invoked exactly once on
/// the transport's internal serial queue. Validation failures (invalid URL,
/// non-HTTPS scheme, invalidated transport) are also reported
/// asynchronously via the completion handler.
///
/// @param request The immutable request to perform.
/// @param completionHandler Called exactly once with the terminal response.
/// @return An opaque request ID (pass to cancelRequestWithID:), or nil when
///         the request or completion handler is nil (no completion in that
///         programmer-error case).
- (nullable NSString *)performRequest:(TLSHTTPRequest *)request
                    completionHandler:(TLSTransportCompletionHandler)completionHandler;

/// Cancels the in-flight request with the given ID. The request's
/// completion handler is invoked exactly once with a cancelled error.
/// Cancelling an unknown, already-terminal or never-started ID is a no-op.
- (void)cancelRequestWithID:(NSString *)requestID;

/// Cancels all in-flight requests (each completes once with a cancelled
/// error) and invalidates the underlying session. Afterwards, new
/// performRequest calls complete with a cancelled error. Idempotent.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
