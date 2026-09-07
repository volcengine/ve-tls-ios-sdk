//
// EntryBenchmarkMetrics.m
//

#import "EntryBenchmarkMetrics.h"

#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
#include <string.h>

double EBMonotonicSeconds(void) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        (void)mach_timebase_info(&timebase);
    });
    if (timebase.denom == 0) {
        return 0;
    }
    uint64_t ticks = mach_absolute_time();
    return (double)ticks * (double)timebase.numer /
        (double)timebase.denom / 1000000000.0;
}

static double EBRusageCPUSeconds(const struct rusage *usage) {
    if (!usage) {
        return 0;
    }
    return (double)usage->ru_utime.tv_sec +
        (double)usage->ru_utime.tv_usec / 1000000.0 +
        (double)usage->ru_stime.tv_sec +
        (double)usage->ru_stime.tv_usec / 1000000.0;
}

BOOL EBReadSystemSample(EBBenchmarkSystemSample *sample) {
    if (!sample) {
        return NO;
    }
    memset(sample, 0, sizeof(*sample));

    mach_task_basic_info_data_t taskInfo;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t taskResult = task_info(
        mach_task_self(),
        MACH_TASK_BASIC_INFO,
        (task_info_t)&taskInfo,
        &count);
    if (taskResult != KERN_SUCCESS) {
        return NO;
    }

    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) {
        return NO;
    }

    sample->residentSizeBytes = (uint64_t)taskInfo.resident_size;
    sample->cpuSeconds = EBRusageCPUSeconds(&usage);
    return YES;
}

@interface EBBenchmarkMetrics ()

@property(nonatomic) BOOL measuring;
@property(nonatomic) NSUInteger sampleCount;
@property(nonatomic) double rssSum;
@property(nonatomic) uint64_t rssPeak;
@property(nonatomic) double cpuStart;
@property(nonatomic) double cpuEnd;
@property(nonatomic) BOOL startValid;
@property(nonatomic) BOOL endValid;
@property(nonatomic) NSUInteger samplingErrorCount;

@end

@implementation EBBenchmarkMetrics

- (void)beginMeasurement {
    self.measuring = YES;
    self.sampleCount = 0;
    self.rssSum = 0;
    self.rssPeak = 0;
    self.cpuStart = 0;
    self.cpuEnd = 0;
    self.startValid = NO;
    self.endValid = NO;
    self.samplingErrorCount = 0;

    EBBenchmarkSystemSample sample;
    if (EBReadSystemSample(&sample)) {
        self.startValid = YES;
        self.cpuStart = sample.cpuSeconds;
        self.cpuEnd = sample.cpuSeconds;
        self.sampleCount = 1;
        self.rssSum = (double)sample.residentSizeBytes;
        self.rssPeak = sample.residentSizeBytes;
    } else {
        self.samplingErrorCount += 1;
    }
}

- (void)sampleMeasurement {
    if (!self.measuring) {
        return;
    }
    EBBenchmarkSystemSample sample;
    if (!EBReadSystemSample(&sample)) {
        self.samplingErrorCount += 1;
        return;
    }
    self.endValid = YES;
    self.cpuEnd = sample.cpuSeconds;
    self.sampleCount += 1;
    self.rssSum += (double)sample.residentSizeBytes;
    if (sample.residentSizeBytes > self.rssPeak) {
        self.rssPeak = sample.residentSizeBytes;
    }
}

- (void)finishMeasurement {
    if (!self.measuring) {
        return;
    }
    // The final RSS/CPU read belongs to the measurement window and is taken
    // before the measuring flag is cleared.
    [self sampleMeasurement];
    self.measuring = NO;
}

- (BOOL)isValid {
    return self.startValid && self.endValid && self.sampleCount > 0 &&
        self.samplingErrorCount == 0;
}

- (NSDictionary<NSString *, NSNumber *> *)jsonFieldsForMeasuredDuration:(NSTimeInterval)duration {
    BOOL valid = [self isValid];
    double mean = valid && self.sampleCount > 0
        ? self.rssSum / (double)self.sampleCount
        : 0;
    double cpuDelta = valid && self.cpuEnd >= self.cpuStart
        ? self.cpuEnd - self.cpuStart
        : 0;
    double normalized = valid && duration > 0 ? cpuDelta / duration : 0;
    return @{
        @"metrics_valid": @(valid),
        @"sampling_error_count": @(self.samplingErrorCount),
        @"rss_sample_count": @(self.sampleCount),
        @"rss_mean_bytes": @(mean),
        @"rss_peak_bytes": @(self.rssPeak),
        @"cpu_cumulative_seconds": @(cpuDelta),
        @"cpu_onecore_normalized": @(normalized),
    };
}

@end
