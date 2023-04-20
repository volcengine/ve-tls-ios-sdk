//
//  VeSign.h
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/10.
//

#import <Foundation/Foundation.h>
#import "VeCredential.h"

NS_ASSUME_NONNULL_BEGIN

// fork form aws
@interface VeSignatureSignerUtility : NSObject

+ (NSData * _Nonnull)sha256HMacWithData:(NSData * _Nullable)data withKey:(NSData * _Nonnull)key;
+ (NSString * _Nonnull)hashString:(NSString * _Nullable)stringToHash;
/*!
 @warning This function is deprecated and will be removed in an upcoming minor
 version of the SDK. You should use hashData instead.
 @deprecated Use hashData instead.
 */
+ (NSData * _Nonnull)hash:(NSData * _Nullable)dataToHash DEPRECATED_MSG_ATTRIBUTE("Use hashData instead.");
+ (NSData * _Nullable)hashData:(NSData * _Nullable)dataToHash;
+ (NSString * _Nonnull)hexEncode:(NSString * _Nullable)string;
+ (NSString * _Nullable)HMACSign:(NSData * _Nullable)data withKey:(NSString * _Nonnull)key usingAlgorithm:(uint32_t)algorithm;

@end

@interface VeSign : NSObject

- (instancetype)initWithCredential:(VeCredential *)credential withService:(NSString *)service  withRegion:(NSString *)region;

- (NSString *)signRequest:(NSMutableURLRequest *)urlRequst;

@property (nonatomic, strong) VeCredential * credential;
@property (nonatomic, copy) NSString * region;
@property (nonatomic, copy) NSString * service;

@end

NS_ASSUME_NONNULL_END
