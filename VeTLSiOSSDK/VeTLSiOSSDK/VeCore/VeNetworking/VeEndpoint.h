//
//  VeEndpoint.h
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/11.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VeEndpoint : NSObject

@property (nonatomic, readonly) NSString *scheme;
@property (nonatomic, readonly) NSString *host;
@property (nonatomic, readonly) NSString *region;
@property (nonatomic, readonly) NSString *endpoint;
@property (nonatomic, readonly) NSURL *URL;

- (instancetype)initWithURLString:(NSString *)URLString region: (NSString *)region;
//- (instancetype)initWithRegionName: (NSString *)region;
//- (instancetype)initWithURL: (NSURL *)URL;
//- (instancetype)initWithURLString: (NSString *)URLString;

@end

NS_ASSUME_NONNULL_END
