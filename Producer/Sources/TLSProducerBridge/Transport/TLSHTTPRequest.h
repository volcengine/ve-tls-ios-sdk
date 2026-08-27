// TLSHTTPRequest.h
// TLSProducerBridge/Transport
//
// Immutable HTTP request model for the NSURLSession transport (Beta design §8).
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
/// transport (Beta design §8.2 / decision ledger O-security).
@property (nonatomic, readonly, copy) NSString *URLString;

/// HTTP header fields. The transport applies them verbatim; protected
/// headers (Authorization, signature, token headers) are the caller's
/// responsibility and are never logged.
@property (nonatomic, readonly, copy, nullable) NSDictionary<NSString *, NSString *> *headers;

/// Request body. May be nil/empty. Never logged.
@property (nonatomic, readonly, copy, nullable) NSData *body;

/// Best-effort connect-phase budget, in seconds.
///
/// HONESTY NOTE (Beta design §8.3): NSURLSession provides no fully
/// independent, portable DNS/TCP/TLS connect-phase hard timer. This value
/// is mapped to `NSURLSessionConfiguration.timeoutIntervalForRequest` /
/// `NSMutableURLRequest.timeoutInterval` on a best-effort basis only. The
/// single verifiable hard upper bound for a request is `requestTimeout`.
@property (nonatomic, readonly) NSTimeInterval connectTimeout;

/// Outer hard deadline for the whole request, in seconds. When the deadline
/// fires, the transport cancels the URLSession task and completes with a
/// stable timeout error, regardless of when URLSession itself would time
/// out. A value <= 0 disables the transport-side deadline.
@property (nonatomic, readonly) NSTimeInterval requestTimeout;

- (instancetype)initWithMethod:(NSString *)method
                     URLString:(NSString *)URLString
                       headers:(nullable NSDictionary<NSString *, NSString *> *)headers
                          body:(nullable NSData *)body
                connectTimeout:(NSTimeInterval)connectTimeout
                requestTimeout:(NSTimeInterval)requestTimeout NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
