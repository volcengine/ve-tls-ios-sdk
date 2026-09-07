//
// EntryBenchmarkEntry.h
// Cross-language entry contract used by the shared scheduler.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class EBBenchmarkOptions;
@class EBBenchmarkPayload;

@interface EBAddOutcome : NSObject

@property(nonatomic, readonly, getter=isAccepted) BOOL accepted;
/// Stable, non-sensitive error code for a rejected admission, if available.
@property(nonatomic, copy, nullable, readonly) NSString *errorCode;
/// Monotonic duration of the actual public `add` call, excluding the shared
/// scheduler's cross-language dispatch. Both entries measure this internally.
@property(nonatomic, readonly) NSTimeInterval latencySeconds;

+ (instancetype)acceptedOutcomeWithLatency:(NSTimeInterval)latencySeconds;
+ (instancetype)rejectedOutcomeWithErrorCode:(NSString *)errorCode
                                    latency:(NSTimeInterval)latencySeconds
    NS_SWIFT_NAME(rejectedOutcome(withErrorCode:latency:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

typedef void (^EBEntryCompletion)(NSError * _Nullable error);
typedef void (^EBTerminalResultHandler)(BOOL success,
                                        NSUInteger rawBytes,
                                        NSUInteger compressedBytes);

/// Both implementations are real public SDK entry points. The scheduler owns
/// timing and measurement; entries only open, admit the pre-built event, and
/// close/drain.
@protocol EBBenchmarkEntry <NSObject>

@property(nonatomic, copy, nullable) EBTerminalResultHandler terminalResultHandler;

- (void)startOpeningWithCompletion:(EBEntryCompletion)completion;
- (EBAddOutcome *)admitOne;
- (void)startClosingWithTimeout:(NSTimeInterval)timeout
                     completion:(EBEntryCompletion)completion;

@end

NS_ASSUME_NONNULL_END
