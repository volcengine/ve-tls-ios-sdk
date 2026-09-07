// TLSHTTPResponse.m
// TLSProducerBridge/Transport
//

#import "TLSHTTPResponse.h"

@implementation TLSHTTPResponse

- (instancetype)initWithStatusCode:(NSInteger)statusCode
                           headers:(NSDictionary *)headers
                              body:(NSData *)body
                         requestID:(NSString *)requestID
                             error:(NSError *)error {
    self = [super init];
    if (self) {
        _statusCode = statusCode;
        _headers = [headers copy];
        _body = [body copy] ?: [NSData data];
        _requestID = [requestID copy];
        _error = [error copy];
    }
    return self;
}

@end
