// TLSThreadAssertions.h
// TLSProducerBridge
//
// Thread/queue assertion helpers for the Bridge coordination layer.
// Pure Objective-C; iOS 13.0+ safe APIs only.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Identity key used to tag SDK-owned serial queues. TLSSerialQueueFactory tags
/// every queue it creates with this key (value = the queue pointer itself);
/// TLSAssertIsOnQueue verifies the current queue via dispatch_get_specific.
/// Exposed so the factory and the assertions share one pointer-identity key.
FOUNDATION_EXPORT const void *TLSSerialQueueIdentityKey;

/// Asserts (debug builds only) that the current code is NOT running on the
/// main thread. In release builds this compiles to a safe no-op return.
///
/// Rationale (Beta design §6.2/§8.1): C sender/transport work must never run
/// on the main thread; this is the cheap tripwire for that contract.
FOUNDATION_EXPORT void TLSAssertNotMainThread(void);

/// Asserts (debug builds only) that the current code is running on the given
/// SDK-owned serial queue. The queue MUST have been created by
/// TLSSerialQueueFactory (queues are tagged via dispatch_queue_set_specific);
/// for untagged queues the assertion always fails in debug. Release: no-op.
FOUNDATION_EXPORT void TLSAssertIsOnQueue(dispatch_queue_t queue);

NS_ASSUME_NONNULL_END
