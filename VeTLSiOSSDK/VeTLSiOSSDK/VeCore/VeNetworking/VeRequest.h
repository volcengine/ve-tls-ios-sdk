//
//  VeRequest.h
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/11.
//

#import <Foundation/Foundation.h>
#import "VeBolts.h"
#import "VeNetworkingConstants.h"
#import "VeNetworkingRequest.h"
#import "VeEndpoint.h"

NS_ASSUME_NONNULL_BEGIN

@interface VeRequest : NSObject

@property (nonatomic, copy) VeNetworkingUploadProgressBlock uploadProgress;
@property (nonatomic, copy) VeNetworkingDownloadProgressBlock downloadProgress;
@property (nonatomic, assign, readonly, getter = isCancelled) BOOL cancelled;

@property (nonatomic, strong, readonly) VeNetworkingRequest *internalRequest;

@property (nonatomic, copy) NSDictionary *queryDictionary;
@property (nonatomic, copy) NSString *queryString;


- (NSURL *)urlWithVeEndpoint: (VeEndpoint *)endpoint path: (NSString *)path;
- (NSDictionary *)queryDictionary;
- (NSString *)queryString;

- (VeTask *)cancel;
- (VeTask *)pause;
- (NSDictionary *)headers;
- (NSString *)urlPathAndQuery;

@end

NS_ASSUME_NONNULL_END
