#import "SLSBenchmarkClient.h"

#import <AliyunLogProducer/Log.h>
#import <AliyunLogProducer/LogProducerClient.h>
#import <AliyunLogProducer/LogProducerConfig.h>

@interface SLSBenchmarkLog ()
@property(nonatomic, strong) Log *log;
@end

@implementation SLSBenchmarkLog
@end

@interface SLSBenchmarkClient ()
@property(nonatomic, strong) LogProducerConfig *configuration;
@property(nonatomic, strong) LogProducerClient *client;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, assign) NSUInteger terminalSuccess;
@property(nonatomic, assign) NSUInteger terminalFailure;
@property(nonatomic, assign) NSUInteger callbackRawBytes;
@end

static void TLSPerformanceSLSSendDone(
    const char *config_name,
    log_producer_result result,
    size_t log_bytes,
    size_t compressed_bytes,
    const char *req_id,
    const char *error_message,
    const unsigned char *raw_buffer,
    void *user_param) {
    (void)config_name;
    (void)compressed_bytes;
    (void)req_id;
    (void)error_message;
    (void)raw_buffer;
    if (user_param == NULL) {
        return;
    }
    SLSBenchmarkClient *owner = (__bridge SLSBenchmarkClient *)user_param;
    [owner.lock lock];
    if (result == LOG_PRODUCER_OK) {
        owner.terminalSuccess += 1;
    } else {
        owner.terminalFailure += 1;
    }
    owner.callbackRawBytes += log_bytes;
    [owner.lock unlock];
}

@implementation SLSBenchmarkClient

- (nullable instancetype)initWithEndpoint:(NSString *)endpoint
                                persistent:(BOOL)persistent
                             persistentPath:(NSString *)persistentPath {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _lock = [[NSLock alloc] init];

    // The C SDK creates https://<project>.<endpoint>/... . Supplying project
    // "127" and endpoint "0.0.1:<port>" resolves to the same 127.0.0.1
    // origin used by TLS, without DNS or hosts-file changes.
    NSURLComponents *components = [NSURLComponents componentsWithString:endpoint];
    if (components == nil || components.port == nil) {
        return nil;
    }
    NSString *slsEndpoint = [NSString stringWithFormat:@"https://0.0.1:%@", components.port];
    _configuration = [[LogProducerConfig alloc]
        initWithEndpoint:slsEndpoint
                 project:@"127"
                logstore:@"performance-topic"
             accessKeyID:@"performance-test-ak"
         accessKeySecret:@"performance-test-sk"];
    [_configuration SetPacketLogBytes:1024 * 1024];
    [_configuration SetPacketLogCount:1024];
    [_configuration SetPacketTimeout:3000];
    [_configuration SetMaxBufferLimit:64 * 1024 * 1024];
    [_configuration SetSendThreadCount:1];
    [_configuration SetConnectTimeoutSec:10];
    [_configuration SetSendTimeoutSec:15];
    [_configuration SetCompressType:1];
    [_configuration SetMaxLogDelayTime:7 * 24 * 60 * 60];
    [_configuration SetDropDelayLog:0];
    [_configuration SetDropUnauthorizedLog:0];
    if (persistent) {
        [_configuration SetPersistent:1];
        [_configuration SetPersistentFilePath:persistentPath];
        [_configuration SetPersistentForceFlush:0];
        [_configuration SetPersistentMaxFileCount:10];
        [_configuration SetPersistentMaxFileSize:10 * 1024 * 1024];
        [_configuration SetPersistentMaxLogCount:65536];
    }
    if ([_configuration IsValid] != 1) {
        return nil;
    }
    _client = [[LogProducerClient alloc]
        initWithLogProducerConfig:_configuration
                         callback:TLSPerformanceSLSSendDone
                        userparams:self];
    if (_client == nil) {
        return nil;
    }
    return self;
}

- (SLSBenchmarkLog *)prepareLogWithIndex:(NSUInteger)index {
    SLSBenchmarkLog *prepared = [[SLSBenchmarkLog alloc] init];
    Log *log = [Log log];
    NSMutableDictionary<NSString *, NSString *> *contents =
        [[NSMutableDictionary alloc] initWithCapacity:10];
    NSString *prefix = [NSString stringWithFormat:@"%012lu", (unsigned long)index];
    for (NSUInteger field = 0; field < 10; field += 1) {
        NSString *key = [NSString stringWithFormat:@"k%lu", (unsigned long)field];
        NSUInteger valueLength = field < 4 ? 101 : 100;
        NSString *fieldPrefix = field == 0 ? prefix : @"";
        NSString *padding = [@"x" stringByPaddingToLength:valueLength - fieldPrefix.length
                                               withString:@"x"
                                          startingAtIndex:0];
        contents[key] = [fieldPrefix stringByAppendingString:padding];
    }
    [log putContents:contents];
    prepared.log = log;
    return prepared;
}

- (BOOL)addPreparedLog:(SLSBenchmarkLog *)log immediate:(BOOL)immediate {
    return [self.client AddLog:log.log flush:(immediate ? 1 : 0)] == LogProducerOK;
}

- (NSDictionary<NSString *, NSNumber *> *)terminalSnapshot {
    [self.lock lock];
    NSDictionary<NSString *, NSNumber *> *snapshot = @{
        @"success": @(self.terminalSuccess),
        @"failure": @(self.terminalFailure),
        @"rawBytes": @(self.callbackRawBytes),
    };
    [self.lock unlock];
    return snapshot;
}

// Do not call -DestroyLogProducer here. AliyunLogProducer 4.3.4 has a known
// destroy-time use-after-free under this workload. Each benchmark case runs
// in a fresh app process, and the host runner terminates and verifies that
// process after copying evidence.

@end
