// TLSHTTPResponse.h
// TLSProducerBridge/Transport
//
// Immutable HTTP response model for the NSURLSession transport (Beta
// design §8).
//
// Pure Objective-C; iOS 13.0+ safe APIs only.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Immutable HTTP response produced by `TLSTransport`.
///
/// Ownership contract (Beta design §8.1): the transport accumulates the
/// body inside its per-request context and hands the caller a fully formed,
/// immutable response exactly once. After completion the context is
/// released; late URLSession callbacks only release themselves.
@interface TLSHTTPResponse : NSObject

/// HTTP status code. 0 when no response was received (transport error).
@property (nonatomic, readonly) NSInteger statusCode;

/// Response header fields (case preserved as delivered by URLSession).
/// Empty/nil when no response was received.
@property (nonatomic, readonly, copy, nullable) NSDictionary *headers;

/// Accumulated response body. Empty when no body was received.
@property (nonatomic, readonly, copy) NSData *body;

/// Value of the `x-tls-request-id` response header, extracted
/// case-insensitively. Nil when the header was absent or no response was
/// received.
@property (nullable, nonatomic, readonly, copy) NSString *requestID;

/// Transport-level error (timeout / cancelled / redirect-rejected /
/// HTTPS-required / invalid-URL / URL-loading failure).
///
/// Nil whenever an HTTP response was received, regardless of status code:
/// 4xx/5xx are successful transport deliveries whose classification
/// (auth/quota/service) is the Core layer's job, not the transport's.
/// The error's userInfo only ever carries the safe fields declared in
/// TLSTransport.h (status code, request ID, underlying NSURLError code);
/// it never contains credentials, Authorization headers or raw bodies.
@property (nullable, nonatomic, readonly, copy) NSError *error;

- (instancetype)initWithStatusCode:(NSInteger)statusCode
                           headers:(nullable NSDictionary *)headers
                              body:(nullable NSData *)body
                         requestID:(nullable NSString *)requestID
                             error:(nullable NSError *)error NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
