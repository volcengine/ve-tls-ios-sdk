// TLSSerialQueueFactory.h
// TLSProducerBridge
//
// Creates SDK-owned serial utility queues for the Bridge coordination layer
// (bridge control queue, callback queue, internal timer queue).
// Pure Objective-C; iOS 13.0+ safe APIs only.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Factory for SDK-owned serial queues.
///
/// Contract:
/// - label always has the prefix `com.volcengine.tls.producer.`;
/// - target QoS is QOS_CLASS_UTILITY;
/// - every queue is tagged with TLSSerialQueueIdentityKey so that
///   TLSAssertIsOnQueue can verify execution context.
@interface TLSSerialQueueFactory : NSObject

/// Creates a serial utility queue labeled
/// `com.volcengine.tls.producer.<suffix>`.
+ (dispatch_queue_t)serialQueueWithSuffix:(NSString *)suffix;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
