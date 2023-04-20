//
//  TLSNetworking.h
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/10.
//

#import <Foundation/Foundation.h>
#import "VeNetworkingConfiguration.h"
#import "VeBolts.h"
#import "VeNetworkingConstants.h"
#import "VeNetworkingRequest.h"


NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VeNetworkingErrorType) {
    VeNetworkingErrorUnknown,
    VeNetworkingErrorCancelled,
    VeNetworkingErrorSessionInvalid
};

@interface VeNetworking : NSObject <NSURLSessionDelegate, NSURLSessionDataDelegate>


- (instancetype)initWithConfiguration:(VeNetworkingConfiguration *)configuration serviceName: (NSString *)service;

- (VeTask *)sendRequest: (VeNetworkingRequest *)veNetworkingRequest;
@end

NS_ASSUME_NONNULL_END
