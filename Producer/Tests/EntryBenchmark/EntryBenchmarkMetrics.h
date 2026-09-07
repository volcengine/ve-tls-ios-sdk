//
// EntryBenchmarkMetrics.h
// Identical Mach/getrusage process sampling for iOS and macOS.
//

#import <Foundation/Foundation.h>

#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    uint64_t residentSizeBytes;
    double cpuSeconds;
} EBBenchmarkSystemSample;

/// Monotonic clock used for both scheduling and measured duration.
FOUNDATION_EXPORT double EBMonotonicSeconds(void);

/// Reads process RSS through task_info and cumulative user+system CPU through
/// getrusage. The same function is compiled into both app targets.
FOUNDATION_EXPORT BOOL EBReadSystemSample(EBBenchmarkSystemSample *sample);

@interface EBBenchmarkMetrics : NSObject

- (void)beginMeasurement;
- (void)sampleMeasurement;
- (void)finishMeasurement;

/// NO means a required start/end system sample failed. Callers must treat the
/// corresponding numeric fields as unavailable rather than as zero values.
- (BOOL)isValid;

/// Returns only measurement-window samples. CPU is cumulative process CPU;
/// cpu_onecore_normalized is cpu delta divided by monotonic wall duration.
- (NSDictionary<NSString *, NSNumber *> *)jsonFieldsForMeasuredDuration:(NSTimeInterval)duration;

@end

NS_ASSUME_NONNULL_END
