//
//  VeNetworkingConstants.h
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/11.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VeHTTPMethod) {
    VeHTTPMethodUnknown,
    VeHTTPMethodGET,
    VeHTTPMethodHEAD,
    VeHTTPMethodPOST,
    VeHTTPMethodPUT,
    VeHTTPMethodPATCH,
    VeHTTPMethodDELETE
};

FOUNDATION_EXPORT NSString *const VeNetworkingErrorDomain;

typedef void (^VeNetworkingUploadProgressBlock) (int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend);

typedef void (^VeNetworkingDownloadProgressBlock) (int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite);


@interface NSString (VeHTTPMethod)

+ (instancetype)ve_stringWithHTTPMethod:(VeHTTPMethod)HTTPMethod;

@end

@interface VeNetworkingConstants : NSObject

@end

NS_ASSUME_NONNULL_END
