//
// EntryBenchmarkEntry.m
//

#import "EntryBenchmarkEntry.h"

@interface EBAddOutcome ()

@property(nonatomic, readwrite, getter=isAccepted) BOOL accepted;
@property(nonatomic, copy, nullable, readwrite) NSString *errorCode;
@property(nonatomic, readwrite) NSTimeInterval latencySeconds;

- (instancetype)initPrivateWithAccepted:(BOOL)accepted
                               errorCode:(nullable NSString *)errorCode
                                 latency:(NSTimeInterval)latencySeconds;

@end

@implementation EBAddOutcome

+ (instancetype)acceptedOutcomeWithLatency:(NSTimeInterval)latencySeconds {
    EBAddOutcome *outcome = [[self alloc] initPrivateWithAccepted:YES
                                                         errorCode:nil
                                                           latency:latencySeconds];
    return outcome;
}

+ (instancetype)rejectedOutcomeWithErrorCode:(NSString *)errorCode
                                      latency:(NSTimeInterval)latencySeconds {
    return [[self alloc] initPrivateWithAccepted:NO
                                       errorCode:errorCode.length > 0
                                           ? errorCode
                                           : @"unknown"
                                         latency:latencySeconds];
}

- (instancetype)initPrivateWithAccepted:(BOOL)accepted
                               errorCode:(NSString *)errorCode
                                 latency:(NSTimeInterval)latencySeconds {
    self = [super init];
    if (!self) {
        return nil;
    }
    _accepted = accepted;
    _errorCode = [errorCode copy];
    _latencySeconds = latencySeconds;
    return self;
}

@end
