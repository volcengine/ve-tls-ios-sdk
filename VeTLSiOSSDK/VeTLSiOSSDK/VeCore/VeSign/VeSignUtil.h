//
//  VeSignUtil.h
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/11.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VeSignUtil : NSObject

+ (NSData * _Nonnull)sha256HMacWithData:(NSData * _Nullable)data withKey:(NSData * _Nonnull)key;
+ (NSString * _Nonnull)hashString:(NSString * _Nullable)stringToHash;
+ (NSData * _Nullable)hashData:(NSData * _Nullable)dataToHash;
+ (NSString * _Nonnull)hexEncode:(NSString * _Nullable)string;
+ (NSString * _Nullable)HMACSign:(NSData * _Nullable)data withKey:(NSString * _Nonnull)key usingAlgorithm:(uint32_t)algorithm;

@end

NS_ASSUME_NONNULL_END
