//
// EntryBenchmarkOptions.m
//

#import "EntryBenchmarkOptions.h"

#include <math.h>

static NSString *const EBBenchmarkOptionsErrorDomain =
    @"com.volcengine.tls.entry-benchmark.options";

static NSError *EBOptionsError(NSString *message) {
    return [NSError errorWithDomain:EBBenchmarkOptionsErrorDomain
                                code:1
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *EBFixedValue(NSUInteger fieldIndex) {
    // Four deterministic 256-byte ASCII values. Keeping the values ASCII
    // makes UTF-8 accounting obvious while retaining enough variation that
    // compression work is still exercised consistently.
    NSMutableString *value = [NSMutableString stringWithCapacity:256];
    for (NSUInteger index = 0; index < 256; index++) {
        unichar letter = (unichar)('A' + ((index * 31 + fieldIndex * 17) % 26));
        [value appendFormat:@"%C", letter];
    }
    return value;
}

@implementation EBBenchmarkPayload

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    NSDictionary<NSString *, NSString *> *fields = @{
        @"field_a": EBFixedValue(0),
        @"field_b": EBFixedValue(1),
        @"field_c": EBFixedValue(2),
        @"field_d": EBFixedValue(3),
    };
    _fields = [fields copy];
    // A current integral-second timestamp stays within maxLogAge without
    // changing the event while either entry is being measured.
    _timestamp = [NSDate dateWithTimeIntervalSince1970:
        floor(NSDate.date.timeIntervalSince1970)];

    NSUInteger bytes = 0;
    for (NSString *key in _fields) {
        bytes += [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        bytes += [_fields[key] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    }
    _utf8Bytes = bytes;
    return self;
}

@end

@interface EBBenchmarkOptions ()

@property(nonatomic, copy, readwrite) NSString *runID;
@property(nonatomic, copy, readwrite) NSString *entry;
@property(nonatomic, copy, readwrite) NSString *persistence;
@property(nonatomic, readwrite) NSUInteger rate;
@property(nonatomic, readwrite) NSTimeInterval duration;
@property(nonatomic, readwrite) NSTimeInterval warmup;
@property(nonatomic, copy, nullable, readwrite) NSString *outputPath;
@property(nonatomic, strong, readwrite) dispatch_queue_t callbackQueue;
@property(nonatomic, readwrite) NSUInteger batchMaxLogCount;
@property(nonatomic, readwrite) NSUInteger batchMaxRawBytes;
@property(nonatomic, readwrite) NSTimeInterval batchLinger;
@property(nonatomic, readwrite) NSUInteger bufferMaxBytes;
@property(nonatomic, readwrite) NSTimeInterval bufferBlockTimeout;
@property(nonatomic, readwrite) NSUInteger sendConcurrency;
@property(nonatomic, readwrite) NSTimeInterval connectTimeout;
@property(nonatomic, readwrite) NSTimeInterval requestTimeout;

@end

@implementation EBBenchmarkOptions

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    _runID = [NSUUID UUID].UUIDString.lowercaseString;
    _entry = @"swift";
    _persistence = @"memory";
    _rate = 100;
    _duration = 300.0;
    _warmup = 60.0;
    _outputPath = nil;
    _callbackQueue = dispatch_queue_create(
        "com.volcengine.tls.entry-benchmark.callback", DISPATCH_QUEUE_SERIAL);

    // These values are intentionally shared by both entry implementations.
    _batchMaxLogCount = 500;
    _batchMaxRawBytes = 1024 * 1024;
    _batchLinger = 1.0;
    _bufferMaxBytes = 64 * 1024 * 1024;
    _bufferBlockTimeout = 1.0;
    _sendConcurrency = 1;
    _connectTimeout = 2.0;
    _requestTimeout = 5.0;
    return self;
}

+ (NSString *)usage {
    return @"Usage: EntryBenchmark [--run-id ID] [--entry swift|objc] "
            "[--persistence memory|buffered] [--rate 100|500] "
            "[--duration SEC] [--warmup SEC] [--output PATH]\n"
            "Defaults: generated --run-id, --entry swift --persistence memory --rate 100 "
            "--duration 300 --warmup 60.\n"
            "iOS always writes Documents/entry-benchmark.json; --output is "
            "for the macOS CLI.";
}

+ (nullable instancetype)optionsWithArguments:(NSArray<NSString *> *)arguments
                                         error:(NSError * _Nullable * _Nullable)error {
    EBBenchmarkOptions *options = [[self alloc] init];
    if (!options) {
        if (error) {
            *error = EBOptionsError(@"could not allocate benchmark options");
        }
        return nil;
    }

    NSUInteger first = 0;
    if (arguments.count > 0 && ![arguments[0] hasPrefix:@"--"]) {
        // NSProcessInfo.arguments and argv include the executable name. Also
        // accept a flags-only array for tests and embedding callers.
        first = 1;
    }

    for (NSUInteger index = first; index < arguments.count; index++) {
        NSString *token = arguments[index];
        if ([token isEqualToString:@"--help"] || [token isEqualToString:@"-h"]) {
            if (error) {
                *error = [NSError errorWithDomain:EBBenchmarkOptionsErrorDomain
                                               code:2
                                           userInfo:@{
                                               NSLocalizedDescriptionKey: [self usage],
                                               @"help": @YES,
                                           }];
            }
            return nil;
        }
        if (![token hasPrefix:@"--"]) {
            if (error) {
                *error = EBOptionsError([NSString stringWithFormat:
                    @"unexpected argument %@", token]);
            }
            return nil;
        }

        NSString *keyAndMaybeValue = [token substringFromIndex:2];
        NSString *key = keyAndMaybeValue;
        NSString *value = nil;
        NSRange equals = [keyAndMaybeValue rangeOfString:@"="];
        if (equals.location != NSNotFound) {
            key = [keyAndMaybeValue substringToIndex:equals.location];
            value = [keyAndMaybeValue substringFromIndex:equals.location + 1];
        } else if (index + 1 < arguments.count &&
                   ![arguments[index + 1] hasPrefix:@"--"]) {
            value = arguments[++index];
        }

        if (value.length == 0 &&
            ([key isEqualToString:@"run-id"] ||
             [key isEqualToString:@"entry"] ||
             [key isEqualToString:@"persistence"] ||
             [key isEqualToString:@"rate"] ||
             [key isEqualToString:@"duration"] ||
             [key isEqualToString:@"warmup"] ||
             [key isEqualToString:@"output"])) {
            if (error) {
                *error = EBOptionsError([NSString stringWithFormat:
                    @"--%@ requires a value", key]);
            }
            return nil;
        }

        if ([key isEqualToString:@"run-id"]) {
            if (value.length == 0 || [value rangeOfCharacterFromSet:
                                      [NSCharacterSet newlineCharacterSet]].location != NSNotFound) {
                if (error) {
                    *error = EBOptionsError(@"--run-id must be a non-empty single-line value");
                }
                return nil;
            }
            options.runID = value;
        } else if ([key isEqualToString:@"entry"]) {
            if (![value isEqualToString:@"swift"] &&
                ![value isEqualToString:@"objc"]) {
                if (error) {
                    *error = EBOptionsError(@"--entry must be swift or objc");
                }
                return nil;
            }
            options.entry = value;
        } else if ([key isEqualToString:@"persistence"]) {
            if (![value isEqualToString:@"memory"] &&
                ![value isEqualToString:@"buffered"]) {
                if (error) {
                    *error = EBOptionsError(
                        @"--persistence must be memory or buffered");
                }
                return nil;
            }
            options.persistence = value;
        } else if ([key isEqualToString:@"rate"]) {
            NSInteger rate = value.integerValue;
            if ((rate != 100 && rate != 500) ||
                ![value isEqualToString:[NSString stringWithFormat:@"%ld", (long)rate]]) {
                if (error) {
                    *error = EBOptionsError(@"--rate must be 100 or 500");
                }
                return nil;
            }
            options.rate = (NSUInteger)rate;
        } else if ([key isEqualToString:@"duration"] ||
                   [key isEqualToString:@"warmup"]) {
            NSScanner *scanner = [NSScanner scannerWithString:value ?: @""];
            double parsed = 0;
            if (![scanner scanDouble:&parsed] || !scanner.isAtEnd ||
                !isfinite(parsed) || parsed < 0 || parsed > 86400.0) {
                if (error) {
                    *error = EBOptionsError([NSString stringWithFormat:
                        @"--%@ must be a finite number in [0, 86400]", key]);
                }
                return nil;
            }
            if ([key isEqualToString:@"duration"]) {
                options.duration = parsed;
            } else {
                options.warmup = parsed;
            }
        } else if ([key isEqualToString:@"output"]) {
            options.outputPath = [value stringByStandardizingPath];
        } else {
            if (error) {
                *error = EBOptionsError([NSString stringWithFormat:
                    @"unknown option --%@", key]);
            }
            return nil;
        }
    }

    if (options.duration <= options.warmup) {
        if (error) {
            *error = EBOptionsError(
                @"--duration must be greater than --warmup");
        }
        return nil;
    }
    // The latency array is preallocated before the timed run. Keep the
    // maximum number of scheduled add attempts bounded at about 1.2 MiB
    // (150,000 doubles), including the largest supported rate of 500/sec.
    if ((double)options.rate * options.duration > 150000.0) {
        if (error) {
            *error = EBOptionsError(
                @"rate * duration must be <= 150000 for bounded latency storage");
        }
        return nil;
    }
    return options;
}

@end
