//
//  TLSCredential.h
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/10.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VeCredential : NSObject

@property (nonatomic, strong, readonly) NSString *accessKey;
@property (nonatomic, strong, readonly) NSString *secretKey;
@property (nonatomic, strong, readonly, nullable) NSString *securityToken;

-(instancetype)initWithAccessKey:(NSString *)accessKey secretKey:(NSString *)secretKey;

// TODO: 暂时没有用到
- (instancetype)initWithSecurityToken: (NSString *)securityToken;

@end

NS_ASSUME_NONNULL_END
