//
//  VeNetworkingRequest.h
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/12.
//

#import <Foundation/Foundation.h>
#import "VeNetworkingConstants.h"
#import "VeBolts.h"

NS_ASSUME_NONNULL_BEGIN

@interface VeNetworkingRequest : NSObject
@property (nonatomic, copy) NSData *requstBody;
@property (nonatomic, strong) NSDictionary *headers;
@property (nonatomic, strong) NSURLSessionTask *task;
@property (nonatomic, assign, getter = isCancelled) BOOL cancelled;

@property (nonatomic, copy) VeNetworkingUploadProgressBlock uploadProgress;
@property (nonatomic, copy) VeNetworkingDownloadProgressBlock downloadProgress;

@property (nonatomic, assign) VeHTTPMethod HTTPMethod;

@property (nonatomic, strong) NSURL *url;

// 预留字段, 支持解析的时候再使用
@property (nonatomic, strong) id requestSerializer;
@property (nonatomic, strong) id responseSerializer;


- (void)cancel;
- (void)pause;

@end

@interface GeneralHttpResponse : NSObject
@property (nonatomic, copy) NSData *responseBody;
@property (nonatomic, copy) NSNumber *httpStatusCode;
@property (nonatomic, copy) NSString *requestId;
@end


NS_ASSUME_NONNULL_END
