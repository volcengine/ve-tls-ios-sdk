// TLSRealCoreAdapter.m
// TLSProducerBridge/Core
//
// BLOCKED — do not wire into release behavior.
//

#import "TLSRealCoreAdapter.h"

NSErrorDomain const TLSRealCoreAdapterErrorDomain = @"com.volcengine.tls.producer";
const NSInteger TLSRealCoreAdapterErrorCodeIntegrationGateNotMet = 1000;
NSString *const TLSRealCoreAdapterUnsatisfiedGatesKey = @"TLSRealCoreAdapterUnsatisfiedGates";

@implementation TLSRealCoreAdapter

+ (BOOL)isCoreIntegrationGateSatisfied {
    // Hard-coded NO until the frozen C Core release passes all 11 gates
    // listed in TLSRealCoreAdapter.h. Do not flip this without the
    // Owner-signed Core release evidence (ledger O1).
    return NO;
}

+ (NSArray<NSString *> *)unsatisfiedGates {
    return @[
        @"1. immutable Core release tag/SHA pinned",
        @"2. public C headers + ABI version/size contract",
        @"3. ownership contract (buffer/string lifetimes, callback context retain/release)",
        @"4. threading/lifecycle contract (no main-thread worker, close ordering, no UAF)",
        @"5. WAL contract (durability, recovery, checkpoint/ACK ordering)",
        @"6. transactional updates (atomic credentials, current-target destination)",
        @"7. credential scrubbing (no credentials in logs/WAL/manifests/file names/NSError)",
        @"8. 504/auth behavior contract (401/403 suspension, 504 retry mapping)",
        @"9. max-age/drop/rewrite policy contract",
        @"10. LZ4 symbol namespacing (ve_tls_iosp_* private prefix)",
        @"11. Core test evidence on the pinned release",
    ];
}

+ (NSError *)integrationGateError {
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: @"C Core integration gate not met",
        NSLocalizedFailureReasonErrorKey:
            @"The frozen C Mobile Core release has not passed all integration "
            @"gates; RealCoreAdapter is blocked and must not be wired into "
            @"release behavior.",
        TLSRealCoreAdapterUnsatisfiedGatesKey: [self unsatisfiedGates],
    };
    return [NSError errorWithDomain:TLSRealCoreAdapterErrorDomain
                               code:TLSRealCoreAdapterErrorCodeIntegrationGateNotMet
                           userInfo:userInfo];
}

- (nullable instancetype)initWithError:(NSError * _Nullable * _Nullable)error {
    self = [super init];
    if (self != nil) {
        if (error != NULL) {
            *error = [[self class] integrationGateError];
        }
        return nil;
    }
    if (error != NULL) {
        *error = [[self class] integrationGateError];
    }
    return nil;
}

- (BOOL)openWithError:(NSError * _Nullable * _Nullable)error {
    if (error != NULL) {
        *error = [[self class] integrationGateError];
    }
    return NO;
}

@end
