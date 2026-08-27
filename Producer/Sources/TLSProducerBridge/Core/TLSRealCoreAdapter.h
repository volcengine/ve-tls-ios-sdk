// TLSRealCoreAdapter.h
// TLSProducerBridge/Core
//
// BLOCKED — do not wire into release behavior.
//
// Placeholder for the real C Core adapter. Every entry point returns a
// well-formed "C Core integration gate not met" error until the frozen
// C Mobile Core release passes ALL of the following gates:
//
//   1. Immutable Core release tag/SHA pinned (no floating branches).
//   2. Public C headers + ABI version/size contract; Bridge fail-fasts on
//      incompatible versions; all public headers compile under
//      Objective-C++ with extern "C".
//   3. Ownership contract: buffer/string lifetimes across the Swift/ObjC/C
//      boundary, explicit retain/release pairs for callback user contexts
//      (covering create failure, open failure, close timeout and callback
//      reentry), no double-free.
//   4. Threading/lifecycle contract: worker/sender never on the main thread;
//      close ordering (block new callbacks, cancel/drain in-flight, confirm
//      stopped before destroying C producer/session); no UAF on late
//      URLSession/C callbacks.
//   5. WAL contract: memory/buffered/sync durability semantics, recovery,
//      checkpoint/ACK ordering, at-least-once boundary documented.
//   6. Transactional updates: whole-group atomic credential replacement;
//      current-target destination semantics for unfinished batches.
//   7. Credential scrubbing: credentials never appear in logs, WAL,
//      manifests, file names, extended attributes or NSError userInfo.
//   8. 504/auth behavior: 401/403 suspension and 504 retry mapping
//      contract frozen; no fake terminal states.
//   9. max-age/drop/rewrite policy contract (expiredLogPolicy,
//      unauthorizedPolicy) with public-config-only drops.
//  10. LZ4 symbol namespacing: vendored Core uses the private
//      `ve_tls_iosp_*` prefix; `ve_tls_*` and LZ4 symbols are not exposed
//      to the host app.
//  11. Core test evidence: frozen-Core test suite (batch/retry/order/
//      backpressure/metrics, crash harness) passing on the pinned release.
//
// Pure Objective-C; iOS 13.0+ safe APIs only.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for TLSRealCoreAdapter placeholder errors.
FOUNDATION_EXPORT NSErrorDomain const TLSRealCoreAdapterErrorDomain;

/// Error code: the C Core integration gate is not met. All placeholder
/// entry points return this code until the 11 gates above are satisfied.
FOUNDATION_EXPORT const NSInteger TLSRealCoreAdapterErrorCodeIntegrationGateNotMet;

/// userInfo key whose value is an NSArray<NSString *> listing the
/// unsatisfied integration gates.
FOUNDATION_EXPORT NSString *const TLSRealCoreAdapterUnsatisfiedGatesKey;

/// Placeholder adapter for the real C Core.
///
/// BLOCKED — do not wire into release behavior.
@interface TLSRealCoreAdapter : NSObject

/// Plain `init`/`new` are unavailable: construction must go through
/// `initWithError:` so callers always receive the integration-gate error.
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// NO until the frozen C Core release passes every integration gate.
@property (class, nonatomic, readonly) BOOL isCoreIntegrationGateSatisfied;

/// Always fails with the integration-gate error.
- (nullable instancetype)initWithError:(NSError * _Nullable * _Nullable)error;

/// Always fails with the integration-gate error.
- (BOOL)openWithError:(NSError * _Nullable * _Nullable)error;

/// The canonical integration-gate error (domain/code/userInfo contract).
+ (NSError *)integrationGateError;

@end

NS_ASSUME_NONNULL_END
