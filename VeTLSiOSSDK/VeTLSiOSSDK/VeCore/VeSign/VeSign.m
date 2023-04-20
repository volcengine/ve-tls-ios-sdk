//
//  VeSign.m
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/10.
//

#import "VeSign.h"
#import "NSDate+Ve.h"
#import "VeSignUtil.h"
#import <CommonCrypto/CommonCrypto.h>

NSString *const VeSignatureV4Algorithm = @"HMAC-SHA256";
NSString *const VeSignatureV4Terminator = @"request";

@implementation VeSignatureSignerUtility

+ (NSData *)sha256HMacWithData:(NSData *)data withKey:(NSData *)key {
    CCHmacContext context;

    CCHmacInit(&context, kCCHmacAlgSHA256, [key bytes], [key length]);
    CCHmacUpdate(&context, [data bytes], [data length]);

    unsigned char digestRaw[CC_SHA256_DIGEST_LENGTH];
    NSInteger digestLength = CC_SHA256_DIGEST_LENGTH;

    CCHmacFinal(&context, digestRaw);

    return [NSData dataWithBytes:digestRaw length:digestLength];
}

+ (NSString *)hashString:(NSString *)stringToHash {
    return [[NSString alloc] initWithData:[self hashData:[stringToHash dataUsingEncoding:NSUTF8StringEncoding]]
                                 encoding:NSASCIIStringEncoding];
}

+ (NSData *)hash:(NSData *)dataToHash {
    if ([dataToHash length] > UINT32_MAX) {
        return nil;
    }

    const void *cStr = [dataToHash bytes];
    unsigned char result[CC_SHA256_DIGEST_LENGTH];

    CC_SHA256(cStr, (uint32_t)[dataToHash length], result);

    return [[NSData alloc] initWithBytes:result length:CC_SHA256_DIGEST_LENGTH];
}

+ (NSData *)hashData:(NSData *)dataToHash {
    if ([dataToHash length] > UINT32_MAX) {
        return nil;
    }
    
    const void *cStr = [dataToHash bytes];
    unsigned char result[CC_SHA256_DIGEST_LENGTH];
    
    CC_SHA256(cStr, (uint32_t)[dataToHash length], result);
    
    return [[NSData alloc] initWithBytes:result length:CC_SHA256_DIGEST_LENGTH];
}

+ (NSString *)hexEncode:(NSString *)string {
    NSUInteger len = [string length];
    if (len == 0) {
        return @"";
    }
    unichar *chars = malloc(len * sizeof(unichar));
    if (chars == NULL) {
        // this situation is irrecoverable and we don't want to return something corrupted, so we raise an exception (avoiding NSAssert that may be disabled)
        [NSException raise:@"NSInternalInconsistencyException" format:@"failed malloc" arguments:nil];
        return nil;
    }

    [string getCharacters:chars];

    NSMutableString *hexString = [NSMutableString new];
    for (NSUInteger i = 0; i < len; i++) {
        if ((int)chars[i] < 16) {
            [hexString appendString:@"0"];
        }
        [hexString appendString:[NSString stringWithFormat:@"%x", chars[i]]];
    }
    free(chars);

    return hexString;
}

+ (NSString *)HMACSign:(NSData *)data withKey:(NSString *)key usingAlgorithm:(CCHmacAlgorithm)algorithm {
    CCHmacContext context;
    const char    *keyCString = [key cStringUsingEncoding:NSASCIIStringEncoding];

    CCHmacInit(&context, algorithm, keyCString, strlen(keyCString));
    CCHmacUpdate(&context, [data bytes], [data length]);

    // Both SHA1 and SHA256 will fit in here
    unsigned char digestRaw[CC_SHA256_DIGEST_LENGTH];

    NSInteger digestLength = -1;

    switch (algorithm) {
        case kCCHmacAlgSHA1:
            digestLength = CC_SHA1_DIGEST_LENGTH;
            break;

        case kCCHmacAlgSHA256:
            digestLength = CC_SHA256_DIGEST_LENGTH;
            break;

        default:
            return nil;
            break;
    }

    CCHmacFinal(&context, digestRaw);

    NSData *digestData = [NSData dataWithBytes:digestRaw length:digestLength];

    return [digestData base64EncodedStringWithOptions:kNilOptions];
}

@end


@implementation VeSign

- (instancetype)initWithCredential:(VeCredential *)credential withService:(NSString *)service  withRegion:(NSString *)region {
    if (self = [super init]) {
        _credential = credential;
        _region = region;
        _service = service;
    }
    return self;
}


- (NSString *)signRequest:(NSMutableURLRequest *)urlRequest {
    
    NSString *absoluteString = [urlRequest.URL absoluteString];
    if ([absoluteString hasSuffix:@"/"]) {
        urlRequest.URL = [NSURL URLWithString:[absoluteString substringToIndex:[absoluteString length] - 1]];
    }
    
    NSDate *xVeDate = [NSDate ve_dateFromString:[urlRequest valueForHTTPHeaderField:@"X-Date"]];
    NSString *dateyyMMddStamp = [xVeDate ve_stringValue: VeDateShortDateFormat1];
    NSString *dateISO8601Time = [xVeDate ve_stringValue: VeDateISO8601DateFormat2];
    
    // 步骤1：创建规范请求
    NSString *httpMethod = urlRequest.HTTPMethod;
    NSString *cfPath = (NSString*)CFBridgingRelease(CFURLCopyPath((CFURLRef)urlRequest.URL));
    NSString *path = cfPath;
    if (path.length == 0) {
        path = [NSString stringWithFormat:@"/"];
    }
    
    NSString *query = urlRequest.URL.query;
    if (query == nil) {
        query = [NSString stringWithFormat:@""];
    }
    
    
    NSString *contentSha256 = [VeSignatureSignerUtility hexEncode:[[NSString alloc] initWithData:[VeSignatureSignerUtility hashData:urlRequest.HTTPBody] encoding:NSASCIIStringEncoding]];
    
    [urlRequest setValue: contentSha256 forHTTPHeaderField:@"X-Content-Sha256"];
    
    NSString *canonicalRequest = [VeSign getCanonicalizedRequest:httpMethod
                                                            path:path
                                                           query:query
                                                         headers:urlRequest.allHTTPHeaderFields
                                                   contentSha256:contentSha256];
    
    // 步骤2：创建待签字符串
    NSString *credentialScope = [NSString stringWithFormat:@"%@/%@/%@/%@", dateyyMMddStamp, self.region, self.service, VeSignatureV4Terminator];
    
    NSString *stringToSign = [NSString stringWithFormat:@"%@\n%@\n%@\n%@",
                              VeSignatureV4Algorithm,
                              dateISO8601Time,
                              credentialScope,
                              [VeSignUtil hexEncode:[VeSignUtil hashString:canonicalRequest]]];
    
    // 步骤3：构建签名
    NSData *signingKey  = [VeSign getV4DerivedKey:self.credential.secretKey
                                             date:dateyyMMddStamp
                                           region:self.region
                                          service:self.service];
    
    NSData *signature = [VeSignUtil sha256HMacWithData:[stringToSign dataUsingEncoding:NSUTF8StringEncoding]
                                               withKey:signingKey];
    
    NSString *signatureString = [VeSignUtil hexEncode:[[NSString alloc] initWithData:signature
                                                                            encoding:NSASCIIStringEncoding]];
    
    // 步骤4：将签名添加到请求当中
    NSString *authorization = [NSString stringWithFormat:@"%@ Credential=%@/%@, SignedHeaders=%@, Signature=%@",
                               VeSignatureV4Algorithm,
                               self.credential.accessKey,
                               credentialScope,
                               [VeSign getSignedHeadersString: urlRequest.allHTTPHeaderFields],
                               signatureString];
    
    [urlRequest setValue:authorization forHTTPHeaderField:@"Authorization"];
    
    
    return authorization;
}


// ----------------------- canonical request  -----------------------

+ (NSString *)getCanonicalizedRequest:(NSString *)method path:(NSString *)path query:(NSString *)query headers:(NSDictionary *)headers contentSha256:(NSString *)contentSha256 {
    NSMutableString *canonicalRequest = [NSMutableString new];
    
    // request method
    [canonicalRequest appendString:method];
    [canonicalRequest appendString:@"\n"];
    
    // canonical uri
    [canonicalRequest appendString:path]; // Canonicalized resource path
    [canonicalRequest appendString:@"\n"];
    
    // canonical query String
    [canonicalRequest appendString:[self getCanonicalizedQueryString:query]];
    [canonicalRequest appendString:@"\n"];
    
    // canonical header
    [canonicalRequest appendString:[self getCanonicalizedHeaderString:headers]];
    [canonicalRequest appendString:@"\n"];
    
    // sign header
    [canonicalRequest appendString:[self getSignedHeadersString:headers]];
    [canonicalRequest appendString:@"\n"];
    
    
    [canonicalRequest appendString:[NSString stringWithFormat:@"%@", contentSha256]];
    
    return canonicalRequest;
}

+ (NSString *)getCanonicalizedQueryString:(NSString *)query {
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *queryDictionary = [NSMutableDictionary new];
    [[query componentsSeparatedByString:@"&"] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        NSArray *components = [obj componentsSeparatedByString:@"="];
        NSString *key;
        NSString *value = @"";
        NSUInteger count = [components count];
        if (count > 0 && count <= 2) {
            //can be ?a=b or ?a
            key = components[0];
            if  (! [key isEqualToString:@""] ) {
                if (count == 2) {
                    //is ?a=b
                    value = components[1];
                }
                if (queryDictionary[key]) {
                    // If the query parameter has multiple values, add it in the mutable array
                    [[queryDictionary objectForKey:key] addObject:value];
                } else {
                    // Insert the value for query parameter as an element in mutable array
                    [queryDictionary setObject:[@[value] mutableCopy] forKey:key];
                }
            }
        }
    }];
    
    NSMutableArray *sortedQuery = [[NSMutableArray alloc] initWithArray:[queryDictionary allKeys]];
    
    [sortedQuery sortUsingSelector:@selector(compare:)];
    
    NSMutableString *sortedQueryString = [NSMutableString new];
    for (NSString *key in sortedQuery) {
        [queryDictionary[key] sortUsingSelector:@selector(compare:)];
        for (NSString *parameterValue in queryDictionary[key]) {
            [sortedQueryString appendString:key];
            [sortedQueryString appendString:@"="];
            [sortedQueryString appendString:parameterValue];
            [sortedQueryString appendString:@"&"];
        }
    }
    // Remove the trailing & for a valid canonical query string.
    if ([sortedQueryString hasSuffix:@"&"]) {
        return [sortedQueryString substringToIndex:[sortedQueryString length] - 1];
    }
    
    return sortedQueryString;
}


+ (NSString *)getCanonicalizedHeaderString:(NSDictionary *)headers {
    NSCharacterSet *whitespaceChars = [NSCharacterSet whitespaceCharacterSet];
    // headers排序
    NSMutableArray *sortedHeaders = [[NSMutableArray alloc] initWithArray:[headers allKeys]];
    [sortedHeaders sortUsingSelector:@selector(caseInsensitiveCompare:)];
    
    NSMutableString *headerString = [NSMutableString new];
    for (NSString *header in sortedHeaders) {
        NSString *value = [headers valueForKey:header];
        value = [value stringByTrimmingCharactersInSet:whitespaceChars];
        [headerString appendString:[header lowercaseString]];
        [headerString appendString:@":"];
        [headerString appendString:value];
        [headerString appendString:@"\n"];
    }
    // SigV4 expects all whitespace in headers and values to be collapsed to a single space
    NSPredicate *noEmptyStrings = [NSPredicate predicateWithFormat:@"SELF != ''"];
    
    NSArray *parts = [headerString componentsSeparatedByCharactersInSet:whitespaceChars];
    NSArray *nonWhitespace = [parts filteredArrayUsingPredicate:noEmptyStrings];
    return [nonWhitespace componentsJoinedByString:@" "];
}

+ (NSString *)getSignedHeadersString:(NSDictionary *)headers {
    NSMutableArray *sortedHeaders = [[NSMutableArray alloc] initWithArray:[headers allKeys]];
    
    [sortedHeaders sortUsingSelector:@selector(caseInsensitiveCompare:)];
    
    NSMutableString *headerString = [NSMutableString new];
    for (NSString *header in sortedHeaders) {
        if ([headerString length] > 0) {
            [headerString appendString:@";"];
        }
        [headerString appendString:[header lowercaseString]];
    }
    
    return headerString;
}

// ------------ 构建签名方法 ------------ //
+ (NSData *)getV4DerivedKey:(NSString *)secret date:(NSString *)dateStamp region:(NSString *)regionName service:(NSString *)serviceName {
    
    NSData *kDate = [VeSignUtil sha256HMacWithData:[dateStamp dataUsingEncoding:NSUTF8StringEncoding]
                                           withKey:[secret dataUsingEncoding:NSUTF8StringEncoding]];
    NSData *kRegion = [VeSignUtil sha256HMacWithData:[regionName dataUsingEncoding:NSASCIIStringEncoding]
                                             withKey:kDate];
    NSData *kService = [VeSignUtil sha256HMacWithData:[serviceName dataUsingEncoding:NSUTF8StringEncoding]
                                              withKey:kRegion];
    NSData *kSigning = [VeSignUtil sha256HMacWithData:[VeSignatureV4Terminator dataUsingEncoding:NSUTF8StringEncoding]
                                              withKey:kService];
    
    return kSigning;
}

@end
