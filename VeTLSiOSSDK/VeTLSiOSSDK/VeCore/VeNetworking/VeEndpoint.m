//
//  VeEndpoint.m
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/11.
//

#import "VeEndpoint.h"

@implementation VeEndpoint

- (instancetype)initWithRegionName: (NSString *)region {
    if (self = [super init]) {
        _region = region;
    }
    return self;
}

- (instancetype)initWithURLString:(NSString *)URLString region: (NSString *)region {
    if (self = [self initWithURLString:URLString]) {
        _region = region;
    }
    return self;
}

- (instancetype)initWithURL: (NSURL *)URL {
    if (self = [super init]) {
        _URL = URL;
        _host = [_URL host];
        _scheme = [_URL scheme];
    }

    _endpoint = URL.absoluteString;
    return self;
}

- (instancetype)initWithURLString: (NSString *)URLString {
    if (![URLString hasPrefix:@"https://"] && ![URLString hasPrefix:@"http://"]) {
        URLString = [NSString stringWithFormat:@"https://%@", URLString];
    }
    return  [self initWithURL:[[NSURL alloc] initWithString:URLString]];
}

@end
