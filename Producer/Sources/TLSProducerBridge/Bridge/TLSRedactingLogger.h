// TLSRedactingLogger.h
// TLSProducerBridge
//
// Redacted transport logging entry point.
//
// Security contract:
// - The log entry point accepts ONLY the predefined fields below. There is
//   intentionally no API to log arbitrary header/body dictionaries, so
//   credentials, signatures, tokens and log bodies can never reach the log.
// - URL strings are redacted: query and fragment are stripped before logging.
// - Any occurrence of the literal "authorization" or an "x-tls-*" prefixed
//   token in the provided fields is masked before emission.
// - NSError userInfo produced by the SDK must likewise never contain
//   credentials, Authorization headers or raw log bodies.
//
// Pure Objective-C; iOS 13.0+ safe APIs only.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Marker substituted for any redacted content.
FOUNDATION_EXPORT NSString *const TLSRedactedMarker;

@interface TLSRedactingLogger : NSObject

/// Process-wide diagnostic transport logging switch. Disabled by default so
/// Release consumers never emit one NSLog line per request unless an internal
/// diagnostic flow explicitly opts in. This Bridge type is not public SDK API.
@property(class, atomic, assign, getter=isLoggingEnabled) BOOL loggingEnabled;

/// Emits one redacted transport log line.
/// This is a no-op while `loggingEnabled` is `NO` (the default).
/// @param method HTTP method (e.g. "POST").
/// @param URLString request URL; query/fragment are stripped before logging.
/// @param status HTTP response status code (0 if no response).
/// @param duration request duration in seconds.
/// @param requestID optional request identifier; only a stable fingerprint is
/// logged, never the server-provided value itself. nil is logged as "-".
/// @param byteCount number of bytes sent (or 0 if not applicable).
+ (void)logWithMethod:(NSString *)method
            URLString:(NSString *)URLString
               status:(NSInteger)status
     durationInterval:(NSTimeInterval)duration
            requestID:(nullable NSString *)requestID
            byteCount:(NSInteger)byteCount;

/// Bounds a server-provided request identifier to 256 characters and replaces
/// characters outside `[A-Za-z0-9._:-]` with `_`. Returns nil for nil/empty.
/// The normalized value is safe for structured API/error fields, but it is
/// still server-controlled and must not be emitted verbatim by the SDK logger.
+ (nullable NSString *)normalizedRequestID:(nullable NSString *)requestID
    NS_SWIFT_NAME(normalizedRequestID(_:));

/// Returns a stable, non-cryptographic fingerprint for log correlation. The
/// original/normalized request identifier is never included in the result.
+ (NSString *)requestIDFingerprintForLogging:(nullable NSString *)requestID
    NS_SWIFT_NAME(requestIDFingerprintForLogging(_:));

/// Strips userinfo, query and fragment from a URL string. Unparseable input
/// returns TLSRedactedMarker; empty input remains empty. Unit-test hook.
+ (NSString *)redactedURLString:(NSString *)URLString;

/// Masks "authorization" and "x-tls-*" tokens in an arbitrary string.
/// Unit-test hook for the redaction contract.
+ (NSString *)maskSensitiveTokensInString:(NSString *)input;

/// Returns YES if the input contains "authorization" or an "x-tls-*" token.
/// Unit-test hook.
+ (BOOL)containsSensitiveToken:(NSString *)input;

/// Built-in self-check exercising the redaction contract. Returns YES when
/// every assertion holds. Intended as a unit-test hook for an ObjC test
/// target (or for activation from Swift once the Bridge module is imported);
/// it performs no logging on its own.
+ (BOOL)runBuiltInSelfCheck;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
