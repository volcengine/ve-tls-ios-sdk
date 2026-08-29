#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class SLSBenchmarkLog;

/// Minimal Objective-C boundary because AliyunLogProducer 4.3.4 is an
/// Objective-C pod without a Swift-importable public module contract.
@interface SLSBenchmarkClient : NSObject

- (nullable instancetype)initWithEndpoint:(NSString *)endpoint
                                persistent:(BOOL)persistent
                             persistentPath:(NSString *)persistentPath
    NS_SWIFT_NAME(init(endpoint:persistent:persistentPath:));

- (SLSBenchmarkLog *)prepareLogWithIndex:(NSUInteger)index
    NS_SWIFT_NAME(prepareLog(index:));
- (BOOL)addPreparedLog:(SLSBenchmarkLog *)log immediate:(BOOL)immediate
    NS_SWIFT_NAME(add(log:immediate:));

/// Stable numeric-only callback snapshot. No request IDs, endpoint text,
/// response bodies, or credentials cross this benchmark boundary.
- (NSDictionary<NSString *, NSNumber *> *)terminalSnapshot;

@end

@interface SLSBenchmarkLog : NSObject
@end

NS_ASSUME_NONNULL_END
