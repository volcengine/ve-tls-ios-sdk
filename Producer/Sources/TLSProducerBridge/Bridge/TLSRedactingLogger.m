// TLSRedactingLogger.m
// TLSProducerBridge
//

#import "TLSRedactingLogger.h"

NSString *const TLSRedactedMarker = @"***REDACTED***";

@implementation TLSRedactingLogger

+ (NSString *)redactedURLString:(NSString *)URLString {
    if (URLString.length == 0) {
        return @"";
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:URLString];
    if (components != nil) {
        components.query = nil;
        components.fragment = nil;
        // L1: strip userinfo so credentials embedded in the URL authority
        // never reach the log.
        components.user = nil;
        components.password = nil;
        NSString *stripped = components.string;
        if (stripped != nil) {
            return stripped;
        }
    }
    // Fallback for malformed URLs: cut at the first '?' or '#'.
    NSUInteger cut = URLString.length;
    NSRange queryRange = [URLString rangeOfString:@"?"];
    if (queryRange.location != NSNotFound) {
        cut = MIN(cut, queryRange.location);
    }
    NSRange fragmentRange = [URLString rangeOfString:@"#"];
    if (fragmentRange.location != NSNotFound) {
        cut = MIN(cut, fragmentRange.location);
    }
    return [URLString substringToIndex:cut];
}

+ (NSRegularExpression *)authorizationRegex {
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression
            regularExpressionWithPattern:@"authorization"
                                 options:NSRegularExpressionCaseInsensitive
                                   error:NULL];
    });
    return regex;
}

+ (NSRegularExpression *)xTLSTokenRegex {
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression
            regularExpressionWithPattern:@"x-tls-[a-z0-9_-]*"
                                 options:NSRegularExpressionCaseInsensitive
                                   error:NULL];
    });
    return regex;
}

+ (BOOL)containsSensitiveToken:(NSString *)input {
    if (input.length == 0) {
        return NO;
    }
    if ([input.lowercaseString containsString:@"authorization"]) {
        return YES;
    }
    NSUInteger matches = [[self xTLSTokenRegex]
        numberOfMatchesInString:input
                         options:0
                           range:NSMakeRange(0, input.length)];
    return matches > 0;
}

+ (NSString *)maskSensitiveTokensInString:(NSString *)input {
    if (input.length == 0) {
        return input;
    }
    NSMutableString *out = [input mutableCopy];
    [[self authorizationRegex] replaceMatchesInString:out
                                              options:0
                                                range:NSMakeRange(0, out.length)
                                         withTemplate:TLSRedactedMarker];
    [[self xTLSTokenRegex] replaceMatchesInString:out
                                          options:0
                                            range:NSMakeRange(0, out.length)
                                     withTemplate:TLSRedactedMarker];
    return out;
}

+ (void)logWithMethod:(NSString *)method
            URLString:(NSString *)URLString
               status:(NSInteger)status
     durationInterval:(NSTimeInterval)duration
            requestID:(nullable NSString *)requestID
            byteCount:(NSInteger)byteCount {
    // The entry point accepts only predefined fields; callers cannot pass
    // headers or bodies. Every field is additionally run through the
    // redactor as defense in depth.
    NSString *safeMethod = [self maskSensitiveTokensInString:method ?: @"-"];
    NSString *safeURL = [self maskSensitiveTokensInString:
        [self redactedURLString:URLString ?: @""]];
    NSString *safeRequestID = requestID.length > 0
        ? [self maskSensitiveTokensInString:requestID]
        : @"-";
    NSLog(@"[TLSProducer] method=%@ url=%@ status=%ld duration_ms=%.1f requestID=%@ bytes=%ld",
          safeMethod,
          safeURL,
          (long)status,
          duration * 1000.0,
          safeRequestID,
          (long)byteCount);
}

+ (BOOL)runBuiltInSelfCheck {
    // URL redaction: query and fragment must be stripped.
    NSString *redacted = [self redactedURLString:
        @"https://tls-cn-beijing.volces.com/path?authorization=abc&x-tls-token=def#frag"];
    if (![redacted isEqualToString:@"https://tls-cn-beijing.volces.com/path"]) {
        return NO;
    }
    // Sensitive tokens must be masked in arbitrary input.
    NSString *masked = [self maskSensitiveTokensInString:
        @"Authorization: Bearer abc; x-tls-secret-token: def"];
    if ([self containsSensitiveToken:masked]) {
        return NO;
    }
    if (![masked containsString:TLSRedactedMarker]) {
        return NO;
    }
    // Clean input must be reported as clean.
    if ([self containsSensitiveToken:@"POST /PutLogs HTTP/1.1"]) {
        return NO;
    }
    // The redacted URL itself must not trip the detector.
    if ([self containsSensitiveToken:redacted]) {
        return NO;
    }
    return YES;
}

@end
