//
// EntryBenchmarkProtocol.m
//

#import "EntryBenchmarkProtocol.h"

@interface EBImmediateURLProtocol ()

@property(nonatomic) BOOL stopped;

@end

@implementation EBImmediateURLProtocol

static NSLock *EBURLProtocolLock(void) {
    static NSLock *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSLock alloc] init];
    });
    return lock;
}

// Keep the counter in file scope so reset/requestCount/startLoading cannot
// accidentally diverge when this fixture is copied between targets.
static NSUInteger gEBURLProtocolRequestCount = 0;

+ (void)reset {
    [EBURLProtocolLock() lock];
    gEBURLProtocolRequestCount = 0;
    [EBURLProtocolLock() unlock];
}

+ (NSUInteger)requestCount {
    [EBURLProtocolLock() lock];
    NSUInteger count = gEBURLProtocolRequestCount;
    [EBURLProtocolLock() unlock];
    return count;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *scheme = request.URL.scheme.lowercaseString;
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    [EBURLProtocolLock() lock];
    BOOL stopped = _stopped;
    [EBURLProtocolLock() unlock];
    if (stopped) {
        return;
    }

    NSURL *URL = self.request.URL;
    if (![URL.scheme.lowercaseString isEqualToString:@"https"] ||
        ![URL.host.lowercaseString isEqualToString:@"entry-benchmark.invalid"] ||
        ![URL.path isEqualToString:@"/PutLogs"]) {
        NSError *error = [NSError errorWithDomain:@"EntryBenchmarkURLProtocol"
                                               code:1
                                           userInfo:@{
                                               NSLocalizedDescriptionKey:
                                                   @"request escaped the offline benchmark fixture",
                                           }];
        [self.client URLProtocol:self didFailWithError:error];
        return;
    }

    [EBURLProtocolLock() lock];
    gEBURLProtocolRequestCount += 1;
    stopped = _stopped;
    [EBURLProtocolLock() unlock];
    if (stopped) {
        return;
    }
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
        initWithURL:URL
         statusCode:200
        HTTPVersion:@"HTTP/1.1"
       headerFields:@{
           @"Content-Type": @"application/json",
           @"x-tls-request-id": @"entry-benchmark-stub",
       }];
    [self.client URLProtocol:self
          didReceiveResponse:response
          cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    // A 200 with an empty body is sufficient for the C core success path. Do
    // not inspect, copy, or retain self.request.HTTPBody here.
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
    [EBURLProtocolLock() lock];
    _stopped = YES;
    [EBURLProtocolLock() unlock];
}

@end
