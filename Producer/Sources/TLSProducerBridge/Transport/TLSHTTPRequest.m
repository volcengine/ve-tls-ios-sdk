// TLSHTTPRequest.m
// TLSProducerBridge/Transport
//

#import "TLSHTTPRequest.h"

@implementation TLSHTTPRequest

- (instancetype)initWithMethod:(NSString *)method
                     URLString:(NSString *)URLString
                       headers:(NSDictionary<NSString *, NSString *> *)headers
                          body:(NSData *)body
                connectTimeout:(NSTimeInterval)connectTimeout
                requestTimeout:(NSTimeInterval)requestTimeout {
    self = [super init];
    if (self) {
        _method = [method copy];
        _URLString = [URLString copy];
        _headers = [headers copy];
        _body = [body copy];
        _connectTimeout = connectTimeout;
        _requestTimeout = requestTimeout;
    }
    return self;
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    // Immutable: sharing the same instance is safe and avoids a redundant
    // copy. TLSTransport stores the request under a `copy` property.
    return self;
}

@end
