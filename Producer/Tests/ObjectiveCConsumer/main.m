// Pure Objective-C external-consumer smoke test.
//
// This file intentionally imports only the public SDK module. It
// must stay free of Swift source and must not include TLSProducerBridge or the
// vendored C Core headers. The verification script copies this file into a
// temporary CocoaPods consumer project and builds it for macOS and iOS
// Simulator.

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#if !TARGET_OS_OSX
#import <UIKit/UIKit.h>
#endif
#include <math.h>
#include <stdint.h>
@import VolcengineTLSProducer;

static NSString *const TLSExpectedProducerUserAgent =
    @"volc-tls-ios/producer/v2.0.1";
static NSString *const TLSExpectedAPIVersion = @"0.3.0";

static void TLSRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String ?: "assertion failed");
        exit(EXIT_FAILURE);
    }
}

static BOOL TLSRunLoopWait(BOOL (^predicate)(void), NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!predicate() && [deadline timeIntervalSinceNow] > 0) {
        NSDate *next = [NSDate dateWithTimeIntervalSinceNow:0.01];
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:next];
    }
    return predicate();
}

static NSData *TLSRequestBody(NSData *httpBody, NSInputStream *stream) {
    if (httpBody.length > 0) {
        return [httpBody copy];
    }
    if (stream == nil) {
        return [NSData data];
    }

    NSMutableData *body = [NSMutableData data];
    uint8_t buffer[16 * 1024];
    [stream open];
    while (stream.streamStatus != NSStreamStatusAtEnd) {
        NSInteger count = [stream read:buffer maxLength:sizeof(buffer)];
        if (count < 0) {
            [stream close];
            return nil;
        }
        if (count == 0) {
            // URLSession supplies a finite request body stream. Treat a zero
            // read as EOF so a malformed stream cannot spin this fixture.
            break;
        }
        [body appendBytes:buffer length:(NSUInteger)count];
    }
    [stream close];
    return body;
}

typedef NS_ENUM(NSInteger, TLSFixtureScenario) {
    TLSFixtureScenarioSuccess = 0,
    TLSFixtureScenarioUnauthorizedDrop,
    TLSFixtureScenarioServerRetry,
    TLSFixtureScenarioTransportTimeoutRetry,
    TLSFixtureScenarioTransportCloseRetry,
    TLSFixtureScenarioPersistentFailure,
    TLSFixtureScenarioPersistentRecovery,
};

/// Thread-safe callback recorder. URLSession/Core callbacks are asynchronous;
/// keeping the count and last result behind a lock makes the fixture's
/// assertions valid on both the command-line and UIKit runners.
@interface TLSResultRecorder : NSObject {
    NSLock *_lock;
    NSUInteger _callbackCount;
    TLSSendResult *_lastResult;
}
- (void)recordResult:(TLSSendResult *)result;
- (NSUInteger)callbackCount;
- (TLSSendResult *)lastResult;
@end

@implementation TLSResultRecorder

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (void)recordResult:(TLSSendResult *)result {
    [_lock lock];
    _callbackCount += 1;
    _lastResult = result;
    [_lock unlock];
}

- (NSUInteger)callbackCount {
    [_lock lock];
    NSUInteger count = _callbackCount;
    [_lock unlock];
    return count;
}

- (TLSSendResult *)lastResult {
    [_lock lock];
    TLSSendResult *result = _lastResult;
    [_lock unlock];
    return result;
}

@end

/// A per-session URLProtocol keeps the smoke test entirely offline. It can
/// return deterministic HTTP/transport faults, while still recording every
/// request body for the wire assertions.
@interface TLSObjectiveCConsumerURLProtocol : NSURLProtocol
+ (void)resetForScenario:(TLSFixtureScenario)scenario;
+ (NSUInteger)requestCount;
+ (NSData *)bodyAtIndex:(NSUInteger)index;
+ (NSString *)headerValue:(NSString *)field atIndex:(NSUInteger)index;
@end

@implementation TLSObjectiveCConsumerURLProtocol

static NSLock *TLSURLProtocolLock(void) {
    static NSLock *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSLock alloc] init];
    });
    return lock;
}

static NSMutableArray<NSData *> *TLSURLProtocolBodies(void) {
    static NSMutableArray<NSData *> *bodies;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bodies = [[NSMutableArray alloc] init];
    });
    return bodies;
}

static NSMutableArray<NSDictionary<NSString *, NSString *> *> *TLSURLProtocolHeaders(void) {
    static NSMutableArray<NSDictionary<NSString *, NSString *> *> *headers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        headers = [[NSMutableArray alloc] init];
    });
    return headers;
}

static TLSFixtureScenario *TLSURLProtocolScenarioStorage(void) {
    static TLSFixtureScenario scenario;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        scenario = TLSFixtureScenarioSuccess;
    });
    return &scenario;
}

static TLSFixtureScenario TLSURLProtocolScenario(void) {
    return *TLSURLProtocolScenarioStorage();
}

static void TLSURLProtocolSetScenario(TLSFixtureScenario scenario) {
    *TLSURLProtocolScenarioStorage() = scenario;
}

+ (void)resetForScenario:(TLSFixtureScenario)scenario {
    [TLSURLProtocolLock() lock];
    [TLSURLProtocolBodies() removeAllObjects];
    [TLSURLProtocolHeaders() removeAllObjects];
    TLSURLProtocolSetScenario(scenario);
    [TLSURLProtocolLock() unlock];
}

+ (NSUInteger)requestCount {
    [TLSURLProtocolLock() lock];
    NSUInteger count = TLSURLProtocolBodies().count;
    [TLSURLProtocolLock() unlock];
    return count;
}

+ (NSData *)bodyAtIndex:(NSUInteger)index {
    [TLSURLProtocolLock() lock];
    NSData *body = index < TLSURLProtocolBodies().count
        ? [TLSURLProtocolBodies()[index] copy]
        : nil;
    [TLSURLProtocolLock() unlock];
    return body;
}

+ (NSString *)headerValue:(NSString *)field atIndex:(NSUInteger)index {
    [TLSURLProtocolLock() lock];
    NSDictionary<NSString *, NSString *> *headers = index < TLSURLProtocolHeaders().count
        ? TLSURLProtocolHeaders()[index]
        : nil;
    NSString *value = nil;
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:field] == NSOrderedSame) {
            value = [headers[key] copy];
            break;
        }
    }
    [TLSURLProtocolLock() unlock];
    return value;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    (void)request;
    // Intercept every request. `startLoading` rejects anything outside the
    // expected local HTTPS endpoint so a malformed SDK URL cannot reach the
    // real network during this offline fixture.
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSURL *URL = self.request.URL;
    if (![URL.scheme.lowercaseString isEqualToString:@"https"] ||
        ![URL.host.lowercaseString isEqualToString:@"objc-consumer.invalid"] ||
        ![URL.path isEqualToString:@"/PutLogs"]) {
        NSError *error = [NSError errorWithDomain:@"TLSObjectiveCConsumerURLProtocol"
                                               code:1
                                           userInfo:@{NSLocalizedDescriptionKey:
                                                          @"unexpected URL escaped the offline consumer fixture"}];
        [self.client URLProtocol:self didFailWithError:error];
        return;
    }
    NSData *body = TLSRequestBody(self.request.HTTPBody, self.request.HTTPBodyStream);
    if (body == nil) {
        NSError *error = [NSError errorWithDomain:@"TLSObjectiveCConsumerURLProtocol"
                                               code:2
                                           userInfo:@{NSLocalizedDescriptionKey:
                                                          @"URLProtocol could not read the SDK request body"}];
        [self.client URLProtocol:self didFailWithError:error];
        return;
    }
    [TLSURLProtocolLock() lock];
    [TLSURLProtocolBodies() addObject:body];
    [TLSURLProtocolHeaders() addObject:self.request.allHTTPHeaderFields ?: @{}];
    NSUInteger requestNumber = TLSURLProtocolBodies().count;
    TLSFixtureScenario scenario = TLSURLProtocolScenario();
    [TLSURLProtocolLock() unlock];

    if ((scenario == TLSFixtureScenarioTransportTimeoutRetry && requestNumber == 1) ||
        (scenario == TLSFixtureScenarioTransportCloseRetry && requestNumber == 1)) {
        NSInteger code = scenario == TLSFixtureScenarioTransportTimeoutRetry
            ? NSURLErrorTimedOut
            : NSURLErrorNetworkConnectionLost;
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain
                                               code:code
                                           userInfo:nil];
        [self.client URLProtocol:self didFailWithError:error];
        return;
    }

    NSInteger statusCode = 200;
    NSString *requestID = @"objc-consumer-request-200";
    NSString *responseJSONString = @"{\"code\":0,\"message\":\"ok\"}";
    switch (scenario) {
        case TLSFixtureScenarioUnauthorizedDrop:
            statusCode = 401;
            requestID = @"objc-consumer-request-401";
            responseJSONString = @"{\"errorCode\":\"AccessDenied\",\"errorMessage\":\"fixture unauthorized\"}";
            break;
        case TLSFixtureScenarioServerRetry:
            if (requestNumber == 1) {
                statusCode = 500;
                requestID = @"objc-consumer-request-500";
                responseJSONString = @"{\"errorCode\":\"InternalError\",\"errorMessage\":\"fixture retry\"}";
            } else {
                requestID = @"objc-consumer-request-500-then-200";
            }
            break;
        case TLSFixtureScenarioPersistentFailure:
            statusCode = 500;
            requestID = @"objc-consumer-request-persistent-500";
            responseJSONString = @"{\"errorCode\":\"InternalError\",\"errorMessage\":\"fixture persistent retry\"}";
            break;
        case TLSFixtureScenarioSuccess:
        case TLSFixtureScenarioTransportTimeoutRetry:
        case TLSFixtureScenarioTransportCloseRetry:
        case TLSFixtureScenarioPersistentRecovery:
            break;
    }

    URL = URL ?: [NSURL URLWithString:@"https://objc-consumer.invalid/PutLogs"];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
        initWithURL:URL
         statusCode:statusCode
        HTTPVersion:@"HTTP/1.1"
       headerFields:@{
           @"Content-Type": @"application/json",
           @"x-tls-requestid": requestID,
       }];
    NSData *responseBody = [responseJSONString
        dataUsingEncoding:NSUTF8StringEncoding];
    [self.client URLProtocol:self
          didReceiveResponse:response
          cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:responseBody];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
}

@end

typedef struct {
    const uint8_t *bytes;
    NSUInteger length;
    NSUInteger offset;
} TLSByteCursor;

static BOOL TLSReadVarint(TLSByteCursor *cursor, uint64_t *value) {
    if (cursor == NULL || value == NULL) {
        return NO;
    }
    uint64_t result = 0;
    for (NSUInteger index = 0; index < 10 && cursor->offset < cursor->length; index++) {
        uint8_t byte = cursor->bytes[cursor->offset++];
        if (index == 9 && (byte & 0xFEu) != 0) {
            return NO;
        }
        result |= ((uint64_t)(byte & 0x7Fu)) << (index * 7);
        if ((byte & 0x80u) == 0) {
            *value = result;
            return YES;
        }
    }
    return NO;
}

static BOOL TLSReadLengthDelimited(TLSByteCursor *cursor,
                                   const uint8_t **bytes,
                                   NSUInteger *length) {
    uint64_t encodedLength = 0;
    if (!TLSReadVarint(cursor, &encodedLength) ||
        encodedLength > (uint64_t)(cursor->length - cursor->offset)) {
        return NO;
    }
    *bytes = cursor->bytes + cursor->offset;
    *length = (NSUInteger)encodedLength;
    cursor->offset += *length;
    return YES;
}

static BOOL TLSSkipField(TLSByteCursor *cursor, uint64_t key) {
    switch ((uint32_t)(key & 7u)) {
        case 0: {
            uint64_t ignored = 0;
            return TLSReadVarint(cursor, &ignored);
        }
        case 1:
            if (cursor->length - cursor->offset < 8) {
                return NO;
            }
            cursor->offset += 8;
            return YES;
        case 2: {
            const uint8_t *ignoredBytes = NULL;
            NSUInteger ignoredLength = 0;
            return TLSReadLengthDelimited(cursor, &ignoredBytes, &ignoredLength);
        }
        case 5:
            if (cursor->length - cursor->offset < 4) {
                return NO;
            }
            cursor->offset += 4;
            return YES;
        default:
            return NO;
    }
}

static BOOL TLSUTF8Equals(const uint8_t *bytes,
                          NSUInteger length,
                          NSString *expected) {
    NSString *actual = [[NSString alloc] initWithBytes:bytes
                                                length:length
                                              encoding:NSUTF8StringEncoding];
    return actual != nil && [actual isEqualToString:expected];
}

/// Verifies the exact uncompressed protobuf envelope emitted by the producer.
/// The check is deliberately small: it proves the external ObjC value model
/// reached the wire without depending on private Core or Bridge headers.
static BOOL TLSValidateLogMessage(const uint8_t *bytes,
                                  NSUInteger length,
                                  int64_t expectedTimestampMilliseconds,
                                  uint32_t expectedNanosecondsRemainder) {
    TLSByteCursor cursor = { bytes, length, 0 };
    BOOL sawTimestamp = NO;
    BOOL sawNanoseconds = NO;
    BOOL sawUnicode = NO;
    BOOL sawEmptyValue = NO;
    uint64_t timestampMilliseconds = 0;
    uint32_t nanosecondsRemainder = 0;

    while (cursor.offset < cursor.length) {
        uint64_t key = 0;
        if (!TLSReadVarint(&cursor, &key) || key == 0) {
            return NO;
        }
        switch (key) {
            case 0x08: {
                if (sawTimestamp || !TLSReadVarint(&cursor, &timestampMilliseconds)) {
                    return NO;
                }
                sawTimestamp = YES;
                break;
            }
            case 0x12: {
                const uint8_t *contentBytes = NULL;
                NSUInteger contentLength = 0;
                if (!TLSReadLengthDelimited(&cursor, &contentBytes, &contentLength)) {
                    return NO;
                }
                TLSByteCursor content = { contentBytes, contentLength, 0 };
                NSString *keyString = nil;
                NSString *valueString = nil;
                while (content.offset < content.length) {
                    uint64_t contentKey = 0;
                    if (!TLSReadVarint(&content, &contentKey)) {
                        return NO;
                    }
                    if (contentKey == 0x0A) {
                        const uint8_t *fieldBytes = NULL;
                        NSUInteger fieldLength = 0;
                        if (!TLSReadLengthDelimited(&content, &fieldBytes, &fieldLength)) {
                            return NO;
                        }
                        keyString = [[NSString alloc] initWithBytes:fieldBytes
                                                              length:fieldLength
                                                            encoding:NSUTF8StringEncoding];
                    } else if (contentKey == 0x12) {
                        const uint8_t *fieldBytes = NULL;
                        NSUInteger fieldLength = 0;
                        if (!TLSReadLengthDelimited(&content, &fieldBytes, &fieldLength)) {
                            return NO;
                        }
                        valueString = [[NSString alloc] initWithBytes:fieldBytes
                                                                length:fieldLength
                                                              encoding:NSUTF8StringEncoding];
                    } else if (!TLSSkipField(&content, contentKey)) {
                        return NO;
                    }
                }
                if ([keyString isEqualToString:@"ключ-🙂"] &&
                    [valueString isEqualToString:@"值-🚀"]) {
                    sawUnicode = YES;
                }
                if ([keyString isEqualToString:@"empty"] &&
                    valueString != nil && valueString.length == 0) {
                    sawEmptyValue = YES;
                }
                break;
            }
            case 0x1D:
                if (sawNanoseconds || cursor.length - cursor.offset < 4) {
                    return NO;
                }
                nanosecondsRemainder = (uint32_t)cursor.bytes[cursor.offset] |
                    ((uint32_t)cursor.bytes[cursor.offset + 1] << 8) |
                    ((uint32_t)cursor.bytes[cursor.offset + 2] << 16) |
                    ((uint32_t)cursor.bytes[cursor.offset + 3] << 24);
                cursor.offset += 4;
                sawNanoseconds = YES;
                break;
            default:
                if (!TLSSkipField(&cursor, key)) {
                    return NO;
                }
                break;
        }
    }
    return sawTimestamp && timestampMilliseconds == (uint64_t)expectedTimestampMilliseconds &&
           sawNanoseconds && nanosecondsRemainder == expectedNanosecondsRemainder &&
           nanosecondsRemainder < 1000000 && sawUnicode && sawEmptyValue;
}

static BOOL TLSValidateRequestBody(NSData *body,
                                   int64_t expectedTimestampMilliseconds,
                                   uint32_t expectedNanosecondsRemainder) {
    if (body.length == 0) {
        return NO;
    }
    TLSByteCursor outer = { body.bytes, body.length, 0 };
    uint64_t key = 0;
    uint64_t groupLength = 0;
    if (!TLSReadVarint(&outer, &key) || key != 0x0A ||
        !TLSReadVarint(&outer, &groupLength) ||
        groupLength > (uint64_t)(outer.length - outer.offset)) {
        return NO;
    }

    TLSByteCursor group = {
        outer.bytes + outer.offset,
        (NSUInteger)groupLength,
        0,
    };
    outer.offset += group.length;
    BOOL sawLog = NO;
    while (group.offset < group.length) {
        uint64_t fieldKey = 0;
        if (!TLSReadVarint(&group, &fieldKey)) {
            return NO;
        }
        if (fieldKey == 0x0A) {
            const uint8_t *logBytes = NULL;
            NSUInteger logLength = 0;
            if (sawLog || !TLSReadLengthDelimited(&group, &logBytes, &logLength) ||
                !TLSValidateLogMessage(logBytes,
                                       logLength,
                                       expectedTimestampMilliseconds,
                                       expectedNanosecondsRemainder)) {
                return NO;
            }
            sawLog = YES;
        } else if (!TLSSkipField(&group, fieldKey)) {
            return NO;
        }
    }
    return sawLog && outer.offset == outer.length;
}

static void TLSRequireProducerHeadersForAllRequests(NSString *caseName) {
    NSUInteger requestCount = [TLSObjectiveCConsumerURLProtocol requestCount];
    for (NSUInteger index = 0; index < requestCount; index++) {
        NSString *userAgent = [TLSObjectiveCConsumerURLProtocol
            headerValue:@"User-Agent" atIndex:index];
        TLSRequire([userAgent isEqualToString:TLSExpectedProducerUserAgent],
                   [NSString stringWithFormat:
                       @"%@ request %lu User-Agent mismatch: expected %@, got %@",
                       caseName,
                       (unsigned long)(index + 1),
                       TLSExpectedProducerUserAgent,
                       userAgent]);
        NSString *apiVersion = [TLSObjectiveCConsumerURLProtocol
            headerValue:@"x-tls-apiversion" atIndex:index];
        TLSRequire([apiVersion isEqualToString:TLSExpectedAPIVersion],
                   [NSString stringWithFormat:
                       @"%@ request %lu x-tls-apiversion mismatch: expected %@, got %@",
                       caseName,
                       (unsigned long)(index + 1),
                       TLSExpectedAPIVersion,
                       apiVersion]);
    }
}

static TLSProducerConfiguration *TLSMakeConfiguration(void) {
    TLSProducerConfiguration *configuration = [[TLSProducerConfiguration alloc] init];
    TLSDestination *destination = [[TLSDestination alloc]
        initWithEndpoint:@"https://objc-consumer.invalid"
                 region:@"cn-beijing"
              projectID:@"objc-project"
               topicID:@"objc-topic"];
    configuration.destination = destination;
    configuration.batchMaxLogCount = 16;
    configuration.batchMaxRawBytes = 1024 * 1024;
    configuration.batchLinger = 60.0;
    configuration.bufferMaxBytes = 4 * 1024 * 1024;
    configuration.bufferFullPolicy = TLSBufferFullPolicyReject;
    configuration.bufferBlockTimeout = 1.0;
    configuration.sendConcurrency = 1;
    configuration.compression = TLSCompressionDisabled;
    configuration.persistence = TLSPersistenceDisabled;
    configuration.connectTimeout = 2.0;
    configuration.requestTimeout = 3.0;
    configuration.metadataSource = @"";
    configuration.metadataFileName = nil;
    configuration.metadataTags = @{};
    configuration.maxLogAge = 7.0 * 24.0 * 60.0 * 60.0;
    configuration.expiredLogPolicy = TLSExpiredLogPolicyRewriteTimestamp;
    configuration.unauthorizedPolicy = TLSUnauthorizedPolicyRetain;
    // Keep all fixture state on the main queue. The run loop below services
    // these callbacks, avoiding a cross-queue data race in this tiny program.
    configuration.callbackQueue = dispatch_get_main_queue();
    NSURLSessionConfiguration *sessionConfiguration =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    sessionConfiguration.protocolClasses = @[TLSObjectiveCConsumerURLProtocol.class];
    configuration.urlSessionConfiguration = sessionConfiguration;
    configuration.automaticLifecycleHandling = NO;
    configuration.producerID = nil;
    return configuration;
}

static TLSProducerConfiguration *TLSMakeFaultConfiguration(
    TLSPersistence persistence,
    TLSUnauthorizedPolicy unauthorizedPolicy,
    NSString *producerID) {
    TLSProducerConfiguration *configuration = TLSMakeConfiguration();
    configuration.batchMaxLogCount = 1;
    configuration.batchLinger = 0.05;
    configuration.persistence = persistence;
    configuration.unauthorizedPolicy = unauthorizedPolicy;
    configuration.producerID = producerID;
    // Fault cases should finish quickly while preserving the Core's bounded
    // retry policy. These values are whole milliseconds as required by the
    // public configuration contract.
    configuration.connectTimeout = 0.5;
    configuration.requestTimeout = 0.5;
    return configuration;
}

static TLSCredentials *TLSMakeCredentials(void) {
    // Fixture-only placeholders. They are never printed or sent to a real
    // network because the endpoint is intercepted by URLProtocol.
    return [[TLSCredentials alloc] initWithAccessKeyID:@"fixture-ak"
                                      accessKeySecret:@"fixture-sk"
                                       securityToken:nil];
}

static TLSLogEvent *TLSMakeEvent(int64_t *expectedTimestampMilliseconds,
                                 uint32_t *expectedNanosecondsRemainder,
                                 NSString *marker) {
    NSTimeInterval timestampSeconds =
        floor([[NSDate date] timeIntervalSince1970]) + 0.123456;
    NSTimeInterval timestampMilliseconds = timestampSeconds * 1000.0;
    int64_t encodedMilliseconds = (int64_t)timestampMilliseconds;
    int64_t encodedNanoseconds = llround(
        (timestampMilliseconds - (NSTimeInterval)encodedMilliseconds) * 1000000.0);
    if (encodedNanoseconds >= 1000000) {
        encodedMilliseconds += 1;
        encodedNanoseconds = 0;
    }
    *expectedTimestampMilliseconds = encodedMilliseconds;
    *expectedNanosecondsRemainder = (uint32_t)encodedNanoseconds;
    NSDate *timestamp = [NSDate dateWithTimeIntervalSince1970:timestampSeconds];
    return [[TLSLogEvent alloc]
        initWithTimestamp:timestamp
                 hashKey:nil
                 contents:@{
                     @"ключ-🙂": @"值-🚀",
                     @"empty": @"",
                     @"fixture_case": marker,
                 }];
}

static TLSLogEvent *TLSMakeMarkedEvent(NSString *marker) {
    return [[TLSLogEvent alloc]
        initWithTimestamp:[NSDate date]
                  hashKey:nil
                 contents:@{
                     @"fixture_case": marker,
                     @"value": @"fixture",
                 }];
}

static NSString *TLSUniqueProducerID(NSString *marker) {
    NSString *uuid = [[[NSUUID UUID] UUIDString]
        stringByReplacingOccurrencesOfString:@"-" withString:@""];
    return [NSString stringWithFormat:@"objc-%@-%@", marker, uuid];
}

static TLSProducer *TLSOpenProducer(
    TLSProducerConfiguration *configuration,
    TLSCredentials *credentials,
    TLSResultRecorder *recorder,
    NSError **errorOut) {
    __block TLSProducer *producer = nil;
    __block NSError *openError = nil;
    __block BOOL openCompleted = NO;
    [TLSProducer openWithConfiguration:configuration
                               credentials:credentials
                              onSendResult:^(TLSSendResult *result) {
        [recorder recordResult:result];
    }
                                  completion:^(TLSProducer *opened, NSError *error) {
        producer = opened;
        openError = error;
        openCompleted = YES;
    }];
    TLSRequire(TLSRunLoopWait(^BOOL { return openCompleted; }, 10.0),
               @"open completion did not arrive");
    if (producer == nil && openError != nil) {
        NSString *code = openError.userInfo[[TLSProducer errorCodeKey]];
        fprintf(stderr, "OPEN ERROR domain=%s code=%ld kind=%s\n",
                openError.domain.UTF8String ?: "",
                (long)openError.code,
                code.UTF8String ?: "");
    }
    if (errorOut != NULL) {
        *errorOut = openError;
    }
    return producer;
}

static TLSProducer *TLSOpenProducerRetryingPersistenceLease(
    TLSProducerConfiguration *configuration,
    TLSCredentials *credentials,
    TLSResultRecorder *recorder,
    NSTimeInterval timeout,
    NSError **errorOut) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    NSError *lastError = nil;
    for (;;) {
        TLSProducer *producer = TLSOpenProducer(
            configuration, credentials, recorder, &lastError);
        if (producer != nil) {
            if (errorOut != NULL) {
                *errorOut = nil;
            }
            return producer;
        }
        NSString *errorCode = lastError.userInfo[[TLSProducer errorCodeKey]];
        if (![errorCode isEqualToString:@"persistence"] ||
            [deadline timeIntervalSinceNow] <= 0) {
            break;
        }
        NSDate *next = [NSDate dateWithTimeIntervalSinceNow:0.05];
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:next];
    }
    if (errorOut != NULL) {
        *errorOut = lastError;
    }
    return nil;
}

static NSError *TLSCloseProducer(TLSProducer *producer, NSTimeInterval timeout) {
    __block NSError *closeError = nil;
    __block BOOL closeCompleted = NO;
    [producer closeWithTimeout:timeout completion:^(NSError *error) {
        closeError = error;
        closeCompleted = YES;
    }];
    TLSRequire(TLSRunLoopWait(^BOOL { return closeCompleted; }, timeout + 5.0),
               @"close completion did not arrive");
    return closeError;
}

static void TLSPumpRunLoop(NSTimeInterval duration) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:duration];
    while ([deadline timeIntervalSinceNow] > 0) {
        NSDate *next = [NSDate dateWithTimeIntervalSinceNow:0.01];
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:next];
    }
}

static BOOL TLSResultHasErrorCode(TLSSendResult *result, NSString *expectedCode) {
    return result.error != nil &&
        [result.error.domain isEqualToString:[TLSProducer errorDomain]] &&
        [result.error.userInfo[[TLSProducer errorCodeKey]]
            isEqualToString:expectedCode];
}

static void TLSPrintCasePass(NSString *name,
                             NSUInteger callbackCount,
                             NSUInteger requestCount) {
    printf("CASE PASS [%s] callback_count=%lu request_count=%lu\n",
           name.UTF8String,
           (unsigned long)callbackCount,
           (unsigned long)requestCount);
}

static NSDictionary *TLSCaseDictionary(NSString *name,
                                        NSUInteger callbackCount,
                                        NSUInteger requestCount) {
    return @{
        @"name": name,
        @"passed": @YES,
        @"callback_count": @(callbackCount),
        @"request_count": @(requestCount),
    };
}

static NSDictionary *TLSRunWireAndLifecycleCase(void) {
    NSString *caseName = @"wire-success-lifecycle";
    [TLSObjectiveCConsumerURLProtocol resetForScenario:TLSFixtureScenarioSuccess];
    TLSResultRecorder *recorder = [[TLSResultRecorder alloc] init];
    TLSCredentials *credentials = TLSMakeCredentials();
    TLSProducerConfiguration *configuration = TLSMakeConfiguration();
    NSError *openError = nil;
    TLSProducer *producer = TLSOpenProducer(
        configuration, credentials, recorder, &openError);
    TLSRequire(producer != nil && openError == nil,
               @"valid Objective-C open failed");

    int64_t expectedTimestampMilliseconds = 0;
    uint32_t expectedNanosecondsRemainder = 0;
    TLSLogEvent *event = TLSMakeEvent(
        &expectedTimestampMilliseconds,
        &expectedNanosecondsRemainder,
        caseName);
    NSError *addError = nil;
    BOOL added = [producer addLog:event mode:TLSAddModeImmediate error:&addError];
    TLSRequire(added && addError == nil, @"addLog failed for valid event");
    TLSRequire(TLSRunLoopWait(^BOOL {
        return [recorder callbackCount] >= 1 &&
            [TLSObjectiveCConsumerURLProtocol requestCount] >= 1;
    }, 10.0), @"send result or URLProtocol request did not arrive");
    TLSRequire([recorder callbackCount] == 1 && recorder.lastResult != nil,
               @"send callback count/result contract failed");
    TLSSendResult *result = recorder.lastResult;
    TLSRequire(result.status == TLSSendResultStatusSuccess && result.error == nil,
               @"successful URLProtocol response did not map to a success result");
    TLSRequire([result.requestID isEqualToString:@"objc-consumer-request-200"],
               @"TLSSendResult.requestID did not preserve the service request ID");
    NSData *requestBody = [TLSObjectiveCConsumerURLProtocol bodyAtIndex:0];
    TLSRequire(TLSValidateRequestBody(requestBody,
                                      expectedTimestampMilliseconds,
                                      expectedNanosecondsRemainder),
               @"wire body lost UTF-8, empty value, or nanosecond timestamp");
    TLSRequireProducerHeadersForAllRequests(caseName);

    NSError *updateError = nil;
    TLSCredentials *updatedCredentials = [[TLSCredentials alloc]
        initWithAccessKeyID:@"fixture-ak-updated"
            accessKeySecret:@"fixture-sk-updated"
             securityToken:@"fixture-token-updated"];
    BOOL credentialsUpdated = [producer updateCredentials:updatedCredentials
                                                     error:&updateError];
    TLSRequire(credentialsUpdated && updateError == nil,
               @"updateCredentials returned an NSError");

    updateError = nil;
    TLSDestination *updatedDestination = [[TLSDestination alloc]
        initWithEndpoint:@"https://objc-consumer.invalid"
                 region:@"cn-shanghai"
              projectID:@"objc-project-updated"
               topicID:@"objc-topic-updated"];
    BOOL destinationUpdated = [producer updateDestination:updatedDestination
                                                     error:&updateError];
    TLSRequire(destinationUpdated && updateError == nil,
               @"updateDestination returned an NSError");

    NSError *invalidModeError = nil;
    BOOL invalidModeAccepted = [producer addLog:event
                                            mode:(TLSAddMode)99
                                           error:&invalidModeError];
    TLSRequire(!invalidModeAccepted && invalidModeError != nil &&
                   [invalidModeError.userInfo[[TLSProducer errorCodeKey]]
                       isEqualToString:@"configuration"],
               @"invalid Objective-C enum mode was unexpectedly accepted");

    TLSProducerConfiguration *invalidConfiguration =
        [[TLSProducerConfiguration alloc] init];
    invalidConfiguration.compression = (TLSCompression)99;
    invalidConfiguration.callbackQueue = dispatch_get_main_queue();
    __block BOOL invalidCompleted = NO;
    __block TLSProducer *invalidProducer = nil;
    __block NSError *invalidError = nil;
    [TLSProducer openWithConfiguration:invalidConfiguration
                               credentials:credentials
                                  completion:^(TLSProducer *opened, NSError *error) {
        invalidProducer = opened;
        invalidError = error;
        invalidCompleted = YES;
    }];
    TLSRequire(TLSRunLoopWait(^BOOL { return invalidCompleted; }, 5.0),
               @"invalid configuration completion did not arrive");
    TLSRequire(invalidProducer == nil && invalidError != nil,
               @"invalid configuration unexpectedly opened");
    TLSRequire([invalidError.domain isEqualToString:[TLSProducer errorDomain]],
               @"invalid configuration NSError domain is unstable");
    NSString *errorCodeKey = [TLSProducer errorCodeKey];
    TLSRequire(errorCodeKey.length > 0 && invalidError.userInfo[errorCodeKey] != nil,
               @"invalid configuration NSError lacks stable error code key");

    // The facade maps invalid timeout asynchronously and leaves the producer
    // ready. A valid close immediately afterwards proves no close mutation
    // happened before the timeout was accepted by the public boundary.
    __block BOOL invalidCloseCompleted = NO;
    __block NSError *invalidCloseError = nil;
    [producer closeWithTimeout:-1 completion:^(NSError *error) {
        invalidCloseError = error;
        invalidCloseCompleted = YES;
    }];
    TLSRequire(TLSRunLoopWait(^BOOL { return invalidCloseCompleted; }, 5.0),
               @"invalid close timeout completion did not arrive");
    TLSRequire(invalidCloseError != nil &&
                   [invalidCloseError.userInfo[[TLSProducer errorCodeKey]]
                       isEqualToString:@"configuration"],
               @"invalid close timeout did not map to configuration error");

    __block BOOL closeCompleted = NO;
    __block NSError *closeError = nil;
    [producer closeWithTimeout:5.0 completion:^(NSError *error) {
        closeError = error;
        closeCompleted = YES;
    }];
    TLSRequire(TLSRunLoopWait(^BOOL { return closeCompleted; }, 10.0),
               @"close completion did not arrive");
    TLSRequire(closeError == nil, @"close returned an NSError");

    NSError *closedAddError = nil;
    BOOL acceptedAfterClose = [producer addLog:event
                                            mode:TLSAddModeNormal
                                           error:&closedAddError];
    TLSRequire(!acceptedAfterClose && closedAddError != nil,
               @"addLog after close was unexpectedly accepted");

    NSUInteger requests = [TLSObjectiveCConsumerURLProtocol requestCount];
    NSUInteger callbacks = [recorder callbackCount];
    TLSPrintCasePass(caseName, callbacks, requests);
    return TLSCaseDictionary(caseName, callbacks, requests);
}

static NSDictionary *TLSRunUnauthorizedDropCase(void) {
    NSString *caseName = @"http401-unauthorized-drop";
    [TLSObjectiveCConsumerURLProtocol
        resetForScenario:TLSFixtureScenarioUnauthorizedDrop];
    TLSResultRecorder *recorder = [[TLSResultRecorder alloc] init];
    TLSCredentials *credentials = TLSMakeCredentials();
    NSString *producerID = TLSUniqueProducerID(@"auth");
    TLSProducerConfiguration *configuration = TLSMakeFaultConfiguration(
        TLSPersistenceBuffered, TLSUnauthorizedPolicyDrop, producerID);
    NSError *openError = nil;
    TLSProducer *producer = TLSOpenProducer(
        configuration, credentials, recorder, &openError);
    TLSRequire(producer != nil && openError == nil,
               @"401 drop producer failed to open");

    NSError *addError = nil;
    BOOL added = [producer addLog:TLSMakeMarkedEvent(caseName)
                              mode:TLSAddModeImmediate
                             error:&addError];
    TLSRequire(added && addError == nil, @"401 drop addLog failed");
    TLSRequire(TLSRunLoopWait(^BOOL {
        return [recorder callbackCount] >= 1 &&
            [TLSObjectiveCConsumerURLProtocol requestCount] >= 1;
    }, 10.0), @"401 drop callback did not arrive");
    TLSRequire([recorder callbackCount] == 1 &&
                   [TLSObjectiveCConsumerURLProtocol requestCount] == 1,
               @"401 drop unexpectedly retried or duplicated callback");
    TLSSendResult *result = recorder.lastResult;
    TLSRequire(result.status == TLSSendResultStatusFailure &&
                   TLSResultHasErrorCode(result, @"auth") &&
                   result.error.code == TLSProducerErrorCodeAuth,
               @"401 drop did not expose structured auth NSError");
    TLSRequire([result.requestID isEqualToString:@"objc-consumer-request-401"],
               @"401 drop did not preserve request ID");
    TLSPumpRunLoop(0.2);
    TLSRequire([TLSObjectiveCConsumerURLProtocol requestCount] == 1,
               @"401 drop left a retained retry request");
    TLSRequireProducerHeadersForAllRequests(caseName);

    NSError *closeError = TLSCloseProducer(producer, 5.0);
    TLSRequire(closeError == nil, @"401 drop close returned an NSError");
    NSUInteger requests = [TLSObjectiveCConsumerURLProtocol requestCount];
    NSUInteger callbacks = [recorder callbackCount];
    TLSPrintCasePass(caseName, callbacks, requests);
    return TLSCaseDictionary(caseName, callbacks, requests);
}

static NSDictionary *TLSRunServerRetryCase(void) {
    NSString *caseName = @"http500-then-200-retry";
    [TLSObjectiveCConsumerURLProtocol
        resetForScenario:TLSFixtureScenarioServerRetry];
    TLSResultRecorder *recorder = [[TLSResultRecorder alloc] init];
    TLSProducerConfiguration *configuration = TLSMakeFaultConfiguration(
        TLSPersistenceDisabled, TLSUnauthorizedPolicyRetain, nil);
    NSError *openError = nil;
    TLSProducer *producer = TLSOpenProducer(
        configuration, TLSMakeCredentials(), recorder, &openError);
    TLSRequire(producer != nil && openError == nil,
               @"500 retry producer failed to open");
    NSError *addError = nil;
    BOOL added = [producer addLog:TLSMakeMarkedEvent(caseName)
                              mode:TLSAddModeImmediate
                             error:&addError];
    TLSRequire(added && addError == nil, @"500 retry addLog failed");
    TLSRequire(TLSRunLoopWait(^BOOL {
        return [recorder callbackCount] >= 1 &&
            [TLSObjectiveCConsumerURLProtocol requestCount] >= 2;
    }, 10.0), @"500 retry did not reach terminal callback");
    TLSRequire([recorder callbackCount] == 1 &&
                   [TLSObjectiveCConsumerURLProtocol requestCount] == 2,
               @"500 retry did not produce exactly one retry attempt");
    TLSSendResult *result = recorder.lastResult;
    TLSRequire(result.status == TLSSendResultStatusSuccess && result.error == nil &&
                   [result.requestID isEqualToString:
                       @"objc-consumer-request-500-then-200"],
               @"500 then 200 did not map to one terminal success");
    TLSRequireProducerHeadersForAllRequests(caseName);
    NSError *closeError = TLSCloseProducer(producer, 5.0);
    TLSRequire(closeError == nil, @"500 retry close returned an NSError");
    NSUInteger requests = [TLSObjectiveCConsumerURLProtocol requestCount];
    NSUInteger callbacks = [recorder callbackCount];
    TLSPrintCasePass(caseName, callbacks, requests);
    return TLSCaseDictionary(caseName, callbacks, requests);
}

static NSDictionary *TLSRunTransportRetryCase(TLSFixtureScenario scenario,
                                               NSString *caseName) {
    [TLSObjectiveCConsumerURLProtocol resetForScenario:scenario];
    TLSResultRecorder *recorder = [[TLSResultRecorder alloc] init];
    TLSProducerConfiguration *configuration = TLSMakeFaultConfiguration(
        TLSPersistenceDisabled, TLSUnauthorizedPolicyRetain, nil);
    NSError *openError = nil;
    TLSProducer *producer = TLSOpenProducer(
        configuration, TLSMakeCredentials(), recorder, &openError);
    TLSRequire(producer != nil && openError == nil,
               [NSString stringWithFormat:@"%@ producer failed to open", caseName]);
    NSError *addError = nil;
    BOOL added = [producer addLog:TLSMakeMarkedEvent(caseName)
                              mode:TLSAddModeImmediate
                             error:&addError];
    TLSRequire(added && addError == nil,
               [NSString stringWithFormat:@"%@ addLog failed", caseName]);
    TLSRequire(TLSRunLoopWait(^BOOL {
        return [recorder callbackCount] >= 1 &&
            [TLSObjectiveCConsumerURLProtocol requestCount] >= 2;
    }, 10.0),
               [NSString stringWithFormat:@"%@ did not reach terminal callback", caseName]);
    TLSRequire([recorder callbackCount] == 1 &&
                   [TLSObjectiveCConsumerURLProtocol requestCount] == 2,
               [NSString stringWithFormat:@"%@ did not retry exactly once", caseName]);
    TLSSendResult *result = recorder.lastResult;
    TLSRequire(result.status == TLSSendResultStatusSuccess && result.error == nil,
               [NSString stringWithFormat:@"%@ fault did not recover to success", caseName]);
    TLSRequireProducerHeadersForAllRequests(caseName);
    NSError *closeError = TLSCloseProducer(producer, 5.0);
    TLSRequire(closeError == nil,
               [NSString stringWithFormat:@"%@ close returned an NSError", caseName]);
    NSUInteger requests = [TLSObjectiveCConsumerURLProtocol requestCount];
    NSUInteger callbacks = [recorder callbackCount];
    TLSPrintCasePass(caseName, callbacks, requests);
    return TLSCaseDictionary(caseName, callbacks, requests);
}

static NSDictionary *TLSRunPersistentRecoveryCase(void) {
    NSString *caseName = @"buffered-close-reopen-recovery";
    NSString *producerID = TLSUniqueProducerID(@"recovery");
    [TLSObjectiveCConsumerURLProtocol
        resetForScenario:TLSFixtureScenarioPersistentFailure];
    TLSResultRecorder *firstRecorder = [[TLSResultRecorder alloc] init];
    TLSProducerConfiguration *firstConfiguration = TLSMakeFaultConfiguration(
        TLSPersistenceBuffered, TLSUnauthorizedPolicyRetain, producerID);
    NSError *openError = nil;
    TLSProducer *firstProducer = TLSOpenProducer(
        firstConfiguration, TLSMakeCredentials(), firstRecorder, &openError);
    TLSRequire(firstProducer != nil && openError == nil,
               @"buffered recovery first producer failed to open");

    NSError *addError = nil;
    BOOL added = [firstProducer addLog:TLSMakeMarkedEvent(caseName)
                                  mode:TLSAddModeImmediate
                                 error:&addError];
    TLSRequire(added && addError == nil,
               @"buffered recovery addLog failed");
    TLSRequire(TLSRunLoopWait(^BOOL {
        return [TLSObjectiveCConsumerURLProtocol requestCount] >= 1;
    }, 10.0), @"buffered recovery fault request did not arrive");
    NSUInteger firstRequestCount = [TLSObjectiveCConsumerURLProtocol requestCount];
    TLSRequireProducerHeadersForAllRequests(caseName);

    // A retryable 500 may remain durable through local close. Public close
    // success only proves local shutdown; it does not promise delivery.
    NSError *closeError = TLSCloseProducer(firstProducer, 5.0);
    TLSRequire(closeError == nil,
               @"buffered recovery close failed; no delivery conclusion is made");
    firstProducer = nil;
    TLSPumpRunLoop(0.2);
    TLSRequire([firstRecorder callbackCount] == 0,
               @"buffered retry unexpectedly emitted a terminal callback before recovery");

    [TLSObjectiveCConsumerURLProtocol
        resetForScenario:TLSFixtureScenarioPersistentRecovery];
    TLSResultRecorder *secondRecorder = [[TLSResultRecorder alloc] init];
    TLSProducerConfiguration *secondConfiguration = TLSMakeFaultConfiguration(
        TLSPersistenceBuffered, TLSUnauthorizedPolicyRetain, producerID);
    NSError *reopenError = nil;
    TLSProducer *secondProducer = TLSOpenProducerRetryingPersistenceLease(
        secondConfiguration,
        TLSMakeCredentials(),
        secondRecorder,
        3.0,
        &reopenError);
    TLSRequire(secondProducer != nil && reopenError == nil,
               @"buffered recovery reopen failed");
    TLSRequire(TLSRunLoopWait(^BOOL {
        return [secondRecorder callbackCount] >= 1 &&
            [TLSObjectiveCConsumerURLProtocol requestCount] >= 1;
    }, 10.0), @"buffered recovery callback did not arrive");
    TLSRequire([secondRecorder callbackCount] == 1 &&
                   [TLSObjectiveCConsumerURLProtocol requestCount] == 1,
               @"buffered recovery did not send one recovered batch");
    TLSSendResult *result = secondRecorder.lastResult;
    TLSRequire(result.status == TLSSendResultStatusSuccess && result.error == nil,
               @"buffered recovery did not map to success");
    NSError *secondCloseError = TLSCloseProducer(secondProducer, 5.0);
    TLSRequire(secondCloseError == nil,
               @"buffered recovery second close returned an NSError");

    NSUInteger recoveryRequestCount = [TLSObjectiveCConsumerURLProtocol requestCount];
    TLSRequireProducerHeadersForAllRequests(caseName);
    NSUInteger callbacks = [firstRecorder callbackCount] +
        [secondRecorder callbackCount];
    NSUInteger requests = firstRequestCount + recoveryRequestCount;
    TLSPrintCasePass(caseName, callbacks, requests);
    return TLSCaseDictionary(caseName, callbacks, requests);
}

#if !TARGET_OS_OSX
static NSString *TLSISO8601String(NSDate *date) {
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
        NSISO8601DateFormatWithFractionalSeconds;
    return [formatter stringFromDate:date];
}

static void TLSWriteIOSResult(NSArray<NSDictionary *> *cases,
                              NSString *runID,
                              NSDate *startedAt,
                              NSDate *finishedAt) {
    NSURL *documentsURL = [[[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory
              inDomains:NSUserDomainMask] firstObject];
    TLSRequire(documentsURL != nil, @"iOS Documents directory is unavailable");
    NSDictionary *payload = @{
        @"passed": @YES,
        @"run_id": runID,
        @"started_at": TLSISO8601String(startedAt),
        @"finished_at": TLSISO8601String(finishedAt),
        @"cases": cases,
    };
    NSError *serializationError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                     options:NSJSONWritingPrettyPrinted
                                                       error:&serializationError];
    TLSRequire(data != nil && serializationError == nil,
               @"iOS result JSON serialization failed");
    NSURL *resultURL = [documentsURL URLByAppendingPathComponent:
        @"objective-c-result.json"];
    NSError *writeError = nil;
    BOOL written = [data writeToURL:resultURL options:NSDataWritingAtomic error:&writeError];
    TLSRequire(written && writeError == nil,
               @"iOS result JSON write failed");
    printf("Objective-C result JSON: %s\n", resultURL.path.UTF8String);
}
#endif

static int TLSRunAllCases(void) {
    NSString *runID = [[NSUUID UUID] UUIDString];
    NSDate *startedAt = [NSDate date];
    NSMutableArray<NSDictionary *> *cases = [NSMutableArray array];
    [cases addObject:TLSRunWireAndLifecycleCase()];
    [cases addObject:TLSRunUnauthorizedDropCase()];
    [cases addObject:TLSRunServerRetryCase()];
    [cases addObject:TLSRunTransportRetryCase(
        TLSFixtureScenarioTransportTimeoutRetry,
        @"transport-timeout-retry")];
    [cases addObject:TLSRunTransportRetryCase(
        TLSFixtureScenarioTransportCloseRetry,
        @"transport-close-retry")];
    [cases addObject:TLSRunPersistentRecoveryCase()];

    NSUInteger totalRequests = 0;
    NSUInteger totalCallbacks = 0;
    for (NSDictionary *caseResult in cases) {
        totalRequests += [caseResult[@"request_count"] unsignedIntegerValue];
        totalCallbacks += [caseResult[@"callback_count"] unsignedIntegerValue];
    }
    NSDate *finishedAt = [NSDate date];
#if !TARGET_OS_OSX
    TLSWriteIOSResult(cases, runID, startedAt, finishedAt);
#endif
    fflush(stdout);
    printf("Objective-C consumer PASS (cases=%lu, requests=%lu, callbacks=%lu)\n",
           (unsigned long)cases.count,
           (unsigned long)totalRequests,
           (unsigned long)totalCallbacks);
    fflush(stdout);
    return EXIT_SUCCESS;
}

#if TARGET_OS_OSX
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        (void)argc;
        (void)argv;
        return TLSRunAllCases();
    }
}
#else
@interface TLSFixtureAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation TLSFixtureAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;
    // Use a run-loop timer, not a main dispatch-queue block: the fixture pumps
    // the run loop while waiting for main-queue SDK callbacks. libdispatch
    // deliberately does not reenter a main-queue block from that nested loop.
    [self performSelector:@selector(runFixture) withObject:nil afterDelay:0.0];
    return YES;
}

- (void)runFixture {
    @autoreleasepool {
        (void)TLSRunAllCases();
    }
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc,
                                  argv,
                                  nil,
                                  NSStringFromClass([TLSFixtureAppDelegate class]));
    }
}
#endif
