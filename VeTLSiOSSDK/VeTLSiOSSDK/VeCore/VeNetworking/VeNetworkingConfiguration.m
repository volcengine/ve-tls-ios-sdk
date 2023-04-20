//
//  TLSNetworkingConfiguration.m
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/10.
//

#import "VeNetworkingConfiguration.h"

@implementation VeNetworkingConfiguration

- (instancetype)initWithEndpoint:(VeEndpoint *)endpoint credentail: (VeCredential *)credential {
    if (self = [super init]) {
        _endpoint = endpoint;
        _credential = credential;
    }
    return self;
}

@end
