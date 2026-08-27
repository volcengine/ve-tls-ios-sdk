// TLSThreadAssertions.m
// TLSProducerBridge
//

#import "TLSThreadAssertions.h"

const void *TLSSerialQueueIdentityKey = &TLSSerialQueueIdentityKey;

void TLSAssertNotMainThread(void) {
    // NSAssert is compiled out in release builds; the function then returns
    // safely with no side effects (Beta design §6.2 execution-domain contract).
    NSAssert(![NSThread isMainThread],
             @"TLSProducer: code must not run on the main thread");
}

void TLSAssertIsOnQueue(dispatch_queue_t queue) {
    if (queue == nil) {
        NSAssert(NO, @"TLSAssertIsOnQueue called with a nil queue");
        return;
    }
    const void *currentIdentity = dispatch_get_specific(TLSSerialQueueIdentityKey);
    NSAssert(currentIdentity == (__bridge const void *)queue,
             @"TLSProducer: code must run on the designated SDK-owned serial queue %@; "
             @"current queue context is %p (only queues created by "
             @"TLSSerialQueueFactory carry the identity tag)",
             queue, currentIdentity);
}
