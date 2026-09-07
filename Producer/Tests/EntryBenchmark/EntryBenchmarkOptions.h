//
// EntryBenchmarkOptions.h
// Bounded, offline entry benchmark fixture.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Shared input for the Swift and Objective-C entry implementations. The
/// current timestamp and all four fields are created once per run and reused
/// for every admission, so the two API paths exercise the same logical event.
@interface EBBenchmarkPayload : NSObject

@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *fields;
@property(nonatomic, strong, readonly) NSDate *timestamp;
/// Sum of the UTF-8 bytes of the four field names and values.
@property(nonatomic, readonly) NSUInteger utf8Bytes;

- (instancetype)init;
+ (instancetype)new NS_UNAVAILABLE;

@end

/// Parsed launch configuration. Values are deliberately narrow so a run is
/// bounded and comparable across the two entry implementations.
@interface EBBenchmarkOptions : NSObject

@property(nonatomic, copy, readonly) NSString *runID;
@property(nonatomic, copy, readonly) NSString *entry;
@property(nonatomic, copy, readonly) NSString *persistence;
@property(nonatomic, readonly) NSUInteger rate;
@property(nonatomic, readonly) NSTimeInterval duration;
@property(nonatomic, readonly) NSTimeInterval warmup;
/// macOS CLI override. iOS always writes to its Documents directory.
@property(nonatomic, copy, nullable, readonly) NSString *outputPath;

/// The same serial callback queue is passed to either entry implementation.
@property(nonatomic, strong, readonly) dispatch_queue_t callbackQueue;

/// Shared producer configuration values. They are not launch knobs: changing
/// them would make the two entry paths incomparable.
@property(nonatomic, readonly) NSUInteger batchMaxLogCount;
@property(nonatomic, readonly) NSUInteger batchMaxRawBytes;
@property(nonatomic, readonly) NSTimeInterval batchLinger;
@property(nonatomic, readonly) NSUInteger bufferMaxBytes;
@property(nonatomic, readonly) NSTimeInterval bufferBlockTimeout;
@property(nonatomic, readonly) NSUInteger sendConcurrency;
@property(nonatomic, readonly) NSTimeInterval connectTimeout;
@property(nonatomic, readonly) NSTimeInterval requestTimeout;

+ (nullable instancetype)optionsWithArguments:(NSArray<NSString *> *)arguments
                                         error:(NSError * _Nullable * _Nullable)error;
+ (NSString *)usage;

@end

NS_ASSUME_NONNULL_END
