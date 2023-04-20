//
//  TLSCredential.m
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/10.
//

#import "VeCredential.h"

@implementation VeCredential

-(instancetype)initWithAccessKey:(NSString *)accessKey secretKey:(NSString *)secretKey {
    if (self = [super init]) {
        _accessKey = accessKey;
        _secretKey = secretKey;
    }
    return self;
}

- (instancetype)initWithSecurityToken: (NSString *)securityToken {
    if (self = [super init]) {
        _securityToken = securityToken;
    }
    return self;
}

@end
