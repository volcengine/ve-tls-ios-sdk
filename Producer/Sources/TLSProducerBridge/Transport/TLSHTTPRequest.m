// TLSHTTPRequest.m
// TLSProducerBridge/Transport
//

#import "TLSHTTPRequest.h"

#import <math.h>
#include <string.h>

static BOOL TLSIsFiniteDiagnosticNumber(NSNumber *number) {
    if (number == nil) {
        return NO;
    }
    const char *type = number.objCType;
    if (type != NULL && (strcmp(type, @encode(float)) == 0 ||
                         strcmp(type, @encode(double)) == 0 ||
                         strcmp(type, @encode(long double)) == 0)) {
        return isfinite(number.doubleValue);
    }
    return YES;
}

static BOOL TLSIsDiagnosticIDToken(NSString *value, NSUInteger maxLength) {
    if (![value isKindOfClass:[NSString class]] ||
        value.length == 0 || value.length > maxLength) {
        return NO;
    }
    for (NSUInteger index = 0; index < value.length; index++) {
        unichar character = [value characterAtIndex:index];
        BOOL allowed = (character >= 'a' && character <= 'z') ||
                       (character >= 'A' && character <= 'Z') ||
                       (character >= '0' && character <= '9') ||
                       character == '.' || character == '_' ||
                       character == ':' || character == '-';
        if (!allowed) {
            return NO;
        }
    }
    return YES;
}

static NSDictionary<NSString *, id> *TLSCopyDiagnosticContext(
    NSDictionary<NSString *, id> *context) {
    if (![context isKindOfClass:[NSDictionary class]] || context.count == 0) {
        return nil;
    }

    NSMutableDictionary<NSString *, id> *copy = [NSMutableDictionary dictionary];
    NSSet<NSString *> *allowedKeys = [NSSet setWithObjects:
        @"batch_start_id", @"batch_end_id", @"counters", @"attempt_id", nil];
    for (id rawKey in context) {
        if (![rawKey isKindOfClass:[NSString class]] ||
            ![allowedKeys containsObject:rawKey]) {
            continue;
        }
        id value = context[rawKey];
        if ([rawKey isEqualToString:@"attempt_id"]) {
            if ([value isKindOfClass:[NSString class]] &&
                TLSIsDiagnosticIDToken((NSString *)value, 128)) {
                copy[rawKey] = [value copy];
            }
            continue;
        }
        if ([rawKey isEqualToString:@"counters"]) {
            if (![value isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSMutableDictionary<NSString *, id> *counterCopy = [NSMutableDictionary dictionary];
            NSSet<NSString *> *allowedCounterKeys = [NSSet setWithObjects:
                @"attempt_count", @"cycle_attempt_count", @"log_count", nil];
            for (NSString *counterKey in allowedCounterKeys) {
                if (![((NSDictionary *)value) objectForKey:counterKey]) {
                    continue;
                }
                id counterValue = ((NSDictionary *)value)[counterKey];
                if ([counterValue isKindOfClass:[NSNumber class]] &&
                    TLSIsFiniteDiagnosticNumber(counterValue)) {
                    counterCopy[counterKey] = [counterValue copy];
                } else if (counterValue == [NSNull null]) {
                    counterCopy[counterKey] = [NSNull null];
                }
            }
            if (counterCopy.count > 0) {
                copy[rawKey] = [counterCopy copy];
            }
            continue;
        }
        if ([value isKindOfClass:[NSNumber class]] &&
            TLSIsFiniteDiagnosticNumber(value)) {
            copy[rawKey] = [value copy];
        }
    }
    return copy.count > 0 ? [copy copy] : nil;
}

@implementation TLSHTTPRequest

- (instancetype)initWithMethod:(NSString *)method
                     URLString:(NSString *)URLString
                       headers:(NSDictionary<NSString *, NSString *> *)headers
                          body:(NSData *)body
                connectTimeout:(NSTimeInterval)connectTimeout
                   idleTimeout:(NSTimeInterval)idleTimeout
                requestTimeout:(NSTimeInterval)requestTimeout
             diagnosticContext:(NSDictionary<NSString *, id> *)diagnosticContext {
    self = [super init];
    if (self) {
        _method = [method copy];
        _URLString = [URLString copy];
        _headers = [headers copy];
        _body = [body copy];
        _diagnosticContext = TLSCopyDiagnosticContext(diagnosticContext);
        _connectTimeout = connectTimeout;
        _idleTimeout = idleTimeout;
        _requestTimeout = requestTimeout;
    }
    return self;
}

- (instancetype)initWithMethod:(NSString *)method
                     URLString:(NSString *)URLString
                       headers:(NSDictionary<NSString *, NSString *> *)headers
                          body:(NSData *)body
                connectTimeout:(NSTimeInterval)connectTimeout
                   idleTimeout:(NSTimeInterval)idleTimeout
                requestTimeout:(NSTimeInterval)requestTimeout {
    return [self initWithMethod:method
                      URLString:URLString
                        headers:headers
                           body:body
                 connectTimeout:connectTimeout
                    idleTimeout:idleTimeout
                 requestTimeout:requestTimeout
              diagnosticContext:nil];
}

- (instancetype)initWithMethod:(NSString *)method
                     URLString:(NSString *)URLString
                       headers:(NSDictionary<NSString *, NSString *> *)headers
                          body:(NSData *)body
                connectTimeout:(NSTimeInterval)connectTimeout
                requestTimeout:(NSTimeInterval)requestTimeout {
    return [self initWithMethod:method
                      URLString:URLString
                        headers:headers
                           body:body
                 connectTimeout:connectTimeout
                    idleTimeout:connectTimeout
                 requestTimeout:requestTimeout
              diagnosticContext:nil];
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    // Immutable: sharing the same instance is safe and avoids a redundant
    // copy. TLSTransport stores the request under a `copy` property.
    return self;
}

@end
