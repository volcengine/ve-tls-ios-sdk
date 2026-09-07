//
// EntryBenchmarkRunner.m
// Shared timing, counters, drain, and JSON artifact implementation.
//

#import "EntryBenchmarkRunner.h"

#import "EntryBenchmarkMetrics.h"
#import "EntryBenchmarkProtocol.h"

#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <TargetConditionals.h>

static NSDictionary<NSString *, id> *EBSafeErrorFields(NSError *error);
static NSString *EBISO8601(NSDate *date);

@interface EBBenchmarkCounters : NSObject {
    NSLock *_lock;
    uint64_t _accepted;
    uint64_t _rejected;
    uint64_t _terminalSuccess;
    uint64_t _terminalFailure;
    uint64_t _terminalSuccessRawBytes;
    uint64_t _terminalSuccessCompressedBytes;
    uint64_t _terminalFailureRawBytes;
    uint64_t _terminalFailureCompressedBytes;
    uint64_t _latencySamples;
    uint64_t _latencySampleOverflowCount;
    NSUInteger _latencyCapacity;
    double *_latencyValues;
}

- (instancetype)initWithLatencyCapacity:(NSUInteger)capacity;
- (void)recordAddOutcome:(EBAddOutcome *)outcome;
- (void)recordTerminalSuccess:(BOOL)success
                      rawBytes:(NSUInteger)rawBytes
              compressedBytes:(NSUInteger)compressedBytes;
- (NSDictionary<NSString *, id> *)jsonFieldsForPayloadBytes:(NSUInteger)payloadBytes
                                                    duration:(NSTimeInterval)duration;

@end

@implementation EBBenchmarkCounters

- (instancetype)init {
    return [self initWithLatencyCapacity:0];
}

- (instancetype)initWithLatencyCapacity:(NSUInteger)capacity {
    self = [super init];
    if (!self) {
        return nil;
    }
    _lock = [[NSLock alloc] init];
    _latencyCapacity = capacity;
    if (capacity > 0) {
        _latencyValues = calloc(capacity, sizeof(double));
    }
    return self;
}

- (void)dealloc {
    free(_latencyValues);
}

static int EBCompareLatencyValues(const void *left, const void *right) {
    double leftValue = *(const double *)left;
    double rightValue = *(const double *)right;
    if (leftValue < rightValue) {
        return -1;
    }
    if (leftValue > rightValue) {
        return 1;
    }
    return 0;
}

static double EBLatencyNearestRank(const double *values,
                                   uint64_t sampleCount,
                                   double quantile) {
    if (!values || sampleCount == 0) {
        return 0;
    }
    uint64_t rank = (uint64_t)ceil((double)sampleCount * quantile);
    rank = MAX(rank, (uint64_t)1);
    rank = MIN(rank, sampleCount);
    return values[rank - 1];
}

- (void)recordAddOutcome:(EBAddOutcome *)outcome {
    if (!outcome) {
        return;
    }
    [_lock lock];
    if (outcome.accepted) {
        _accepted += 1;
    } else {
        _rejected += 1;
    }
    _latencySamples += 1;
    if (_latencyValues && _latencySamples <= _latencyCapacity) {
        _latencyValues[_latencySamples - 1] = outcome.latencySeconds;
    } else {
        _latencySampleOverflowCount += 1;
    }
    [_lock unlock];
}

- (void)recordTerminalSuccess:(BOOL)success
                      rawBytes:(NSUInteger)rawBytes
              compressedBytes:(NSUInteger)compressedBytes {
    [_lock lock];
    if (success) {
        _terminalSuccess += 1;
        _terminalSuccessRawBytes += (uint64_t)rawBytes;
        _terminalSuccessCompressedBytes += (uint64_t)compressedBytes;
    } else {
        _terminalFailure += 1;
        _terminalFailureRawBytes += (uint64_t)rawBytes;
        _terminalFailureCompressedBytes += (uint64_t)compressedBytes;
    }
    [_lock unlock];
}

- (NSDictionary<NSString *, id> *)jsonFieldsForPayloadBytes:(NSUInteger)payloadBytes
                                                    duration:(NSTimeInterval)duration {
    [_lock lock];
    uint64_t accepted = _accepted;
    uint64_t rejected = _rejected;
    uint64_t terminalSuccess = _terminalSuccess;
    uint64_t terminalFailure = _terminalFailure;
    uint64_t successRawBytes = _terminalSuccessRawBytes;
    uint64_t successCompressedBytes = _terminalSuccessCompressedBytes;
    uint64_t failureRawBytes = _terminalFailureRawBytes;
    uint64_t failureCompressedBytes = _terminalFailureCompressedBytes;
    uint64_t latencySamples = _latencySamples;
    uint64_t latencyOverflow = _latencySampleOverflowCount;
    double *latencyValues = NULL;
    if (_latencyValues && latencySamples > 0) {
        latencyValues = calloc((size_t)latencySamples, sizeof(double));
        if (latencyValues) {
            memcpy(latencyValues,
                   _latencyValues,
                   (size_t)MIN(latencySamples, (uint64_t)_latencyCapacity) * sizeof(double));
        } else {
            latencyOverflow += 1;
        }
    }
    [_lock unlock];

    BOOL latencyExact = latencyOverflow == 0 && latencyValues != NULL;
    double p50 = 0;
    double p99 = 0;
    if (latencyExact) {
        qsort(latencyValues,
              (size_t)latencySamples,
              sizeof(double),
              EBCompareLatencyValues);
        p50 = EBLatencyNearestRank(latencyValues, latencySamples, 0.50);
        p99 = EBLatencyNearestRank(latencyValues, latencySamples, 0.99);
    }
    free(latencyValues);

    uint64_t attempts = accepted + rejected;
    uint64_t acceptedPayloadBytes = accepted * (uint64_t)payloadBytes;
    double throughput = duration > 0
        ? (double)acceptedPayloadBytes / duration
        : 0;
    return @{
        @"accepted": @(accepted),
        @"rejected": @(rejected),
        @"add_attempts": @(attempts),
        @"utf8_payload_bytes_per_log": @(payloadBytes),
        @"utf8_payload_bytes_accepted": @(acceptedPayloadBytes),
        @"utf8_payload_throughput_bytes_per_second": @(throughput),
        @"add_latency_sample_count": @(latencySamples),
        @"add_latency_exact": @(latencyExact),
        @"add_latency_sample_overflow_count": @(latencyOverflow),
        @"add_latency_p50_ms": latencyExact ? @(p50 * 1000.0) : [NSNull null],
        @"add_latency_p99_ms": latencyExact ? @(p99 * 1000.0) : [NSNull null],
        // A terminal callback is a terminal batch result, not a log count.
        @"terminal_success": @(terminalSuccess),
        @"terminal_failure": @(terminalFailure),
        @"terminal_success_raw_bytes": @(successRawBytes),
        @"terminal_success_compressed_bytes": @(successCompressedBytes),
        @"terminal_failure_raw_bytes": @(failureRawBytes),
        @"terminal_failure_compressed_bytes": @(failureCompressedBytes),
    };
}

@end

@interface EBBenchmarkRunner ()

@property(nonatomic, strong) EBBenchmarkOptions *options;
@property(nonatomic, strong) EBBenchmarkPayload *payload;
@property(nonatomic, strong) id<EBBenchmarkEntry> entry;
@property(nonatomic, copy) EBBenchmarkCompletion completion;
@property(nonatomic, strong) EBBenchmarkMetrics *metrics;
@property(nonatomic, strong) EBBenchmarkCounters *counters;
@property(nonatomic, strong) dispatch_queue_t runQueue;
@property(nonatomic) dispatch_source_t addTimer;
@property(nonatomic) dispatch_source_t sampleTimer;
@property(nonatomic, copy) NSString *state;
@property(nonatomic, strong) NSDate *startedAt;
@property(nonatomic, strong) NSDate *finishedAt;
@property(nonatomic, copy) NSString *artifactPath;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *openErrorFields;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *closeErrorFields;
@property(nonatomic, copy, nullable) NSError *runError;
@property(nonatomic) double measurementStart;
@property(nonatomic) double measurementEnd;
@property(nonatomic) BOOL measurementStarted;
@property(nonatomic) BOOL measurementFinished;
@property(nonatomic) BOOL closeAttempted;
@property(nonatomic) BOOL closeSucceeded;
@property(nonatomic) BOOL closeFailed;

@end

@implementation EBBenchmarkRunner

- (instancetype)initWithOptions:(EBBenchmarkOptions *)options
                         payload:(EBBenchmarkPayload *)payload
                           entry:(id<EBBenchmarkEntry>)entry
                      completion:(EBBenchmarkCompletion)completion {
    self = [super init];
    if (!self) {
        return nil;
    }
    _options = options;
    _payload = payload;
    _entry = entry;
    _completion = [completion copy];
    _metrics = [[EBBenchmarkMetrics alloc] init];
    // Preallocate the bounded latency sample storage before the timed run.
    // Options reject rate*duration above 150,000, so this is about 1.2 MiB.
    NSUInteger latencyCapacity = (NSUInteger)ceil(
        (double)options.rate * options.duration) + 1;
    _counters = [[EBBenchmarkCounters alloc]
        initWithLatencyCapacity:latencyCapacity];
    _runQueue = dispatch_queue_create(
        "com.volcengine.tls.entry-benchmark.runner", DISPATCH_QUEUE_SERIAL);
    _state = @"idle";
    __weak EBBenchmarkRunner *weakSelf = self;
    entry.terminalResultHandler = ^(BOOL success,
                                    NSUInteger rawBytes,
                                    NSUInteger compressedBytes) {
        EBBenchmarkRunner *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        dispatch_async(strongSelf.runQueue, ^{
            // Results delivered while draining still belong to the measured
            // producer instance. Warm-up callbacks before this boundary are
            // intentionally excluded.
            if (strongSelf.measurementStarted &&
                ![strongSelf.state isEqualToString:@"finished"]) {
                [strongSelf.counters recordTerminalSuccess:success
                                                   rawBytes:rawBytes
                                           compressedBytes:compressedBytes];
            }
        });
    };
    return self;
}

- (void)start {
    dispatch_async(self.runQueue, ^{
        [self startOnRunQueue];
    });
}

- (void)startOnRunQueue {
    if (![self.state isEqualToString:@"idle"]) {
        return;
    }
    self.state = @"opening";
    self.startedAt = [NSDate date];
    [EBImmediateURLProtocol reset];

    printf("ENTRY_BENCHMARK_START run_id=%s entry=%s persistence=%s rate=%lu duration=%.3f warmup=%.3f\n",
           self.options.runID.UTF8String,
           self.options.entry.UTF8String,
           self.options.persistence.UTF8String,
           (unsigned long)self.options.rate,
           self.options.duration,
           self.options.warmup);
    fflush(stdout);

    NSURL *artifactURL = [self outputURL];
    self.artifactPath = artifactURL.path;
    NSError *removeError = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:artifactURL.path] &&
        ![[NSFileManager defaultManager] removeItemAtURL:artifactURL error:&removeError]) {
        self.runError = removeError;
        [self finishWithoutMeasurementOnRunQueue];
        return;
    }

    __weak EBBenchmarkRunner *weakSelf = self;
    [self.entry startOpeningWithCompletion:^(NSError * _Nullable error) {
        EBBenchmarkRunner *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        dispatch_async(strongSelf.runQueue, ^{
            [strongSelf openedWithError:error];
        });
    }];
}

- (void)openedWithError:(NSError *)error {
    if (error) {
        self.openErrorFields = EBSafeErrorFields(error);
        self.runError = error;
        [self finishWithoutMeasurementOnRunQueue];
        return;
    }
    self.state = @"warmup";
    NSTimeInterval interval = 1.0 / (double)self.options.rate;
    uint64_t intervalNanos = (uint64_t)MAX(1.0, interval * 1000000000.0);
    self.addTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.runQueue);
    dispatch_source_set_timer(
        self.addTimer,
        dispatch_time(DISPATCH_TIME_NOW, intervalNanos),
        intervalNanos,
        MAX((uint64_t)1, intervalNanos / 10));
    __weak EBBenchmarkRunner *weakSelf = self;
    dispatch_source_set_event_handler(self.addTimer, ^{
        EBBenchmarkRunner *strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf performScheduledAdd];
        }
    });
    dispatch_resume(self.addTimer);

    if (self.options.warmup <= 0) {
        [self beginMeasurementAt:EBMonotonicSeconds()];
    } else {
        [self scheduleMeasurementStartAfter:self.options.warmup];
    }
}

- (void)scheduleMeasurementStartAfter:(NSTimeInterval)delay {
    __weak EBBenchmarkRunner *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delay * 1000000000.0)),
                   self.runQueue, ^{
        EBBenchmarkRunner *strongSelf = weakSelf;
        if (strongSelf && !strongSelf.measurementStarted) {
            [strongSelf beginMeasurementAt:EBMonotonicSeconds()];
        }
    });
}

- (void)beginMeasurementAt:(double)start {
    if (self.measurementStarted || self.measurementFinished) {
        return;
    }
    self.measurementStarted = YES;
    self.state = @"measurement";
    self.measurementStart = start;
    [self.metrics beginMeasurement];

    self.sampleTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.runQueue);
    uint64_t sampleInterval = 250000000;
    dispatch_source_set_timer(
        self.sampleTimer,
        dispatch_time(DISPATCH_TIME_NOW, 0),
        sampleInterval,
        25000000);
    __weak EBBenchmarkRunner *weakSelf = self;
    dispatch_source_set_event_handler(self.sampleTimer, ^{
        EBBenchmarkRunner *strongSelf = weakSelf;
        if (strongSelf && !strongSelf.measurementFinished) {
            [strongSelf.metrics sampleMeasurement];
        }
    });
    dispatch_resume(self.sampleTimer);
    [self scheduleMeasurementEndAfter:self.options.duration - self.options.warmup];
}

- (void)scheduleMeasurementEndAfter:(NSTimeInterval)duration {
    __weak EBBenchmarkRunner *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(duration * 1000000000.0)),
                   self.runQueue, ^{
        EBBenchmarkRunner *strongSelf = weakSelf;
        if (strongSelf && !strongSelf.measurementFinished) {
            [strongSelf finishMeasurementAt:EBMonotonicSeconds()];
        }
    });
}

- (void)performScheduledAdd {
    if (self.measurementFinished) {
        return;
    }
    EBAddOutcome *outcome = [self.entry admitOne];
    if (self.measurementStarted && !self.measurementFinished) {
        [self.counters recordAddOutcome:outcome];
    }
}

- (void)finishMeasurementAt:(double)end {
    if (!self.measurementStarted || self.measurementFinished) {
        return;
    }
    self.measurementFinished = YES;
    self.state = @"draining";
    self.measurementEnd = MAX(end, self.measurementStart);
    [self.metrics finishMeasurement];
    if (self.addTimer) {
        dispatch_source_cancel(self.addTimer);
        self.addTimer = nil;
    }
    if (self.sampleTimer) {
        dispatch_source_cancel(self.sampleTimer);
        self.sampleTimer = nil;
    }

    // Let the normal linger window settle before asking the producer to close.
    // This is bounded and makes the close/drain boundary explicit for buffered
    // persistence, which does not promise that every admitted item is sent.
    NSTimeInterval drainWait = MIN(MAX(self.options.batchLinger, 0), 5.0);
    __weak EBBenchmarkRunner *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(drainWait * 1000000000.0)),
                   self.runQueue, ^{
        EBBenchmarkRunner *strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf beginCloseOnRunQueue];
        }
    });
}

- (void)beginCloseOnRunQueue {
    if (self.closeAttempted || [self.state isEqualToString:@"finished"]) {
        return;
    }
    self.closeAttempted = YES;
    __weak EBBenchmarkRunner *weakSelf = self;
    [self.entry startClosingWithTimeout:30.0 completion:^(NSError * _Nullable error) {
        EBBenchmarkRunner *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        dispatch_async(strongSelf.runQueue, ^{
            if (error) {
                strongSelf.closeFailed = YES;
                strongSelf.closeErrorFields = EBSafeErrorFields(error);
                if (!strongSelf.runError) {
                    strongSelf.runError = error;
                }
            } else {
                strongSelf.closeSucceeded = YES;
            }
            [strongSelf finishArtifactOnRunQueue];
        });
    }];
}

- (void)finishWithoutMeasurementOnRunQueue {
    if (self.measurementStarted) {
        self.measurementFinished = YES;
        [self.metrics finishMeasurement];
    }
    [self finishArtifactOnRunQueue];
}

- (NSURL *)outputURL {
#if TARGET_OS_IPHONE
    NSURL *documents = [[[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    return [documents URLByAppendingPathComponent:@"entry-benchmark.json"];
#else
    if (self.options.outputPath.length > 0) {
        return [NSURL fileURLWithPath:self.options.outputPath];
    }
    NSURL *documents = [[[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    return [documents URLByAppendingPathComponent:@"entry-benchmark.json"];
#endif
}

- (void)finishArtifactOnRunQueue {
    if ([self.state isEqualToString:@"finished"]) {
        return;
    }
    self.state = @"finished";
    self.finishedAt = [NSDate date];

    NSTimeInterval measuredDuration = self.measurementEnd > self.measurementStart
        ? self.measurementEnd - self.measurementStart
        : 0;
    NSMutableDictionary<NSString *, id> *artifact = [NSMutableDictionary dictionary];
    artifact[@"schema_version"] = @1;
    artifact[@"run_id"] = self.options.runID;
    artifact[@"entry"] = self.options.entry;
    artifact[@"platform"] =
#if TARGET_OS_IPHONE
        @"iOS";
#else
        @"macOS";
#endif
    artifact[@"started_at"] = self.startedAt ? EBISO8601(self.startedAt) : @"";
    artifact[@"finished_at"] = self.finishedAt ? EBISO8601(self.finishedAt) : @"";
    artifact[@"rate"] = @(self.options.rate);
    artifact[@"persistence"] = self.options.persistence;
    artifact[@"compression"] = @"lz4";
    artifact[@"duration_seconds_requested"] = @(self.options.duration);
    artifact[@"warmup_seconds_requested"] = @(self.options.warmup);
    artifact[@"measurement_duration_seconds"] = @(measuredDuration);
    artifact[@"measurement_started"] = @(self.measurementStarted);
    artifact[@"drain_wait_seconds"] = @(MIN(MAX(self.options.batchLinger, 0), 5.0));
    artifact[@"output_path"] = self.artifactPath ?: @"";

    artifact[@"payload"] = @{
        @"field_count": @(self.payload.fields.count),
        @"utf8_payload_bytes_per_log": @(self.payload.utf8Bytes),
        @"timestamp_unix_seconds": @([self.payload.timestamp timeIntervalSince1970]),
        @"event_construction": @"preconstructed_once_per_entry_and_reused",
    };
    NSDictionary<NSString *, id> *counterFields =
        [self.counters jsonFieldsForPayloadBytes:self.payload.utf8Bytes
                                         duration:measuredDuration];
    artifact[@"counters"] = counterFields;
    artifact[@"metrics"] = [self.metrics jsonFieldsForMeasuredDuration:measuredDuration];
    artifact[@"requests"] = @{
        @"urlprotocol_200_count": @([EBImmediateURLProtocol requestCount]),
        @"body_storage": @"none",
    };
    artifact[@"close"] = @{
        @"attempted": @(self.closeAttempted),
        @"success": @(self.closeSucceeded),
        @"failure": @(self.closeFailed),
        @"timeout_seconds": @30.0,
    };
    if (self.openErrorFields) {
        artifact[@"open_error"] = self.openErrorFields;
    }
    if (self.closeErrorFields) {
        artifact[@"close_error"] = self.closeErrorFields;
    }
    BOOL metricsValid = [self.metrics isValid];
    BOOL latencyExact = [counterFields[@"add_latency_exact"] boolValue];
    BOOL resultValid = metricsValid && latencyExact;
    artifact[@"status"] = (!self.runError && resultValid) ? @"success" : @"failure";
    if (!metricsValid && !self.runError) {
        self.runError = [NSError errorWithDomain:@"EntryBenchmarkMetrics"
                                              code:1
                                          userInfo:@{
                                              NSLocalizedDescriptionKey:
                                                  @"required measurement system sample failed",
                                          }];
    } else if (!latencyExact && !self.runError) {
        self.runError = [NSError errorWithDomain:@"EntryBenchmarkLatency"
                                              code:1
                                          userInfo:@{
                                              NSLocalizedDescriptionKey:
                                                  @"exact add latency samples were unavailable",
                                          }];
    }

    NSError *serializationError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:artifact
                                                     options:NSJSONWritingPrettyPrinted
                                                       error:&serializationError];
    NSError *writeError = serializationError;
    if (data && !writeError) {
        NSURL *URL = [NSURL fileURLWithPath:self.artifactPath ?: @""];
        NSString *directory = URL.URLByDeletingLastPathComponent.path;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:&writeError]) {
            data = nil;
        } else if (![data writeToURL:URL options:NSDataWritingAtomic error:&writeError]) {
            data = nil;
        }
    }
    self.finishedAt = [NSDate date];
    NSString *markerPath = self.artifactPath ?: @"";
    printf("ENTRY_BENCHMARK_JSON run_id=%s path=%s status=%s\n",
           self.options.runID.UTF8String,
           markerPath.UTF8String,
           (!self.runError && !writeError && resultValid) ? "success" : "failure");
    fflush(stdout);

    NSError *finalError = self.runError ?: writeError;
    EBBenchmarkCompletion completion = self.completion;
    if (completion) {
        completion(writeError ? nil : [NSURL fileURLWithPath:markerPath], finalError);
    }
}

static NSDictionary<NSString *, id> *EBSafeErrorFields(NSError *error) {
    if (!error) {
        return @{};
    }
    return @{
        @"domain": error.domain ?: @"",
        @"code": @(error.code),
    };
}

static NSString *EBISO8601(NSDate *date) {
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
        NSISO8601DateFormatWithFractionalSeconds;
    return [formatter stringFromDate:date] ?: @"";
}

@end
