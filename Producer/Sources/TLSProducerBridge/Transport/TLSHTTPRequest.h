// TLSHTTPRequest.h
// TLSProducerBridge/Transport
//
// Immutable HTTP request model for the NSURLSession transport.
//
// Pure Objective-C; iOS 13.0+ safe APIs only.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Immutable HTTP request consumed by `TLSTransport`.
///
/// Thread safety: immutable after construction; safe to share across threads.
@interface TLSHTTPRequest : NSObject <NSCopying>

/// HTTP method (e.g. "POST"). Must not be empty.
@property (nonatomic, readonly, copy) NSString *method;

/// Absolute request URL. Only the `https` scheme is accepted by the
/// transport.
@property (nonatomic, readonly, copy) NSString *URLString;

/// HTTP header fields. The transport applies them verbatim; protected
/// headers (Authorization, signature, token headers) are the caller's
/// responsibility and are never logged.
@property (nonatomic, readonly, copy, nullable) NSDictionary<NSString *, NSString *> *headers;

/// Request body. May be nil/empty. Never logged.
@property (nonatomic, readonly, copy, nullable) NSData *body;

/// Internal diagnostic correlation context. The transport copies only the
/// bounded scalar whitelist (batch_start_id, batch_end_id, counters and
/// attempt_id). Counters are limited to attempt_count,
/// cycle_attempt_count and log_count; attempt_id is an ASCII ID token no
/// longer than 128 characters. It is never serialized into HTTP headers,
/// signatures or the request body.
@property (nonatomic, readonly, copy, nullable)
    NSDictionary<NSString *, id> *diagnosticContext;

/// Compatibility connect-phase budget, in seconds.
///
/// NSURLSession provides no fully independent, portable DNS/TCP/TLS
/// connect-phase hard timer. This value is retained for callers that still
/// provide it, but it is not used as a TCP/connect timer by the transport.
@property (nonatomic, readonly) NSTimeInterval connectTimeout;

/// Per-request idle timeout, in seconds.
///
/// A positive value is applied to `NSMutableURLRequest.timeoutInterval` and
/// therefore takes precedence over the copied session configuration for this
/// request. NSURLSession does not expose a portable independent connect-phase
/// deadline; this is an idle/request-loading timeout, not a TCP timer. A
/// value of zero leaves the copied session configuration in effect.
@property (nonatomic, readonly) NSTimeInterval idleTimeout;

/// Outer hard deadline for the whole request, in seconds. When the deadline
/// fires, the transport cancels the URLSession task and completes with a
/// stable timeout error, regardless of when URLSession itself would time
/// out. A value of zero disables the transport-side deadline; negative or
/// non-finite values are rejected when the request is performed.
@property (nonatomic, readonly) NSTimeInterval requestTimeout;

/// Designated initializer with independent compatibility, idle and outer
/// timeout values. Timeout values are validated by `TLSTransport` when the
/// request is performed; zero retains the legacy disabled/default behavior.
- (instancetype)initWithMethod:(NSString *)method
                     URLString:(NSString *)URLString
                       headers:(nullable NSDictionary<NSString *, NSString *> *)headers
                          body:(nullable NSData *)body
                connectTimeout:(NSTimeInterval)connectTimeout
                   idleTimeout:(NSTimeInterval)idleTimeout
                requestTimeout:(NSTimeInterval)requestTimeout
             diagnosticContext:(nullable NSDictionary<NSString *, id> *)diagnosticContext NS_DESIGNATED_INITIALIZER;

/// Split-timeout initializer without diagnostic correlation context.
- (instancetype)initWithMethod:(NSString *)method
                     URLString:(NSString *)URLString
                       headers:(nullable NSDictionary<NSString *, NSString *> *)headers
                          body:(nullable NSData *)body
                connectTimeout:(NSTimeInterval)connectTimeout
                   idleTimeout:(NSTimeInterval)idleTimeout
                requestTimeout:(NSTimeInterval)requestTimeout;

/// Legacy initializer. `connectTimeout` is forwarded as `idleTimeout` so
/// existing package-internal callers retain their prior request timeout
/// behavior while the transport migrates to the independent idle knob.
- (instancetype)initWithMethod:(NSString *)method
                     URLString:(NSString *)URLString
                       headers:(nullable NSDictionary<NSString *, NSString *> *)headers
                          body:(nullable NSData *)body
                connectTimeout:(NSTimeInterval)connectTimeout
                requestTimeout:(NSTimeInterval)requestTimeout;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
