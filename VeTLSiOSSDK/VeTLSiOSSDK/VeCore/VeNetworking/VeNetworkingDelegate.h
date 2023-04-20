//
//  VeNetworkingDelegate.h
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/11.
//

#import <Foundation/Foundation.h>
#import "VeBolts.h"
#import "VeNetworkingRequest.h"

@class VeNetworking;

NS_ASSUME_NONNULL_BEGIN

@interface VeNetworkingDelegate : NSObject

@property (nonatomic, strong) VeTaskCompletionSource *taskCompletionSource;
@property (nonatomic, strong) id responseObject;
@property (nonatomic, strong) NSMutableData *responseData;
@property (nonatomic, strong) VeNetworkingRequest *request;

@property (nonatomic, strong) NSError *error;

@end

NS_ASSUME_NONNULL_END
