//
// EntryBenchmarkObjCEntry.m
// Objective-C entry: direct TLSProducer facade calls.
//

#import "EntryBenchmarkObjCEntry.h"
#import "EntryBenchmarkMetrics.h"
#import "EntryBenchmarkProtocol.h"

@import VolcengineTLSProducer;

@interface EBObjCEntry ()

@property(nonatomic, strong) EBBenchmarkPayload *payload;
@property(nonatomic, strong) EBBenchmarkOptions *options;
@property(nonatomic, strong, nullable) TLSProducer *producer;
@property(nonatomic, strong) TLSLogEvent *event;

@end

@implementation EBObjCEntry

- (instancetype)initWithPayload:(EBBenchmarkPayload *)payload
                         options:(EBBenchmarkOptions *)options {
    self = [super init];
    if (!self) {
        return nil;
    }
    _payload = payload;
    _options = options;
    _event = [[TLSLogEvent alloc] initWithTimestamp:payload.timestamp
                                            hashKey:nil
                                           contents:payload.fields];
    return self;
}

- (TLSProducerConfiguration *)configuration {
    TLSProducerConfiguration *configuration = [[TLSProducerConfiguration alloc] init];
    configuration.destination = [[TLSDestination alloc]
        initWithEndpoint:@"https://entry-benchmark.invalid"
                 region:@"cn-beijing"
              projectID:@"entry-benchmark-project"
               topicID:@"entry-benchmark-topic"];
    configuration.batchMaxLogCount = (NSInteger)self.options.batchMaxLogCount;
    configuration.batchMaxRawBytes = (NSInteger)self.options.batchMaxRawBytes;
    configuration.batchLinger = self.options.batchLinger;
    configuration.bufferMaxBytes = (NSInteger)self.options.bufferMaxBytes;
    configuration.bufferFullPolicy = TLSBufferFullPolicyReject;
    configuration.bufferBlockTimeout = self.options.bufferBlockTimeout;
    configuration.sendConcurrency = (NSInteger)self.options.sendConcurrency;
    configuration.compression = TLSCompressionLz4;
    configuration.persistence = [self.options.persistence isEqualToString:@"buffered"]
        ? TLSPersistenceBuffered
        : TLSPersistenceMemory;
    configuration.connectTimeout = self.options.connectTimeout;
    configuration.requestTimeout = self.options.requestTimeout;
    configuration.metadataSource = @"entry-benchmark";
    configuration.metadataFileName = nil;
    configuration.metadataTags = @{};
    configuration.maxLogAge = 7.0 * 24.0 * 60.0 * 60.0;
    configuration.expiredLogPolicy = TLSExpiredLogPolicyRewriteTimestamp;
    configuration.unauthorizedPolicy = TLSUnauthorizedPolicyRetain;
    configuration.callbackQueue = self.options.callbackQueue;
    NSURLSessionConfiguration *sessionConfiguration =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    sessionConfiguration.protocolClasses = @[EBImmediateURLProtocol.class];
    configuration.urlSessionConfiguration = sessionConfiguration;
    configuration.automaticLifecycleHandling = NO;
    configuration.producerID = [self.options.persistence isEqualToString:@"buffered"]
        ? [NSString stringWithFormat:@"entry-benchmark-objc-%@", self.options.runID]
        : nil;
    return configuration;
}

- (TLSCredentials *)credentials {
    // Fixture placeholders never reach the network: the per-session protocol
    // above handles the local HTTPS endpoint and returns 200.
    return [[TLSCredentials alloc] initWithAccessKeyID:@"entry-benchmark-ak"
                                      accessKeySecret:@"entry-benchmark-sk"
                                       securityToken:nil];
}

- (void)startOpeningWithCompletion:(EBEntryCompletion)completion {
    TLSProducerConfiguration *configuration = [self configuration];
    TLSCredentials *credentials = [self credentials];
    __weak EBObjCEntry *weakSelf = self;
    [TLSProducer openWithConfiguration:configuration
                           credentials:credentials
                          onSendResult:^(TLSSendResult *result) {
        EBObjCEntry *strongSelf = weakSelf;
        EBTerminalResultHandler handler = strongSelf.terminalResultHandler;
        if (handler) {
            handler(result.status == TLSSendResultStatusSuccess,
                    (NSUInteger)MAX(0, result.rawBytes),
                    (NSUInteger)MAX(0, result.compressedBytes));
        }
    }
                              completion:^(TLSProducer * _Nullable opened,
                                           NSError * _Nullable error) {
        EBObjCEntry *strongSelf = weakSelf;
        strongSelf.producer = opened;
        completion(error);
    }];
}

- (EBAddOutcome *)admitOne {
    TLSProducer *producer = self.producer;
    if (!producer) {
        return [EBAddOutcome rejectedOutcomeWithErrorCode:@"notOpen" latency:0];
    }

    // The timing is deliberately inside the entry implementation. It excludes
    // the shared ObjC scheduler's call into this object, while both entries
    // use the same monotonic clock and autorelease-pool boundary.
    @autoreleasepool {
        double begin = EBMonotonicSeconds();
        NSError *error = nil;
        BOOL accepted = [producer addLog:self.event
                                    mode:TLSAddModeNormal
                                   error:&error];
        double end = EBMonotonicSeconds();
        NSTimeInterval latency = end >= begin ? end - begin : 0;
        if (accepted) {
            return [EBAddOutcome acceptedOutcomeWithLatency:latency];
        }
        NSString *errorCode = error.userInfo[[TLSProducer errorCodeKey]];
        if (![errorCode isKindOfClass:NSString.class] || errorCode.length == 0) {
            errorCode = @"unknown";
        }
        return [EBAddOutcome rejectedOutcomeWithErrorCode:errorCode
                                                   latency:latency];
    }
}

- (void)startClosingWithTimeout:(NSTimeInterval)timeout
                     completion:(EBEntryCompletion)completion {
    TLSProducer *producer = self.producer;
    if (!producer) {
        completion(nil);
        return;
    }
    [producer closeWithTimeout:timeout completion:completion];
}

@end
