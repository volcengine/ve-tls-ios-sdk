//
//  VeRequest.m
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/11.
//

#import "VeRequest.h"

@interface VeRequest()

@end

@implementation VeRequest

- (instancetype)init {
    if (self = [super init]) {
        _internalRequest = [VeNetworkingRequest new];
    }
    
    return self;
}

- (VeTask *)cancel {
    [self.internalRequest cancel];
    return [VeTask taskWithResult:nil];
}

- (VeTask *)pause {
    [self.internalRequest pause];
    return [VeTask taskWithResult:nil];
}

- (NSDictionary *)headers {
    return nil;
}

- (NSDictionary *)queryDictionary {
    return nil;
}

- (NSString *)queryString {
    NSMutableString *queryString = [[NSMutableString alloc] initWithString:@""];
    [[self queryDictionary] enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
        [queryString appendFormat:@"%@=%@", key, obj];
    }];
    return queryString;
}

- (NSURL *)urlWithVeEndpoint: (VeEndpoint *)endpoint path: (NSString *)path {
    NSURLComponents *urlComponents = [[NSURLComponents alloc] initWithString: endpoint.endpoint];
    [urlComponents setPath: path];
    
    NSMutableArray *querys = [[NSMutableArray alloc] init];
    [[self queryDictionary] enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
        
        NSURLQueryItem *item = [[NSURLQueryItem alloc] initWithName:key value:obj];
        [querys addObject: item];
    }];
    
    [urlComponents setQueryItems:querys];
    
    NSString *urlString = [NSString stringWithString:endpoint.endpoint];
    if (path) {
        if ([urlString hasSuffix:@"/"]) {
            urlString = [NSString stringWithFormat:@"%@%@", urlString, path];
        } else {
            urlString = [NSString stringWithFormat:@"%@/%@", urlString, path];
        }
    }
    
    if (urlComponents.query) {
        urlString = [NSString stringWithFormat:@"%@?%@", urlString, path];
    }
    
    return [NSURL URLWithString:urlString];
}

@end
