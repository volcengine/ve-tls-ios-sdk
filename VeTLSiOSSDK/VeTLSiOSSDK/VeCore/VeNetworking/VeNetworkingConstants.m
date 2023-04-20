//
//  VeNetworkingConstants.m
//  VeTLSiOSSDK
//
//  Created by chenshiyu on 2023/1/11.
//

#import "VeNetworkingConstants.h"

NSString *const VeNetworkingErrorDomain = @"com.console.VeNetworkingErrorDomain";


@implementation NSString (VeHTTPMethod)

+ (instancetype)ve_stringWithHTTPMethod:(VeHTTPMethod)HTTPMethod {
    NSString *string = nil;
    switch (HTTPMethod) {
        case VeHTTPMethodGET:
            string = @"GET";
            break;
        case VeHTTPMethodHEAD:
            string = @"HEAD";
            break;
        case VeHTTPMethodPOST:
            string = @"POST";
            break;
        case VeHTTPMethodPUT:
            string = @"PUT";
            break;
        case VeHTTPMethodPATCH:
            string = @"PATCH";
            break;
        case VeHTTPMethodDELETE:
            string = @"DELETE";
            break;

        default:
            break;
    }

    return string;
}

@end

@implementation VeNetworkingConstants


@end
