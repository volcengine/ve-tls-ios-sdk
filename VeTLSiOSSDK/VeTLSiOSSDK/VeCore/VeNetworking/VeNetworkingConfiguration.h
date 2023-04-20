//
//  TLSNetworkingConfiguration.h
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/10.
//

#import <Foundation/Foundation.h>
#import "VeCredential.h"
#import "VeEndpoint.h"

NS_ASSUME_NONNULL_BEGIN

@interface VeNetworkingConfiguration : NSObject

@property (nonatomic, strong, readonly) VeEndpoint *endpoint;
@property (nonatomic, strong, readonly) VeCredential *credential;


- (instancetype)initWithEndpoint:(VeEndpoint *)endpoint credentail: (VeCredential *)credential;

@end

NS_ASSUME_NONNULL_END
