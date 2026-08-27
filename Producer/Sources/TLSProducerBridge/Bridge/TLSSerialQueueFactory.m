// TLSSerialQueueFactory.m
// TLSProducerBridge
//

#import "TLSSerialQueueFactory.h"
#import "TLSThreadAssertions.h"

static NSString *const kTLSSerialQueueLabelPrefix = @"com.volcengine.tls.producer";

@implementation TLSSerialQueueFactory

+ (dispatch_queue_t)serialQueueWithSuffix:(NSString *)suffix {
    NSString *label = [NSString stringWithFormat:@"%@.%@", kTLSSerialQueueLabelPrefix, suffix];
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
    dispatch_queue_t queue = dispatch_queue_create(label.UTF8String, attr);
    // Tag the queue so TLSAssertIsOnQueue can verify execution context by
    // pointer identity (dispatch queue specific keys compare by pointer).
    dispatch_queue_set_specific(queue,
                                TLSSerialQueueIdentityKey,
                                (__bridge void *)queue,
                                NULL);
    return queue;
}

@end
