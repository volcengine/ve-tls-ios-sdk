// TLSRedactingLogger.h
// TLSProducerBridge
//
// Redacted transport logging entry point.
//
// SECURITY CONTRACT (Beta design §8.2/§11.3):
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

/// Emits one redacted transport log line.
/// @param method HTTP method (e.g. "POST").
/// @param URLString request URL; query/fragment are stripped before logging.
/// @param status HTTP response status code (0 if no response).
/// @param duration request duration in seconds.
/// @param requestID optional request identifier; nil is logged as "-".
/// @param byteCount number of bytes sent (or 0 if not applicable).
+ (void)logWithMethod:(NSString *)method
            URLString:(NSString *)URLString
               status:(NSInteger)status
     durationInterval:(NSTimeInterval)duration
            requestID:(nullable NSString *)requestID
            byteCount:(NSInteger)byteCount;

/// Strips query and fragment from a URL string. Unit-test hook.
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
