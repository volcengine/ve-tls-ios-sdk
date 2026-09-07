// TLSThreadAssertions.m
// TLSProducerBridge
//

#import "TLSThreadAssertions.h"

const void *TLSSerialQueueIdentityKey = &TLSSerialQueueIdentityKey;

void TLSAssertNotMainThread(void) {
    // NSCAssert (C-function variant of NSAssert, which references self/_cmd and
    // only compiles inside ObjC method scope) is compiled out in release
    // builds; the function then returns safely with no side effects
    // This is the SDK execution-domain contract.
    NSCAssert(![NSThread isMainThread],
              @"TLSProducer: code must not run on the main thread");
}

void TLSAssertIsOnQueue(dispatch_queue_t queue) {
    if (queue == nil) {
        NSCAssert(NO, @"TLSAssertIsOnQueue called with a nil queue");
        return;
    }
    const void *currentIdentity = dispatch_get_specific(TLSSerialQueueIdentityKey);
    NSCAssert(currentIdentity == (__bridge const void *)queue,
              @"TLSProducer: code must run on the designated SDK-owned serial queue %@; "
              @"current queue context is %p (only queues created by "
              @"TLSSerialQueueFactory carry the identity tag)",
              queue, currentIdentity);
}
